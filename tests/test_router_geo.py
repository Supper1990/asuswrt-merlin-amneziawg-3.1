"""Router OUTPUT failure injection; simulated commands, not Merlin validation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_recovery import functions, MAIN, ROOT

RUNTIME = (ROOT / 'addon/awg-runtime.sh').read_text()
COMMON = (ROOT / 'addon/awg-common.sh').read_text()


class RouterGeo(unittest.TestCase):
    def run_shell(self, body, **env):
        return subprocess.run(['sh'], input=body, text=True, capture_output=True,
                              timeout=10, env=dict(os.environ, **env))

    def setup_script(self):
        return functions(RUNTIME, 'router_geo_enabled', 'router_transport_port', 'setup_router_geo') + '\n' + functions(COMMON, 'valid_ipv4') + r'''
get_setting(){ echo "$ENABLED"; }
get_lan_net(){ echo 192.168.50.0/24; }
awg_mock(){ case "$3" in listen-port) echo "$PORT";; endpoints) echo 'key 203.0.113.5:51820';; esac; }
log_msg(){ echo "$*" >&2; }
iptables(){ echo "$*"; case "$*" in *"$FAIL_AT"*) return 1;; esac; }
AWG_BIN=awg_mock
IFACE=awg0
IPSET_NAME=awg_dst
FWMARK=0x100
setup_router_geo
'''

    def test_default_off_does_not_touch_firewall(self):
        for enabled in ('', '0'):
            r = self.run_shell(self.setup_script(), ENABLED=enabled, PORT='51820', FAIL_AT='never')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, '')

    def test_transport_and_local_exclusions_precede_mark_and_hook(self):
        r = self.run_shell(self.setup_script(), ENABLED='1', PORT='51820', FAIL_AT='never')
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = r.stdout.splitlines()
        mark = next(i for i, row in enumerate(rows) if '--set-mark' in row)
        for match in ('--sport 51820', '--dst-type LOCAL', '-d 192.168.50.0/24', '-d 203.0.113.5/32', '--mark 0x0/'):
            self.assertLess(next(i for i, row in enumerate(rows) if match in row), mark)
        self.assertEqual(rows[-1], '-t mangle -I OUTPUT 1 -j AWG_OUTPUT')
        self.assertNotIn('PREROUTING', r.stdout)

    def test_unknown_transport_port_refuses_activation(self):
        for port in ('', '0', '65536', 'bad'):
            r = self.run_shell(self.setup_script(), ENABLED='1', PORT=port, FAIL_AT='never')
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, '')

    def test_cleanup_removes_duplicate_hooks_before_chain_only(self):
        body = functions(RUNTIME, 'cleanup_router_geo') + r'''
n_hooks=2
iptables(){
    case "$*" in
        *' -C OUTPUT '*) [ "$n_hooks" -gt 0 ];;
        *' -D OUTPUT '*) n_hooks=$((n_hooks-1)); echo "$*";;
        *) echo "$*";;
    esac
}
cleanup_router_geo
'''
        r = self.run_shell(body)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), [
            '-t mangle -D OUTPUT -j AWG_OUTPUT',
            '-t mangle -D OUTPUT -j AWG_OUTPUT',
            '-t mangle -F AWG_OUTPUT', '-t mangle -X AWG_OUTPUT'])

    def test_full_health_rejects_missing_exclusion_even_with_hook_and_mark(self):
        with tempfile.TemporaryDirectory() as d:
            expected = Path(d, 'expected')
            expected.write_text('transport-exclusion\ngeo-mark\n')
            body = functions(RUNTIME, 'main_firewall_healthy') + r'''
main_firewall_base_healthy(){ return 0; }
managed_firewall_rules(){ echo geo-mark; }
main_firewall_healthy
'''
            r = self.run_shell(body, FIREWALL_EXPECTED=str(expected))
            self.assertNotEqual(r.returncode, 0)

    def test_failed_exclusion_or_mark_never_attaches_hook(self):
        for failure in ('-N AWG_OUTPUT', '--sport', '--dst-type', '--set-mark'):
            r = self.run_shell(self.setup_script(), ENABLED='1', PORT='51820', FAIL_AT=failure)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('-I OUTPUT', r.stdout)

    def health_script(self):
        return functions(RUNTIME, 'router_geo_enabled', 'router_transport_port', 'router_geo_healthy') + r'''
get_setting(){ echo "$ENABLED"; }
awg_mock(){ echo "$PORT"; }
AWG_BIN=awg_mock
IFACE=awg0
IPSET_NAME=awg_dst
FWMARK=0x100
iptables(){
    case "$*" in
        '-t mangle -S OUTPUT') printf '%s\n' "$HOOKS";;
        '-t mangle -S AWG_OUTPUT') [ "$CHAIN" = 1 ];;
        *'--sport '*) [ "$PORT" = "$RULE_PORT" ] && [ "$CHAIN" = 1 ];;
        *'--match-set '*) [ "$CHAIN" = 1 ];;
        *) return 1;;
    esac
}
'''

    def test_watchdog_health_detects_missing_duplicate_reordered_and_stale_rules(self):
        good = '-P OUTPUT ACCEPT\n-A OUTPUT -j AWG_OUTPUT\n-A OUTPUT -j MYAWG_CHAIN'
        for hooks, chain, rule_port, success in (
            (good, '1', '51820', True),
            ('-P OUTPUT ACCEPT\n-A OUTPUT -j MYAWG_CHAIN', '1', '51820', False),
            (good + '\n-A OUTPUT -j AWG_OUTPUT', '1', '51820', False),
            ('-A OUTPUT -j MYAWG_CHAIN\n-A OUTPUT -j AWG_OUTPUT', '1', '51820', False),
            (good, '0', '51820', False),
            (good, '1', '51821', False),
        ):
            r = self.run_shell(self.health_script() + '\nrouter_geo_healthy\n',
                               ENABLED='1', HOOKS=hooks, CHAIN=chain, PORT='51820', RULE_PORT=rule_port)
            self.assertEqual(r.returncode == 0, success, r.stderr)

    def test_disabled_health_rejects_leftover_chain(self):
        for chain in ('0', '1'):
            r = self.run_shell(self.health_script() + '\nrouter_geo_healthy\n',
                               ENABLED='0', HOOKS='-A OUTPUT -j MYAWG_CHAIN', CHAIN=chain)
            self.assertEqual(r.returncode == 0, chain == '0')

    def test_watchdog_repairs_output_without_restarting_healthy_tunnel(self):
        script = self.health_script() + '\n' + functions(MAIN, 'do_watchdog') + r'''
ip(){ return 0; }
pidof(){ echo 123; }
tunnel_healthy(){ return 0; }
main_firewall_healthy(){ router_geo_healthy; }
do_firewall_restart(){ echo repaired; HOOKS='-A OUTPUT -j AWG_OUTPUT'; CHAIN=1; }
log_msg(){ :; }
ensure_status_loop(){ :; }
save_and_set_rp_filter(){ :; }
ensure_ui_mark_nat(){ :; }
repair_aux_routing(){ :; }
do_stop(){ echo UNEXPECTED_STOP; }
do_start(){ echo UNEXPECTED_START; }
do_watchdog
'''
        r = self.run_shell(script, ENABLED='1', HOOKS='-A OUTPUT -j MYAWG_CHAIN', CHAIN='0', PORT='51820', RULE_PORT='51820')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'repaired')

    def test_rollback_restores_output_position_without_touching_antifilter(self):
        with tempfile.TemporaryDirectory() as d:
            snapshot = Path(d, 'snapshot')
            snapshot.write_text('*mangle\n:AWG_OUTPUT - [0:0]\n-A OUTPUT -j OTHER\n-A OUTPUT -j AWG_OUTPUT\n-A OUTPUT -j MYAWG_CHAIN\n-A AWG_OUTPUT -j RETURN\nCOMMIT\n')
            body = functions(RUNTIME, 'restore_owned_rules').replace('iptables-restore', 'iptables_restore')
            r = self.run_shell(body + '\niptables_restore(){ cat; }\nrestore_owned_rules "$SNAPSHOT"\n', SNAPSHOT=str(snapshot))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(':AWG_OUTPUT - [0:0]', r.stdout)
            self.assertIn('-I OUTPUT 2 -j AWG_OUTPUT', r.stdout)
            self.assertIn('-A AWG_OUTPUT -j RETURN', r.stdout)
            self.assertNotIn('MYAWG', r.stdout)
            self.assertNotIn('OTHER', r.stdout)
