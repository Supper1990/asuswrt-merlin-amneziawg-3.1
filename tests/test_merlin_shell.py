"""Regression: Merlin shell reported `command: not found` during Start."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest
from test_recovery import functions, ROOT

RUNTIME=(ROOT/'addon/awg-runtime.sh').read_text()

class MerlinShell(unittest.TestCase):
    def run_shell(self, script, env):
        return subprocess.run(['/bin/sh'], input=script, text=True, capture_output=True,
                              timeout=10, env=dict(os.environ, **env))

    def test_path_resolution_ignores_same_name_function(self):
        with tempfile.TemporaryDirectory() as d:
            exe=Path(d,'ip');exe.write_text('#!/bin/sh\necho external\n');exe.chmod(0o755)
            result=self.run_shell(functions(RUNTIME,'find_external_program')+'''
command(){ echo 'command unavailable' >&2; return 127; }
ip(){ echo RECURSION; return 1; }
resolved=$(find_external_program ip) || exit 1
"$resolved"
''',{'PATH':d})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,'external\n')

    def test_missing_executable_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            result=self.run_shell(functions(RUNTIME,'find_external_program')+'\nfind_external_program ip',{'PATH':d})
            self.assertEqual(result.returncode,1)

    def test_wrappers_run_without_command_and_keep_error_checks(self):
        wrappers='\n'.join(textwrap.dedent(re.search(r'^        '+name+r'\(\)\{.*?^        \}',RUNTIME,re.M|re.S).group()) for name in ('ip','iptables'))
        for mode,expected in [('success',0),('probe',1),('fail_route',42),('fail_rule',42)]:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as d:
                for name in ('ip','iptables'):
                    exe=Path(d,name)
                    exe.write_text('#!/bin/sh\necho "'+name+' $*" >> "$TRACE"\n[ "$MODE" = success ]\n')
                    exe.chmod(0o755)
                calls={'success':'ip route replace default dev awg0; iptables -t mangle -A AWG -j RETURN',
                       'probe':'iptables -t mangle -C AWG -j RETURN',
                       'fail_route':'ip route replace default dev awg0',
                       'fail_rule':'iptables -t mangle -A AWG -j RETURN'}
                result=self.run_shell(functions(RUNTIME,'find_external_program')+'''
command(){ echo 'command unavailable' >&2; return 127; }
log_msg(){ printf '%s\n' "$*" >&2; }
awg_ip_exec=$(find_external_program ip) || exit 2
awg_iptables_exec=$(find_external_program iptables) || exit 2
'''+wrappers+'\n'+calls[mode],{'PATH':d,'TRACE':d+'/trace','MODE':mode})
                self.assertEqual(result.returncode,expected,result.stderr)
                self.assertNotIn('command unavailable',result.stderr)
                self.assertTrue(Path(d,'trace').exists())
                if expected==42:self.assertIn('ERROR:',result.stderr)

if __name__=='__main__':unittest.main()
