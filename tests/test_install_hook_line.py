import subprocess
import tempfile
import unittest
from pathlib import Path
from test_recovery import functions, MAIN


class HookInstall(unittest.TestCase):
    def test_install_twice_with_or_without_final_lf(self):
        for original in (None, b'#!/bin/sh\n# user comment', b'#!/bin/sh\necho existing', b'#!/bin/sh\necho existing\n'):
            with self.subTest(original=original), tempfile.TemporaryDirectory() as d:
                hook = Path(d) / 'hook'
                if original is not None:
                    hook.write_bytes(original)
                body = functions(MAIN, 'install_hook_line') + """
set -e
install_hook_line "$1" 'echo amneziawg'
install_hook_line "$1" 'echo amneziawg'
"""
                subprocess.run(['sh','-c',body,'sh',str(hook)],check=True)
                self.assertTrue(hook.read_bytes().startswith(original or b'#!/bin/sh\n'))
                output = subprocess.check_output(['sh',str(hook)],text=True)
                expected = 'existing\n' if original and b'echo existing' in original else ''
                self.assertEqual(output, expected+'amneziawg\n')
