"""Simulated firmware flushes; no host firewall or router is modified."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_recovery import functions, ROOT

RUNTIME = (ROOT / 'addon/awg-runtime.sh').read_text()

class FirewallEvents(unittest.TestCase):
    def probe(self, mode, pending=True, healthy=False):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'dns').write_text('active-dns\n')
            (root / 'include').write_text('active-include\n')
            (root / 'original-dns').write_text('rollback-dns\n')
            (root / 'original-include').write_text('rollback-include\n')
            if pending:
                (root / 'pending').touch()
            body = functions(RUNTIME, 'verify_firewall_after_events') + r'''
log_msg(){ echo "$*"; }
sleep(){ :; }
main_firewall_base_healthy(){ [ "$HEALTHY" = 1 ]; }
setup_firewall_body(){
    count=$((count+1))
    [ "$1" = "$D/retry_dns" ] && [ "$2" = "$D/retry_include" ] || return 9
    cmp -s "$1" "$DNSMASQ_AWG_CONF" || return 9
    cmp -s "$2" "$DNSMASQ_INCLUDE" || return 9
    case "$MODE" in
        recover) HEALTHY=1;;
        fail) return 7;;
        endless) : > "$FIREWALL_PENDING";;
        twice) if [ "$count" = 1 ]; then
                   : > "$FIREWALL_PENDING"
                   echo new-dns > "$DNSMASQ_AWG_CONF"
               else HEALTHY=1; fi;;
    esac
    return 0
}
count=0
verify_firewall_after_events "$D"
rc=$?
echo "rc=$rc rebuilds=$count"
exit "$rc"
'''
            result = subprocess.run(['sh'], input=body, text=True, capture_output=True,
                timeout=10, env=dict(os.environ, D=d, MODE=mode,
                    HEALTHY='1' if healthy else '0', FIREWALL_PENDING=d+'/pending',
                    DNSMASQ_AWG_CONF=d+'/dns', DNSMASQ_INCLUDE=d+'/include'))
            self.assertEqual((root/'original-dns').read_text(), 'rollback-dns\n')
            self.assertEqual((root/'original-include').read_text(), 'rollback-include\n')
            return result, (root/'pending').exists()

    def test_healthy_leaves_event_for_normal_replay(self):
        result, pending = self.probe('recover', healthy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rebuilds=0', result.stdout)
        self.assertTrue(pending)

    def test_failure_without_event_still_fails(self):
        result, _ = self.probe('recover', pending=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('rebuilds=0', result.stdout)

    def test_pending_flush_is_recovered(self):
        result, pending = self.probe('recover')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rebuilds=1', result.stdout)
        self.assertFalse(pending)

    def test_repeated_events_are_bounded(self):
        result, pending = self.probe('endless')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('rebuilds=2', result.stdout)
        self.assertTrue(pending)

    def test_rebuild_error_is_not_accepted(self):
        result, _ = self.probe('fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rebuilds=1', result.stdout)

    def test_failed_rebuild_without_new_event_is_not_retried(self):
        result, _ = self.probe('unhealthy')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('rebuilds=1', result.stdout)

    def test_second_retry_uses_latest_dns_without_changing_rollback(self):
        result, pending = self.probe('twice')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rebuilds=2', result.stdout)
        self.assertFalse(pending)

if __name__ == '__main__':
    unittest.main()
