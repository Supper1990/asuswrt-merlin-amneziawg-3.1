import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'addon/awg-runtime.sh'

class DNSWorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.procs = []
        self.lock = self.root / 'lock'
        self.pending = self.root / 'pending'
        self.script = self.root / 'amneziawg.sh'
        source = SOURCE.read_text().replace('/tmp/.awg_dns_pending', str(self.pending))
        (self.root / 'runtime.sh').write_text(source)
        (self.root / 'dns.conf').write_text('ipset=/one.example/two.example/awg_dst\n')
        self.script.write_text('#!/bin/sh\n' +
            'DNS_PREFILL_LOCK=' + shlex.quote(str(self.lock)) + '\n' +
            'DNSMASQ_AWG_CONF=' + shlex.quote(str(self.root / 'dns.conf')) + '\n' +
            '. ' + shlex.quote(str(self.root / 'runtime.sh')) + '\n' +
            '''log_msg(){ echo "$*"; }
update_status(){ :; }
# Executor host /proc uses different PIDs: mock only process inspection.
# Child processes, signals, waits and lock handling below remain real.
prefill_process_active(){ kill -0 "$1" 2>/dev/null; }
prefill_worker_owned(){ [ "$1" = "$(cat "$DNS_PREFILL_LOCK/test_owner" 2>/dev/null)" ]; }
"$@"
''')
        self.script.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root)+':'+os.environ['PATH'])
    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
        self.tmp.cleanup()
    def run_cmd(self, *args):
        return subprocess.run([str(self.script), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)
    def start(self, slow=True):
        query = self.root / 'nslookup'
        query.write_text('#!/bin/sh\necho $$ > '+shlex.quote(str(self.root/'query.pid'))+'\n' +
                         ('exec sleep 60\n' if slow else 'exit 0\n'))
        query.chmod(0o755)
        self.pending.touch()
        p = subprocess.Popen([str(self.script), 'prefill_worker'], env=self.env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        for _ in range(150):
            if self.lock.exists():
                (self.lock/'test_owner').write_text(str(p.pid))
                break
            time.sleep(.01)
        return p
    def await_query(self):
        for _ in range(150):
            if (self.root/'query.pid').exists():
                return int((self.root/'query.pid').read_text())
            time.sleep(.02)
        self.fail('Query did not start')
    def test_cancel_active_query_and_repeat(self):
        for _ in range(2):
            (self.root/'query.pid').unlink(missing_ok=True)
            p = self.start()
            query = self.await_query()
            result = self.run_cmd('cancel_prefill')
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual(p.wait(timeout=3), 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(query, 0)
            self.assertFalse(self.lock.exists())
            self.assertFalse(self.pending.exists())
    def test_normal_completion(self):
        p = self.start(False)
        self.assertEqual(p.wait(timeout=5), 0)
        self.assertFalse(self.lock.exists())
    def test_query_timeout(self):
        p = self.start()
        query = self.await_query()
        # Cancel subsequent domains; a single query must be bounded as well.
        (self.root/'dns.conf').write_text('ipset=/one.example/awg_dst\n')
        # Existing snapshot has two domains, so allow both bounded timeouts.
        self.assertEqual(p.wait(timeout=22), 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(query, 0)
        self.assertFalse(self.lock.exists())
    def test_unrelated_owner_not_signalled(self):
        p = subprocess.Popen(['sleep', '60'])
        self.procs.append(p)
        self.lock.mkdir()
        (self.lock/'pid').write_text(str(p.pid))
        result = self.run_cmd('cancel_prefill')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(p.poll())
    def test_proc_state_and_identity(self):
        root = self.root/'proc'
        proc = root/'123'
        proc.mkdir(parents=True)
        runtime = self.root/'parser.sh'
        runtime.write_text(SOURCE.read_text().replace('/proc/', str(root)+'/'))
        def check(function):
            return subprocess.run(['/bin/sh', '-c', '. "$1"; "$2" 123',
                                   'test', str(runtime), function]).returncode
        (proc/'stat').write_text('123 (name with ) spaces) Z 1 2 3\n')
        self.assertNotEqual(check('prefill_process_active'), 0)
        (proc/'stat').write_text('123 (amneziawg.sh) S 1 2 3\n')
        self.assertEqual(check('prefill_process_active'), 0)
        (proc/'cmdline').write_bytes(b'/bin/sh\x00/jffs/addons/amneziawg/amneziawg.sh\x00prefill_worker\x00')
        self.assertEqual(check('prefill_worker_owned'), 0)
        (proc/'cmdline').write_bytes(b'sleep\x0060\x00')
        self.assertNotEqual(check('prefill_worker_owned'), 0)
    def test_idle_worker_does_not_create_lock(self):
        self.assertEqual(self.run_cmd('prefill_worker').returncode, 0)
        self.assertFalse(self.lock.exists())
