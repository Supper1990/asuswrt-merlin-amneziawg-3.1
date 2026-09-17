"""dnsmasq readiness must probe Merlin's real listener, not another DNS service."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_recovery import functions, MAIN


class DnsmasqRestart(unittest.TestCase):
    def run_case(self, config, listener, timeout='1'):
        with tempfile.TemporaryDirectory() as d:
            conf = Path(d, 'dnsmasq.conf')
            state = Path(d, 'restarted')
            conf.write_text(config)
            script = functions(MAIN, 'dnsmasq_listen_port',
                                'dnsmasq_listener_ready',
                                'restart_dnsmasq_and_wait') + r'''
pidof(){ if [ -f "$STATE" ]; then echo 202; else echo 101; fi; }
service(){ touch "$STATE"; }
sleep(){ :; }
netstat(){ printf '%s\n' "$LISTENER"; }
log_msg(){ printf '%s\n' "$*" >&2; }
restart_dnsmasq_and_wait "$TIMEOUT"
'''
            return subprocess.run(['/bin/sh'], input=script, text=True,
                                  capture_output=True, timeout=5,
                                  env=dict(os.environ, DNSMASQ_CONF=str(conf),
                                           LISTENER=listener, TIMEOUT=timeout,
                                           STATE=str(state)))

    def test_custom_port_listener_is_accepted(self):
        result = self.run_case('port=553\n',
                               'tcp 0 0 127.0.0.1:553 0.0.0.0:* LISTEN 101/dnsmasq')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_service_on_port_53_does_not_mask_missing_dnsmasq_553(self):
        result = self.run_case('port=553\n',
                               'tcp 0 0 127.0.0.1:53 0.0.0.0:* LISTEN 202/AdGuardHome')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restart timeout', result.stderr)

    def test_default_port_is_53(self):
        result = self.run_case('domain-needed\n',
                               'udp 0 0 0.0.0.0:53 0.0.0.0:* 202/dnsmasq')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_or_disabled_port_is_rejected(self):
        for config in ('port=0\n', 'port=bad\n', 'port=70000\n'):
            with self.subTest(config=config):
                result = self.run_case(config,
                    'tcp 0 0 127.0.0.1:553 0.0.0.0:* LISTEN 101/dnsmasq')
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
