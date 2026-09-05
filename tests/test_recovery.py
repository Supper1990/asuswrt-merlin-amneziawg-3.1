"""Fault-injection checks. No router, network or real firewall is touched."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / 'addon/amneziawg.sh').read_text()
AUX = (ROOT / 'addon/awg-ipset-update.sh').read_text()

def functions(source, *names):
    return '\n'.join(re.search(r'^' + name + r'\(\)\{.*?^\}', source,
                              re.M | re.S).group() for name in names)

class Recovery(unittest.TestCase):
    def run_shell(self, body, env=None):
        return subprocess.run(['sh'], input=body, text=True, capture_output=True,
                              timeout=10, env=dict(os.environ, **(env or {})))

    def test_dead_main_lock(self):
        with tempfile.TemporaryDirectory() as d:
            lock = Path(d) / 'lock'
            lock.mkdir()
            (lock / 'pid').write_text('2147483647')
            r = self.run_shell(functions(MAIN, 'acquire_lock', 'release_lock') +
                               '\nacquire_lock || exit 1\nrelease_lock\n', {'LOCKDIR': str(lock)})
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(lock.exists())

    def test_live_main_lock_not_stolen(self):
        with tempfile.TemporaryDirectory() as d:
            lock = Path(d) / 'lock'
            lock.mkdir()
            (lock / 'pid').write_text(str(os.getpid()))
            r = self.run_shell(functions(MAIN, 'acquire_lock') +
                               '\nsleep(){ :; }\nlog_msg(){ :; }\nacquire_lock\n',
                               {'LOCKDIR': str(lock)})
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual((lock / 'pid').read_text(), str(os.getpid()))

    def test_watchdog_retains_retry_after_failure(self):
        r = self.run_shell(functions(MAIN, 'do_watchdog') + '''
ip(){ return 1; }
log_msg(){ :; }
do_stop(){ :; }
wait_for_pid_exit(){ :; }
do_start(){ return 1; }
cru(){ echo "$*"; }
do_watchdog
''')
        self.assertEqual(r.returncode, 1)
        self.assertIn('a awg_watchdog', r.stdout)

    def test_second_probe_prevents_restart(self):
        r = self.run_shell(functions(MAIN, 'tunnel_healthy') + '''
ping(){ case "$*" in *1.1.1.1) return 0;; *) return 1;; esac; }
tunnel_healthy
''')
        self.assertEqual(r.returncode, 0)

    def test_all_probes_fail(self):
        r = self.run_shell(functions(MAIN, 'tunnel_healthy') + '''
ping(){ echo probe >> "$TRACE"; return 1; }
tunnel_healthy
''', {'TRACE': '/dev/null'})
        self.assertEqual(r.returncode, 1)

    def test_failed_staging_and_swap_preserve_cache(self):
        for fail in ('restore', 'swap'):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as d:
                env = {k: str(Path(d) / k) for k in ('OLD_LIST', 'NEW_LIST', 'RESTORE', 'LOG')}
                Path(env['OLD_LIST']).write_text('old\n')
                Path(env['NEW_LIST']).write_text('203.0.113.0/24\n')
                env['FAIL'] = fail
                r = self.run_shell(functions(AUX, 'full_rebuild_from_new_list') + '''
log(){ :; }
ipset(){ [ "$1" != "$FAIL" ]; }
full_rebuild_from_new_list
''', env)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(Path(env['OLD_LIST']).read_text(), 'old\n')

    def test_disabled_antifilter_never_installs_routes(self):
        r = self.run_shell(functions(AUX, 'ensure_routing') + '''
antifilter_allowed(){ return 1; }
disable_routing(){ echo disabled; }
ip(){ echo UNEXPECTED; }
ensure_routing
''')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.strip(), 'disabled')

    def test_dns_rules_are_captured(self):
        r = self.run_shell(functions(MAIN, 'managed_firewall_rules').replace('iptables-save', 'iptables_save') + '''
AWG_CHAIN=AWG
iptables_save(){
    case "$2" in
    mangle) echo '-A AWG -j MARK --set-xmark 0x100/0xffffffff';;
    nat) echo '-A PREROUTING -i br0 -p udp -m udp --dport 53 -j DNAT --to-destination 192.168.50.1';;
    filter) echo '-A FORWARD -i br0 -p tcp -m tcp --dport 853 -j REJECT --reject-with icmp-port-unreachable';;
    esac
}
managed_firewall_rules
''')
        self.assertEqual(len(r.stdout.splitlines()), 3)

    def test_aux_lock_recovers_dead_owner(self):
        with tempfile.TemporaryDirectory() as d:
            lock = Path(d) / 'lock'
            lock.mkdir()
            (lock / 'pid').write_text('2147483647')
            r = self.run_shell(functions(AUX, 'acquire_aux_lock') +
                               '\nlog(){ :; }\nacquire_aux_lock\n', {'LOCKDIR': str(lock)})
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotEqual((lock / 'pid').read_text(), '2147483647')

    def test_individual_policies_precede_default(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ('geoip', 'domains'):
                Path(d, name).mkdir()
            Path(d, 'clients').write_text('192.168.50.10,Direct,direct,\n192.168.50.11,Geo,vpn_geo,\n')
            env = {k: str(Path(d, k)) for k in ('IPSET_MIN_COUNT_FILE', 'DNSMASQ_AWG_CONF', 'DNSMASQ_INCLUDE', 'FIREWALL_EXPECTED')}
            env.update(GEO_DIR=d, CLIENTS_FILE=str(Path(d, 'clients')), TRACE=str(Path(d, 'trace')),
                       AWG_CHAIN='AWG', FWMARK='0x100', DIRECT_MARK='0x101', IFACE='awg0', RT_TABLE='300', IPSET_NAME='awg_dst')
            stubs = '\n'.join(name + '(){ :; }' for name in ('cleanup_firewall', 'prune_unselected_geoip_lists',
                'selected_geoip_services', 'save_clients', 'setup_dns_interception', 'restart_dnsmasq_and_wait',
                'flush_conntrack', 'save_and_set_rp_filter', 'ensure_ui_mark_nat', 'repair_aux_routing',
                'register_managed_cron', 'managed_firewall_rules', 'log_msg'))
            r = self.run_shell(functions(MAIN, 'setup_firewall') + '\n' + stubs + r'''
get_setting(){ [ "$1" = awg_default_policy ] && echo vpn_all; }
get_lan_net(){ echo 192.168.50.0/24; }
get_endpoint(){ echo 203.0.113.1; }
ipset(){ [ "$1" = list ] && echo 'Number of entries: 0'; return 0; }
ip(){ echo "$*" >> "$TRACE"; }
iptables(){ echo "$*" >> "$TRACE"; }
setup_firewall
''', env)
            self.assertEqual(r.stderr, '')
            trace = Path(env['TRACE']).read_text().splitlines()
            direct = '-t mangle -A AWG -s 192.168.50.10 -j MARK --set-mark 0x101'
            geo_return = '-t mangle -A AWG -s 192.168.50.11 -j RETURN'
            default = '-t mangle -A AWG -j MARK --set-mark 0x100'
            self.assertIn(direct, trace)
            self.assertLess(trace.index(geo_return), trace.index(default))
            self.assertIn('rule add fwmark 0x101 lookup main prio 9', trace)

    def test_apply_restarts_only_for_tunnel_changes(self):
        for changed in (False, True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as d:
                Path(d, 'conf').write_text('old')
                Path(d, 'awg0.addr').write_text('10.8.1.10/32')
                r = self.run_shell(functions(MAIN, 'do_service_event') + '''
get_setting(){ echo present; }
generate_config(){ [ "$CHANGED" = yes ] && echo new > "$CONF"; return 0; }
is_running(){ return 0; }
update_geo_if_needed(){ :; }
log_msg(){ :; }
do_stop(){ echo stop; }
do_start(){ echo start; }
setup_firewall(){ echo firewall; }
update_status(){ :; }
do_service_event start awgsaveconf
''', {'AWG_DIR': d, 'CONF': str(Path(d, 'conf')), 'CHANGED': 'yes' if changed else 'no'})
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), 'stop\nstart' if changed else 'firewall')

if __name__ == '__main__':
    unittest.main()
