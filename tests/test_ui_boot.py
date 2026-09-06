"""Web UI recovery without router mounts, daemon startup or network access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_recovery import functions, ROOT
MAIN=(ROOT/'addon/amneziawg.sh').read_text()
UI_FUNCTIONS=functions(MAIN,'mount_menu_tree','ui_ready','ui_mount_once','do_mount_ui','acquire_lock','release_lock')

class UIBoot(unittest.TestCase):
    def fixture(self, d):
        root=Path(d)
        for name in ('addon','web','geo','main-lock'):(root/name).mkdir()
        (root/'main-lock/pid').write_text(str(os.getpid()))
        (root/'addon/amneziawg_page.asp').write_text('<title>AmneziaWG</title>\nnew page\n')
        (root/'menu').write_text('{url: "Advanced_VPN_OpenVPN.asp", tabName: "OpenVPN"},\n{url: "other.asp", tabName: "Other addon"},\n')
        (root/'helper').write_text('am_get_webui_page(){ am_webui_page=user3.asp; return 1; }\n')
        return dict(ADDON_DIR=d+'/addon',UI_WEB_DIR=d+'/web',GEO_DIR=d+'/geo',UI_MENU_FILE=d+'/menu',
                    UI_MENU_CACHE=d+'/cache',UI_HELPER=d+'/helper',UI_LOCKDIR=d+'/ui-lock',LOCKDIR=d+'/main-lock',
                    TRACE=d+'/trace',D=d,DISPATCH_LOCK='1')

    def shell(self, body, env):
        stubs='''
package_busy(){ return 1; }
log_msg(){ printf '%s\\n' "$*" >> "$TRACE"; }
cru(){ printf 'cron %s\\n' "$*" >> "$TRACE"; }
ensure_status_loop(){ :; }
do_start(){ echo UNEXPECTED_START >> "$TRACE"; return 1; }
umount(){ :; }
mount(){ printf 'mount\\n' >> "$TRACE"; cp "$3" "$4"; }
'''
        return subprocess.run(['/bin/sh'],input=UI_FUNCTIONS+stubs+body,env=dict(os.environ,**env),
                              text=True,capture_output=True,timeout=10)

    def test_mount_does_not_wait_for_main_lock_or_start_tunnel(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            result=self.shell('\ndo_mount_ui\n',env)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(Path(d,'web/user3.asp').exists())
            self.assertEqual(Path(d,'main-lock/pid').read_text(),str(os.getpid()))
            self.assertFalse(Path(d,'ui-lock').exists())
            trace=Path(d,'trace').read_text()
            self.assertNotIn('UNEXPECTED_START',trace)
            self.assertIn('awg_ui_watchdog',trace)
            self.assertIn('Other addon',Path(d,'menu').read_text())

    def test_repeated_mount_reuses_page_and_does_not_rebind(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            result=self.shell('\ndo_mount_ui && do_mount_ui\n',env)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(len(list(Path(d,'web').glob('user*.asp'))),1)
            self.assertEqual(Path(d,'menu').read_text().count('tabName: "AmneziaWG"'),1)
            self.assertEqual(Path(d,'trace').read_text().splitlines().count('mount'),1)

    def test_late_httpd_readiness_is_retried(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            Path(d,'menu').rename(Path(d,'menu-later'))
            result=self.shell('''
sleep(){ cp "$D/menu-later" "$UI_MENU_FILE"; }
do_mount_ui
''',env)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(Path(d,'web/user3.asp').exists())

    def test_menu_reset_is_repaired_without_replacing_page(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            result=self.shell('''
do_mount_ui || exit 1
printf '{url: "Advanced_VPN_OpenVPN.asp", tabName: "OpenVPN"},\\n' > "$UI_MENU_FILE"
do_mount_ui
''',env)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('tabName: "AmneziaWG"',Path(d,'menu').read_text())
            self.assertEqual(Path(d,'trace').read_text().splitlines().count('mount'),2)

    def test_missing_anchor_preserves_existing_menu_and_page(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            Path(d,'menu').write_text('Other addon menu without expected anchor\n')
            Path(d,'web/user3.asp').write_bytes(Path(d,'addon/amneziawg_page.asp').read_bytes())
            result=self.shell('sleep(){ :; }\ndo_mount_ui\n',env)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertEqual(Path(d,'menu').read_text(),'Other addon menu without expected anchor\n')
            self.assertTrue(Path(d,'web/user3.asp').exists())
            self.assertNotIn('mount\n',Path(d,'trace').read_text())
            self.assertIn('UI watchdog will retry',Path(d,'trace').read_text())

    def test_failed_bind_restores_previous_menu(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d);old=Path(d,'menu').read_text()
            result=self.shell('''
mount(){
    if [ ! -f "$D/failed" ]; then touch "$D/failed"; return 1; fi
    cp "$3" "$4"
}
ui_mount_once
''',env)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertEqual(Path(d,'menu').read_text(),old)

    def test_stale_ui_lock_recovered(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.fixture(d)
            Path(d,'ui-lock').mkdir();Path(d,'ui-lock/pid').write_text('2147483647')
            result=self.shell('\ndo_mount_ui\n',env)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertFalse(Path(d,'ui-lock').exists())

if __name__=='__main__':unittest.main()
