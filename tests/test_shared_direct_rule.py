"""Shared policy-rule races and rollback; no real network is modified."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_recovery import functions, ROOT, MAIN

RUNTIME = (ROOT / 'addon/awg-runtime.sh').read_text()
DIRECT = '9: from all fwmark 0x101 lookup main\n'


class SharedDirectRule(unittest.TestCase):
    def probe(self, rules='', mode='create', body='ensure_direct_rule'):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'rules').write_text(rules)
            fake = root / 'ip'
            fake.write_text('''#!/bin/sh
case "$1 $2" in
    'rule show') [ "$MODE" != read-fail ] || exit 1; cat "$D/rules";;
    'rule add')
        echo "$*" >> "$D/adds"
        case "$MODE" in
            race) echo '9: from all fwmark 0x101 lookup main' >> "$D/rules"; echo 'File exists' >&2; exit 2;;
            conflict-race) echo '9: from all fwmark 0x101 lookup 300' >> "$D/rules"; exit 2;;
            fail) echo 'Permission denied' >&2; exit 2;;
            silent-fail) exit 0;;
            *) echo '9: from all fwmark 0x101 lookup main' >> "$D/rules";;
        esac;;
    *) exit 1;;
esac
''')
            fake.chmod(0o755)
            script = functions(RUNTIME, 'direct_rule_state', 'ensure_direct_rule') + r'''
DIRECT_MARK=0x101
find_external_program(){ echo "$D/ip"; }
ip(){
    # Match the Apply wrapper: an unchecked add failure would abort it.
    if [ "$1 $2" = 'rule add' ]; then echo unexpected-wrapper-add; exit 42; fi
    "$D/ip" "$@"
}
log_msg(){ echo "$*"; }
''' + '\n' + body + '\n'
            result = subprocess.run(['sh'], input=script, text=True,
                capture_output=True, timeout=10,
                env=dict(os.environ, D=d, MODE=mode))
            adds = (root / 'adds').read_text().splitlines() if (root / 'adds').exists() else []
            return result, adds, (root / 'rules').read_text()

    def test_existing_shared_rule_is_reused(self):
        for rule in (DIRECT, '9: from all fwmark 0x101/0xffffffff lookup 254\n'):
            with self.subTest(rule=rule):
                result, adds, after = self.probe(rule)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(adds, [])
                self.assertEqual(after, rule)

    def test_rule_is_created_once_across_rebuilds(self):
        result, adds, after = self.probe(body='ensure_direct_rule && ensure_direct_rule')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(adds), 1)
        self.assertEqual(after, DIRECT)

    def test_matching_concurrent_add_is_accepted(self):
        result, adds, after = self.probe(mode='race')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(adds), 1)
        self.assertEqual(after, DIRECT)

    def test_incompatible_rules_are_never_deleted_or_replaced(self):
        for rule in (
            '9: from all fwmark 0x101 lookup 300\n',
            '9: from all fwmark 0x101/0xff lookup main\n',
            '9: from 192.168.50.10 fwmark 0x101 lookup main\n',
            '9: from all fwmark 0x101 lookup main iif br0\n',
            '9: from all fwmark 0x101 lookup main suppress_prefixlength 0\n',
            DIRECT + DIRECT,
            DIRECT + '9: from all lookup 300\n',
        ):
            with self.subTest(rule=rule):
                result, adds, after = self.probe(rule)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(adds, [])
                self.assertEqual(after, rule)

    def test_add_failures_without_matching_rule_remain_failures(self):
        for mode in ('fail', 'silent-fail', 'conflict-race'):
            with self.subTest(mode=mode):
                result, adds, _ = self.probe(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(adds), 1)
                if mode == 'fail':
                    self.assertIn('Permission denied', result.stdout)

    def test_rule_read_error_never_adds(self):
        result, adds, _ = self.probe(mode='read-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(adds, [])

    def test_cleanup_retains_shared_rule_and_removes_awg_rules(self):
        with tempfile.TemporaryDirectory() as d:
            body = functions(MAIN, 'cleanup_firewall') + r'''
cleanup_router_geo(){ :; }
iptables(){ :; }
ipset(){ :; }
ip(){ echo "$*"; return 1; }
get_router_ip(){ echo 192.168.50.1; }
log_msg(){ :; }
cleanup_firewall
'''
            result = subprocess.run(['sh'], input=body, text=True, capture_output=True,
                env=dict(os.environ, CLIENTS_FILE=d+'/clients', RT_TABLE='300',
                    DIRECT_MARK='0x101', FWMARK='0x100', AWG_CHAIN='AWG',
                    IPSET_MIN_COUNT_FILE=d+'/min', DNSMASQ_AWG_CONF=d+'/dns',
                    DNSMASQ_INCLUDE=d+'/include'), timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('fwmark 0x101', result.stdout)
            self.assertIn('rule del lookup 300', result.stdout)
            self.assertIn('rule del fwmark 0x100', result.stdout)

    def test_apply_rollback_does_not_duplicate_shared_rule(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'geo').mkdir()
            body = functions(RUNTIME, 'setup_firewall').replace('iptables-save', 'iptables_save') + r'''
validate_runtime_settings(){ :; }
cancel_prefill(){ :; }
find_external_program(){ echo /bin/true; }
selected_geoip_services(){ :; }
prune_unselected_geoip_lists(){ :; }
preflight_geo(){ :; }
iptables_save(){ echo '*mangle'; echo COMMIT; }
ipset(){ return 1; }
ip(){
    case "$1 $2" in
        'rule show') printf '%s\n' '9: from all fwmark 0x101 lookup main' '98: from all fwmark 0x100 lookup 300';;
        'rule add') echo "$*" >> "$TRACE";;
    esac
    return 0
}
setup_firewall_body(){ return 1; }
cleanup_firewall(){ :; }
restore_owned_rules(){ :; }
restart_dnsmasq_and_wait(){ :; }
log_msg(){ :; }
setup_firewall
'''
            result = subprocess.run(['sh'], input=body, text=True, capture_output=True,
                env=dict(os.environ, GEO_DIR=d+'/geo', RT_TABLE='300',
                    DNSMASQ_AWG_CONF=d+'/dns', DNSMASQ_INCLUDE=d+'/include',
                    FIREWALL_EXPECTED=d+'/expected', IPSET_MIN_COUNT_FILE=d+'/min',
                    IPSET_NAME='awg_dst', TRACE=d+'/trace'), timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertNotIn('0x101', (root/'trace').read_text())
            self.assertIn('rule add priority 98', (root/'trace').read_text())


if __name__ == '__main__':
    unittest.main()
