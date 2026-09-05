"""Audit regressions with simulated failures; never operate the host firewall."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from test_recovery import functions, MAIN, AUX, ROOT
COMMON=(ROOT/'addon/awg-common.sh').read_text()
RUNTIME=(ROOT/'addon/awg-runtime.sh').read_text()
UI=(ROOT/'addon/amneziawg_page.asp').read_text()

class Audit(unittest.TestCase):
    def shell(self, body, env=None):
        return subprocess.run(['sh'],input=body,text=True,capture_output=True,timeout=15,
                              env=dict(os.environ,**(env or {})))

    def test_cidr_validation_keeps_existing_output(self):
        for data in ['<html>Error</html>\n','1.2.3.4/33\n','999.1.1.1\n','1.2.3.4\nbad\n']:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as d:
                Path(d,'in').write_text(data);Path(d,'out').write_text('previous')
                result=self.shell(COMMON+'\nnormalize_cidrs "$D/in" "$D/out"',{'D':d})
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(Path(d,'out').read_text(),'previous')

    def test_cidr_canonicalization(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'in').write_text('1.2.3.129/24\n1.2.3.0/24\n8.8.8.8\n')
            result=self.shell(COMMON+'\nnormalize_cidrs "$D/in" "$D/out"',{'D':d})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(Path(d,'out').read_text(),'1.2.3.0/24\n8.8.8.8/32\n')

    def test_bad_download_keeps_geoip_cache(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'geoip').mkdir();cache=Path(d,'geoip/v2fly_test.cidr');cache.write_text('8.8.8.0/24\n')
            result=self.shell(COMMON+functions(MAIN,'download_geoip_service')+'''
valid_geo_service_name(){ :; }
log_msg(){ :; }
curl(){ printf '<html>error</html>\\n' > "$GEO_DIR/geoip/.dl_test.tmp"; }
download_geoip_service test
''',{'GEO_DIR':d})
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertEqual(cache.read_text(),'8.8.8.0/24\n')

    def test_geosite_attribute_syntax(self):
        for value, valid in [('google@cn', True), ('openai', True), ('../../tmp', False), ('openai@', False)]:
            result=self.shell(COMMON+'\nvalid_geosite_name "$VALUE"', {'VALUE':value})
            self.assertEqual(result.returncode==0,valid)

    def test_json_backslash_and_controls(self):
        text='VPN \\ foo "quoted"\nnext\ttab\rreturn'
        result=self.shell(COMMON+'\nprintf %s "$VALUE" | json_string',{'VALUE':text})
        self.assertEqual(json.loads(result.stdout),text)

    def test_aux_route_failure_is_failure(self):
        result=self.shell(functions(AUX,'ensure_routing')+'''
antifilter_allowed(){ :; }
ipset(){ :; }
log(){ :; }
ip(){ case "$1 $2" in 'route replace') return 1;; 'rule show') echo '10: from all fwmark 0x66 lookup 400';; esac; }
ensure_routing
''',{'MARK':'0x66','TABLE':'400'})
        self.assertEqual(result.returncode,1,result.stderr)

    def test_aux_rule_failure_is_sticky(self):
        result=self.shell(functions(AUX,'add_rule_once')+'''
ROUTING_FAILED=0
iptables(){ return 1; }
add_rule_once mangle MYAWG -j RETURN
[ "$ROUTING_FAILED" = 1 ]
''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_partial_aux_loss_above_old_floor_is_restored(self):
        for lost in (False,True):
            with self.subTest(lost=lost),tempfile.TemporaryDirectory() as d:
                cache=''.join(f'10.{i//256}.{i%256}.0/24\n' for i in range(1200))
                Path(d,'cache').write_text(cache)
                Path(d,'actual').write_text(cache if not lost else '\n'.join(cache.splitlines()[1:])+'\n')
                result=self.shell(COMMON+functions(AUX,'restore_from_cache_if_needed')+'''
set_members(){ LC_ALL=C sort -u "$D/actual"; }
log(){ :; }
full_rebuild_from_new_list(){ echo rebuilt; }
restore_from_cache_if_needed
''',{'D':d,'OLD_LIST':d+'/cache','NEW_LIST':d+'/new','RESTORE':d+'/restore'})
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),'rebuilt' if lost else '')

    def test_set_read_failure_not_hidden(self):
        result=self.shell(COMMON+'\nipset(){ return 1; }\nset_members test')
        self.assertNotEqual(result.returncode,0)

    def test_no_global_conntrack_flush(self):
        result=self.shell(functions(MAIN,'flush_conntrack')+'\nconntrack(){ echo touched; }\nflush_conntrack')
        self.assertEqual(result.stdout,'')

    def test_unknown_geosite_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'geoip').mkdir();Path(d,'v2fly_all.yml').write_text('lists:\n - name: "youtube"\n')
            result=self.shell(COMMON+functions(RUNTIME,'preflight_geo')+'''
selected_geoip_services(){ :; }
get_setting(){ [ "$1" = awg_geo_v2fly ] && echo typo; }
log_msg(){ :; }
preflight_geo
''',{'GEO_DIR':d})
            self.assertEqual(result.returncode,1,result.stderr)

    def test_operation_receipts_are_independent(self):
        with tempfile.TemporaryDirectory() as d:
            result=self.shell(COMMON+functions(RUNTIME,'operation_write')+'''
operation_write 123 running Apply
operation_write 456 failed Busy
operation_write 123 succeeded Apply
''',{'OP_FILE':d+'/awg_operation.htm'})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(Path(d,'awg_operation_123.htm').read_text())['state'],'succeeded')
            self.assertEqual(json.loads(Path(d,'awg_operation_456.htm').read_text())['state'],'failed')

    def test_firewall_failure_restores_old_set_and_dns(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'geo').mkdir();Path(d,'dns').write_text('old dns')
            env={'GEO_DIR':d+'/geo','DNSMASQ_AWG_CONF':d+'/dns','DNSMASQ_INCLUDE':d+'/include',
                 'IPSET_MIN_COUNT_FILE':d+'/min','FIREWALL_EXPECTED':d+'/expected','TRACE':d+'/trace'}
            result=self.shell(functions(RUNTIME,'setup_firewall').replace('iptables-save','iptables_save')+'''
validate_runtime_settings(){ :; }
cancel_prefill(){ :; }
preflight_geo(){ :; }
prune_unselected_geoip_lists(){ :; }
selected_geoip_services(){ :; }
iptables_save(){ echo '*mangle'; echo COMMIT; }
ip(){ :; }
ipset(){ case "$1" in save) echo 'old set';; restore) cat >> "$TRACE";; esac; }
log_msg(){ :; }
cleanup_firewall(){ rm -f "$DNSMASQ_AWG_CONF"; }
restore_owned_rules(){ echo restored-rules >> "$TRACE"; }
restart_dnsmasq_and_wait(){ :; }
setup_firewall_body(){ echo broken > "$DNSMASQ_AWG_CONF"; return 1; }
setup_firewall
''',env)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertEqual(Path(d,'dns').read_text(),'old dns')
            self.assertIn('old set',Path(d,'trace').read_text())
            self.assertIn('restored-rules',Path(d,'trace').read_text())

    def test_scoped_rollback_excludes_other_addons(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'snapshot').write_text('*mangle\n:AWG - [0:0]\n-A AWG -j RETURN\n-A PREROUTING -j AWG\n-A MYAWG_CHAIN -j RETURN\nCOMMIT\n*filter\n-A OTHER -j DROP\nCOMMIT\n')
            result=self.shell(functions(RUNTIME,'restore_owned_rules').replace('iptables-restore','iptables_restore')+'''
iptables_restore(){ cat; }
restore_owned_rules "$D/snapshot"
''',{'D':d})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('MYAWG',result.stdout)
            self.assertNotIn('OTHER',result.stdout)
            self.assertIn('-A AWG -j RETURN',result.stdout)

    def test_update_validates_rollback_before_stopping(self):
        self.package_scenario('missing_old')

    def test_update_failure_reinstalls_previous_package(self):
        self.package_scenario('install_fail')

    def package_scenario(self, mode):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'tmp').mkdir();Path(d,'settings').write_text('old settings')
            Path(d,'amneziawg.sh').write_text('#!/bin/sh\necho "$1" >> "$TRACE"\n')
            Path(d,'amneziawg.sh').chmod(0o755)
            body=functions(RUNTIME,'do_update').replace('/opt/bin/opkg','opkg_mock').replace('/tmp/',d+'/tmp/')
            result=self.shell(body+'''
acquire_lock(){ :; }
release_lock(){ :; }
log_msg(){ :; }
is_running(){ return 0; }
curl(){ echo '{"tag_name":"v2.2.0-18"}'; }
fetch_verified_package(){
    [ "$MODE" != missing_old ] || [ "$1" != 2.2.0-17 ] || return 1
    touch "$3/amneziawg_${1}_${2}.ipk"
}
opkg_mock(){
    if [ "$1" = status ]; then echo 'Version: 2.2.0-17'; echo 'Architecture: aarch64-3.10'; return 0; fi
    echo "$*" >> "$TRACE"
    [ "$2" = --force-downgrade ]
}
do_update
''',{'SETTINGS':d+'/settings','ADDON_DIR':d,'TRACE':d+'/trace','MODE':mode})
            self.assertEqual(result.returncode,1,result.stderr)
            if mode=='missing_old':
                self.assertFalse(Path(d,'trace').exists(), 'must not stop before rollback is available')
            else:
                trace=Path(d,'trace').read_text()
                self.assertIn('stop',trace)
                self.assertIn('--force-downgrade',trace)
                self.assertIn('install_page',trace)
                self.assertTrue(trace.endswith('start\n'),trace)

    def test_static_loss_cannot_be_hidden_by_dynamic_entries(self):
        for actual in ['', '9.9.9.9/32\n', '8.8.8.8/32\n9.9.9.9/32\n']:
            with self.subTest(actual=actual), tempfile.TemporaryDirectory() as d:
                Path(d,'expected').write_text('rules\n')
                Path(d,'static').write_text('8.8.8.8/32\n')
                Path(d,'dns').write_text('config\n')
                body=functions(RUNTIME,'main_firewall_healthy').replace('/tmp/.awg_static_members',d+'/static').replace('/tmp/.awg_dns_expected',d+'/dns')
                result=self.shell(body+'''
main_firewall_base_healthy(){ :; }
managed_firewall_rules(){ echo rules; }
set_members(){ printf '%s' "$ACTUAL"; }
main_firewall_healthy
''',{'FIREWALL_EXPECTED':d+'/expected','DNSMASQ_AWG_CONF':d+'/dns','ACTUAL':actual})
                self.assertEqual(result.returncode==0,actual.startswith('8.8.8.8'))

    def test_attach_recounts_awg_index_after_removal(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'chain').write_text('1 MYAWG_CHAIN\n2 AWG\n3 OTHER\n')
            result=self.shell(functions(AUX,'attach_chain_after_awg')+'''
delete_rule_all(){ printf '1 AWG\n2 OTHER\n' > "$D/chain"; }
iptables(){
    case " $* " in *' -L '*) cat "$D/chain";; *' -I '*) echo "$*";; esac
}
attach_chain_after_awg PREROUTING
''',{'D':d,'CHAIN':'MYAWG_CHAIN'})
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('-I PREROUTING 2 -j MYAWG_CHAIN',result.stdout)

    @unittest.skipUnless(shutil.which('node'), 'Node.js needed for browser logic test')
    def test_browser_validation_mac_and_operation_completion(self):
        source=re.search(r'<script>\s*(var custom_settings.*?)</script>',UI,re.S).group(1)
        source=re.sub(r'<%.*?%>','{}',source,flags=re.S)
        checks='''
const assert = require('assert');
assert(validIPv4('192.168.50.1'));
assert(!validIPv4('999.1.1.1'));
global.document={querySelectorAll:()=>[{querySelector:(q)=>({value:q==='.client_ip'?'192.168.50.2':q==='.client_name'?'phone':'direct'}),getAttribute:()=> 'aa:bb:cc:dd:ee:ff'}]};
assert(serializeClients().endsWith(',aa:bb:cc:dd:ee:ff'));
var pending, callback, completed=false, el={};
global.setTimeout=(f)=>{pending=f;};
global.refreshStatus=()=>{};
document.getElementById=()=>el;
document.form={action_script:{},submit:()=>{}};
global.XMLHttpRequest=function(){this.open=()=>{};this.send=()=>{callback=this;};};
submitOperation('start_awgdoupdate',()=>{completed=true;});
let id=document.form.action_script.value.split('_').pop();
pending();
callback.responseText=JSON.stringify({id,state:'running'});callback.onload();callback.onloadend();
assert(!completed);assert(activeOperation);
pending();callback.responseText=JSON.stringify({id,state:'succeeded'});callback.onload();callback.onloadend();
assert(completed);assert(!activeOperation);
'''
        result=subprocess.run(['node'],input=source+'\n'+checks,text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main()
