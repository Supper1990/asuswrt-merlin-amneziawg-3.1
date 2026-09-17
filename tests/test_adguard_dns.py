"""AdGuard Home integration tests; no router service is changed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_recovery import functions, MAIN


RENDER = functions(MAIN, 'render_adguard_dns_config')
ENSURE = functions(MAIN, 'ensure_adguard_dns')


class AdGuardDns(unittest.TestCase):
    def shell(self, body, env=None):
        return subprocess.run(['/bin/sh'], input=body, text=True,
                              capture_output=True, timeout=10,
                              env=dict(os.environ, **(env or {})))

    def render(self, config, port='553'):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, 'AdGuardHome.yaml')
            path.write_text(config)
            result = self.shell(RENDER + '\nrender_adguard_dns_config "$CFG" "$PORT"\n',
                                {'CFG': str(path), 'PORT': port})
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_correct_configuration_is_byte_identical(self):
        config = """http:\n  address: 0.0.0.0:3000
dns:
  port: 53
  upstream_dns:
    - '[/lan/][::]:553'
    - '[//][::]:553'
    - 127.0.0.1:553
  upstream_dns_file: ""
  bootstrap_dns:
    - 77.88.8.8
  fallback_dns:
    - 77.88.8.1
  local_ptr_upstreams:
    - '[::]:553'
    - '[/168.192.in-addr.arpa/][::]:553'
filters: []
"""
        self.assertEqual(self.render(config), config)

    def test_equivalent_quotes_do_not_force_rewrite(self):
        config = """dns:
  upstream_dns:
    - '127.0.0.1:553'
  upstream_dns_file: ''
"""
        self.assertEqual(self.render(config), config)

    def test_replaces_only_dns_upstreams_and_preserves_fallbacks(self):
        config = """dns:
  upstream_dns:
    - '[/lan/][::]:53'
    - 8.8.8.8
    - tls://1.1.1.1
  upstream_dns_file: /opt/etc/upstreams.txt
  bootstrap_dns:
    - 77.88.8.8
  fallback_dns:
    - tcp://77.88.8.1
  local_ptr_upstreams:
    - '[/168.192.in-addr.arpa/][::]:53'
filters: []
"""
        rendered = self.render(config)
        self.assertIn("    - '[/lan/][::]:553'", rendered)
        self.assertIn('    - 127.0.0.1:553', rendered)
        self.assertEqual(rendered.count('    - 127.0.0.1:553'), 1)
        self.assertNotIn('8.8.8.8', rendered)
        self.assertNotIn('tls://1.1.1.1', rendered)
        self.assertIn('  upstream_dns_file: ""', rendered)
        self.assertIn('    - 77.88.8.8', rendered)
        self.assertIn('    - tcp://77.88.8.1', rendered)
        self.assertIn("    - '[/168.192.in-addr.arpa/][::]:553'", rendered)

    def test_missing_upstream_is_added_inside_dns_section(self):
        rendered = self.render('dns:\n  port: 53\nfilters: []\n')
        self.assertEqual(rendered,
                         'dns:\n  port: 53\n  upstream_dns:\n'
                         '    - 127.0.0.1:553\nfilters: []\n')

    def test_detects_owner_and_active_config_argument(self):
        with tempfile.TemporaryDirectory() as d:
            proc = Path(d, 'proc', '10346')
            proc.mkdir(parents=True)
            cfg = '/opt/etc/AdGuardHome/AdGuardHome.yaml'
            (proc / 'cmdline').write_bytes(
                b'AdGuardHome\0-s\0run\0-c\0' + cfg.encode() + b'\0-w\0/opt/etc/AdGuardHome\0')
            body = functions(MAIN, 'adguard_dns_pid', 'adguard_active_config') + r'''
netstat(){
    printf '%s\n' 'tcp 0 0 :::53 :::* LISTEN 10346/AdGuardHome'
}
pid=$(adguard_dns_pid) || exit 1
printf '%s\n' "$pid"
adguard_active_config "$pid"
'''
            result = self.shell(body, {'ADGUARD_PROC_ROOT': str(Path(d, 'proc'))})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['10346', cfg])

    def test_absent_adguard_is_a_noop(self):
        result = self.shell(ENSURE + r'''
adguard_dns_pid(){ return 0; }
log_msg(){ echo UNEXPECTED; }
ensure_adguard_dns
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_lifecycle_hooks_call_integration(self):
        for name in ('setup_firewall_body', 'do_start', 'do_watchdog',
                     'do_install_page'):
            with self.subTest(function=name):
                self.assertIn('ensure_adguard_dns', functions(MAIN, name))

    def ensure_fixture(self, config, port='553', wait='success'):
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        cfg = root / 'AdGuardHome.yaml'
        trace = root / 'trace'
        init = root / 'S99AdGuardHome'
        cfg.write_text(config)
        init.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$TRACE"\n')
        init.chmod(0o755)
        body = RENDER + '\n' + ENSURE + r'''
adguard_dns_pid(){ echo 10346; }
adguard_active_config(){ echo "$CFG"; }
dnsmasq_listen_port(){ echo "$PORT"; }
wait_for_pid_exit(){ return 0; }
log_msg(){ printf '%s\n' "$*" >> "$LOG"; }
'''
        if wait == 'success':
            body += 'wait_for_adguard_dns(){ return 0; }\n'
        else:
            body += r'''
WAIT_COUNT=0
wait_for_adguard_dns(){
    WAIT_COUNT=$((WAIT_COUNT + 1))
    [ "$WAIT_COUNT" -ge 2 ]
}
'''
        body += 'ensure_adguard_dns\n'
        env = {'CFG': str(cfg), 'PORT': port, 'TRACE': str(trace),
               'LOG': str(root / 'log'), 'ADGUARD_INIT': str(init)}
        return temp, cfg, trace, self.shell(body, env)

    def test_correct_config_does_not_restart_adguard(self):
        config = 'dns:\n  upstream_dns:\n    - 127.0.0.1:553\n  upstream_dns_file: ""\n'
        temp, cfg, trace, result = self.ensure_fixture(config)
        try:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(cfg.read_text(), config)
            self.assertFalse(trace.exists())
        finally:
            temp.cleanup()

    def test_wrong_config_is_updated_with_one_stop_start(self):
        config = 'dns:\n  upstream_dns:\n    - 8.8.8.8\n  fallback_dns:\n    - 77.88.8.1\n'
        temp, cfg, trace, result = self.ensure_fixture(config)
        try:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(trace.read_text().splitlines(), ['stop', 'start'])
            updated = cfg.read_text()
            self.assertIn('    - 127.0.0.1:553', updated)
            self.assertNotIn('8.8.8.8', updated)
            self.assertIn('77.88.8.1', updated)
        finally:
            temp.cleanup()

    def test_failed_start_restores_original_config(self):
        config = 'dns:\n  upstream_dns:\n    - 8.8.8.8\n'
        temp, cfg, trace, result = self.ensure_fixture(config, wait='rollback')
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cfg.read_text(), config)
            self.assertEqual(trace.read_text().splitlines(),
                             ['stop', 'start', 'stop', 'start'])
        finally:
            temp.cleanup()

    def test_port_53_conflict_is_rejected_without_restart(self):
        config = 'dns:\n  upstream_dns:\n    - 8.8.8.8\n'
        temp, cfg, trace, result = self.ensure_fixture(config, port='53')
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cfg.read_text(), config)
            self.assertFalse(trace.exists())
        finally:
            temp.cleanup()


if __name__ == '__main__':
    unittest.main()
