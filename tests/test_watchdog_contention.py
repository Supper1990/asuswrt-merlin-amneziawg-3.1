"""Watchdog decisions with a busy, recovered or actually incomplete firewall."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

from test_recovery import MAIN, ROOT, functions

RUNTIME = (ROOT / 'addon/awg-runtime.sh').read_text()


class Contention(unittest.TestCase):
    def test_health_probe_waits_only_on_exit_four(self):
        script = functions(RUNTIME, 'health_iptables') + '''
iptables(){ return "$FIRST"; }
timeout(){ echo "$*"; return "$SECOND"; }
health_iptables -S OUTPUT
'''
        for first, second, expected in [(0, 1, 0), (1, 0, 1), (4, 0, 0), (4, 124, 124)]:
            r = subprocess.run(['sh'], input=script, capture_output=True, text=True,
                               env=dict(os.environ, FIRST=str(first), SECOND=str(second)))
            self.assertEqual(r.returncode, expected)
            self.assertEqual(r.stdout.strip(), '8 iptables -w -S OUTPUT' if first == 4 else '')

    def test_transient_and_persistent_failures(self):
        for recover, calls, healthy in [(1,1,True), (2,2,True), (3,3,True), (4,3,False)]:
            with tempfile.TemporaryDirectory() as d:
                script = functions(MAIN, 'watchdog_firewall_healthy').replace('/tmp/awg-health', d+'/awg-health') + '''
n=0
sleep(){ [ "$1" = 3 ] || exit 33; }
log_msg(){ :; }
main_firewall_healthy(){ n=$((n+1)); echo probe >> "$CALLS"; [ "$n" = "$RECOVER" ]; }
watchdog_firewall_healthy
'''
                count = Path(d, 'attempts')
                r = subprocess.run(['sh'], input=script, capture_output=True, text=True,
                                   env=dict(os.environ, CALLS=str(count), RECOVER=str(recover)))
                self.assertEqual(r.returncode == 0, healthy)
                self.assertEqual(len(count.read_text().splitlines()), calls)
                trace = Path(d, 'awg-health-last.log')
                self.assertEqual(trace.exists(), not healthy)
                if trace.exists():
                    self.assertEqual(trace.stat().st_mode & 0o077, 0)
