import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_recovery import MAIN, functions


class WatchdogNewlines(unittest.TestCase):
    def test_dns_include_matches_watchdog_after_two_applies(self):
        with tempfile.TemporaryDirectory() as d:
            conf = Path(d, 'dnsmasq.conf.add')
            line = 'conf-file=/opt/amneziawg/dnsmasq_awg.conf'
            env = dict(os.environ, DNSMASQ_INCLUDE=str(conf), DNSMASQ_AWG_CONF=line.split('=')[1])
            for prefix in ('', 'port=553', 'port=553\n', '# disabled: '+line):
                conf.write_text(prefix)
                subprocess.run(['sh','-c',functions(MAIN,'ensure_dns_include')+
                                '\nensure_dns_include && ensure_dns_include'],env=env,check=True)
                self.assertEqual(conf.read_text().splitlines(),prefix.splitlines()+[line])

    def test_missing_last_rule_is_rejected_with_or_without_lf(self):
        # Exercise the actual final snapshot check; network preconditions are independent.
        body = functions(MAIN,'main_firewall_base_healthy').split('    [ -s "$FIREWALL_EXPECTED" ]',1)[1]
        probe = 'check(){\n    [ -s "$FIREWALL_EXPECTED" ]'+body+'\nmanaged_firewall_rules(){ printf "%s" "$ACTUAL"; }\ncheck'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, 'rules')
            for end in ('','\n'):
                p.write_text('first\nlast'+end)
                for actual, expected in [('first',1),('first\nlast',0)]:
                    result = subprocess.run(['sh','-c',probe],env=dict(os.environ,FIREWALL_EXPECTED=str(p),ACTUAL=actual))
                    self.assertEqual(result.returncode,expected)
