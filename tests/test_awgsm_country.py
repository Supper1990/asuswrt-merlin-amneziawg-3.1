"""Test the optional server-manager contract without changing a live firewall."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_recovery import MAIN, ROOT, functions

RT = (ROOT / 'addon/awg-runtime.sh').read_text()


def shell(script, *args):
    return subprocess.run(['sh', '-c', script, 'test', *args],
                          text=True, capture_output=True, timeout=5)


class ServerCountry(unittest.TestCase):
    def test_contract_requires_opt_in_and_both_chains(self):
        body = functions(MAIN, 'awgsm_country_contract') + '\nawgsm_country_contract "$1"'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'manager.py'
            for data, ok in [(None, False), ('AWGSM_CM43 AWGSM_CF43', False),
                             ('# AWGSM_COUNTRY43: AWGSM_CM43', False),
                             ('# AWGSM_COUNTRY43:\nAWGSM_CM43\nAWGSM_CF43', True)]:
                if data is not None:
                    p.write_text(data)
                self.assertEqual(shell(body, str(p)).returncode == 0, ok)

    def test_cleanup_preserves_peer_hooks_in_either_boot_order(self):
        body = functions(MAIN, 'reset_awgsm_country') + """
trace=$2; rc=$3; FIREWALL_EXPECTED=/dev/null
iptables(){
    echo "$*" >> "$trace"
    case "$3" in -S) return "$rc";; esac
    return 0
}
AWGSM_COUNTRY_COMPAT=$1 reset_awgsm_country
"""
        with tempfile.TemporaryDirectory() as d:
            trace = Path(d)/'trace'
            for enabled, missing in [('0', '0'), ('1', '0'), ('1', '1')]:
                trace.write_text('')
                self.assertEqual(shell(body, enabled, str(trace), missing).returncode, 0)
                lines = trace.read_text().splitlines()
                expected = []
                if enabled == '1':
                    for table, chain in [('filter', 'AWGSM_CF43'), ('mangle', 'AWGSM_CM43')]:
                        for op in (['-S','-N','-F'] if missing == '1' else ['-S','-F']):
                            expected.append(f'-t {table} {op} {chain}')
                self.assertEqual(lines, expected)

    def test_classification_preserves_peer_permissions(self):
        r = shell(functions(MAIN, 'setup_awgsm_country') + """
iptables(){ echo "$*"; }
FWMARK=0x100 IFACE=awg0 AWG_CHAIN=AWG setup_awgsm_country
""")
        self.assertEqual(r.returncode, 0)
        rules = r.stdout.splitlines()
        self.assertTrue(all(s.endswith(' -j RETURN') for s in rules[:-2]))
        self.assertIn('-d 10.0.0.0/8 -j RETURN', '\n'.join(rules[:-2]))
        self.assertEqual(rules[-2:], [
            '-t filter -A AWGSM_CF43 -i awgs0 -o awg0 -m conntrack --ctdir ORIGINAL -m mark --mark 0x100/0xffffffff -m set ! --match-set awg_ru4 dst -j ACCEPT',
            '-t mangle -A AWGSM_CM43 -i awgs0 -m conntrack --ctdir ORIGINAL -m mark --mark 0/0xffffffff -j AWG'])

    def test_watchdog_and_rollback_own_only_chain_bodies(self):
        snapshot = """*mangle
-A AWGSM_MARK -s 192.0.2.1 -j AWGSM_CM43
-A AWGSM_CM43 -i awgs0 -j AWG
COMMIT
*filter
-A AWGSM_FW4 -s 192.0.2.1 -j AWGSM_CF43
-A AWGSM_CF43 -d 10.0.0.0/8 -j RETURN
COMMIT
"""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'snapshot'
            p.write_text(snapshot)
            for body in [
                functions(RT, 'restore_owned_rules').replace('iptables-restore','restore') +
                '\nrestore(){ cat; }\nAWGSM_COUNTRY_COMPAT=$2 restore_owned_rules "$1"',
                functions(MAIN, 'managed_firewall_rules').replace('iptables-save','save') +
                '\nsave(){ cat "$file"; }\nfile=$1 AWG_CHAIN=AWG AWGSM_COUNTRY_COMPAT=$2 managed_firewall_rules']:
                for enabled in ('0', '1'):
                    r = shell(body, str(p), enabled)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    for gate in ['AWGSM_CM43','AWGSM_CF43']:
                        self.assertEqual(gate in r.stdout, enabled == '1')
                    for parent in ['AWGSM_MARK','AWGSM_FW4']:
                        self.assertNotIn(parent, r.stdout)
