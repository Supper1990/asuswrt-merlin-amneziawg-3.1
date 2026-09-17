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

    def active_config_case(self, previous_dns, current_dns,
                           previous_include, current_include, listener):
        with tempfile.TemporaryDirectory() as d:
            paths = {}
            for name, content in (
                    ('previous_dns', previous_dns), ('current_dns', current_dns),
                    ('previous_include', previous_include),
                    ('current_include', current_include)):
                paths[name] = str(Path(d, name))
                if content is not None:
                    Path(paths[name]).write_text(content)
            script = functions(MAIN, 'dnsmasq_listen_port',
                                'dnsmasq_listener_ready',
                                'optional_files_equal',
                                'dnsmasq_config_is_active') + r'''
netstat(){ printf '%s\n' "$LISTENER"; }
dnsmasq_config_is_active "$PREVIOUS_DNS" "$PREVIOUS_INCLUDE"
'''
            conf = Path(d, 'dnsmasq.conf')
            conf.write_text('port=553\n')
            return subprocess.run(
                ['/bin/sh'], input=script, text=True, capture_output=True,
                timeout=5, env=dict(os.environ, DNSMASQ_CONF=str(conf),
                                    DNSMASQ_AWG_CONF=paths['current_dns'],
                                    DNSMASQ_INCLUDE=paths['current_include'],
                                    PREVIOUS_DNS=paths['previous_dns'],
                                    PREVIOUS_INCLUDE=paths['previous_include'],
                                    LISTENER=listener))

    def test_unchanged_active_dnsmasq_config_skips_restart(self):
        result = self.active_config_case(
            'ipset=/example/awg_dst\n', 'ipset=/example/awg_dst\n',
            'conf-file=/jffs/awg.conf\n', 'conf-file=/jffs/awg.conf\n',
            'udp 0 0 127.0.0.1:553 0.0.0.0:* 202/dnsmasq')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_dnsmasq_config_requires_restart(self):
        result = self.active_config_case(
            'ipset=/old/awg_dst\n', 'ipset=/new/awg_dst\n',
            'conf-file=/jffs/awg.conf\n', 'conf-file=/jffs/awg.conf\n',
            'udp 0 0 127.0.0.1:553 0.0.0.0:* 202/dnsmasq')
        self.assertNotEqual(result.returncode, 0)

    def test_missing_listener_requires_restart_even_when_files_match(self):
        result = self.active_config_case(
            'ipset=/example/awg_dst\n', 'ipset=/example/awg_dst\n',
            'conf-file=/jffs/awg.conf\n', 'conf-file=/jffs/awg.conf\n',
            'udp 0 0 127.0.0.1:53 0.0.0.0:* 202/AdGuardHome')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
