import ipaddress
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_recovery import MAIN, ROOT, functions

class NonRu(unittest.TestCase):
    def installed(self, count):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'ru-direct.cidr').write_text('5.0.0.0/8\n')
            script = functions(MAIN,'setup_non_ru_default','ru_country_set_healthy') + '''
ipset(){ case "$1" in list) echo "Number of entries: $COUNT";; esac; }
ipset_load_file(){ :; }
iptables(){ echo "$*"; }
setup_non_ru_default
'''
            return subprocess.run(['sh','-c',script],text=True,capture_output=True,
                env=dict(os.environ,GEO_DIR=d,COUNT=str(count),AWG_CHAIN='AWG',IPSET_NAME='awg_dst',FWMARK='0x100'))

    def test_incomplete_country_set_never_installs_catchall(self):
        for count in (0,2):
            result=self.installed(count)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(result.stdout,'')

    def test_effective_policy(self):
        r=self.installed(1)
        self.assertEqual(r.returncode,0,r.stderr)
        rules=[x.split()[4:] for x in r.stdout.splitlines()]
        def route(ip, iface='br0', mark='0'):
            for args in rules:
                if '-i' in args and iface==args[args.index('-i')+1]: continue
                if '--mark' in args and mark=='0': continue
                if '-d' in args and ipaddress.ip_address(ip) not in ipaddress.ip_network(args[args.index('-d')+1]): continue
                if '--match-set' in args:
                    name=args[args.index('--match-set')+1]
                    if name=='awg_dst' and ip!='5.1.2.3': continue
                    if name=='awg_ru4' and not ip.startswith('5.'): continue
                if 'RETURN' in args: break
                if 'MARK' in args: mark=args[-1]
            return mark
        for addr,expected in [('5.1.2.3','0x100'),('5.2.2.2','0'),('8.8.8.8','0x100'),('10.94.216.10','0')]:
            self.assertEqual(route(addr),expected)
        self.assertEqual(route('8.8.8.8','awg0'),'0')
        self.assertEqual(route('8.8.8.8',mark='0x101'),'0x101')

    def test_invalid_country_cache_refused_before_apply(self):
        common=(ROOT/'addon/awg-common.sh').read_text()
        runtime=(ROOT/'addon/awg-runtime.sh').read_text()
        with tempfile.TemporaryDirectory() as d:
            script=common+'\n'+functions(runtime,'preflight_geo')+'''
get_setting(){ [ "$1" != awg_default_policy ] || echo vpn_non_ru; }
selected_geoip_services(){ :; }
log_msg(){ :; }
preflight_geo
'''
            for content,ok in [('',False),('bad-data\n',False),('0.0.0.0/0\n',False),('5.0.0.0/8\n',True)]:
                Path(d,'ru-direct.cidr').write_text(content)
                r=subprocess.run(['sh','-c',script],env=dict(os.environ,GEO_DIR=d),capture_output=True)
                self.assertEqual(r.returncode==0,ok)

    def test_cron_runs_one_daily_job_for_country_mode(self):
        script = functions(MAIN, 'register_managed_cron') + '''
remove_managed_cron(){ :; }
antifilter_enabled(){ return 1; }
cru(){ echo "$*"; }
get_setting(){ case "$1" in awg_geo_autoupdate) echo "$AUTO";; awg_default_policy) echo "$POLICY";; esac; }
register_managed_cron
'''
        for policy, auto, job in [('vpn_non_ru','0','update_ru'), ('vpn_non_ru','1','update_geo'),
                                  ('vpn_geo','0',None), ('vpn_geo','1','update_geo')]:
            result = subprocess.check_output(['sh','-c',script], text=True,
                     env=dict(os.environ,POLICY=policy,AUTO=auto))
            jobs = [x.split()[-1] for x in result.splitlines() if '0 4 * * *' in x]
            self.assertEqual(jobs, [job] if job else [])

    def test_country_only_refresh_keeps_previous_set_and_cache_on_error(self):
        script = (ROOT/'addon/awg-common.sh').read_text() + '\n' + functions(
            MAIN, 'download_geoip_service', 'update_ru_country') + '''
get_setting(){ echo vpn_non_ru; }
is_running(){ return 0; }
log_msg(){ :; }
valid_geo_service_name(){ return 0; }
curl(){ for last do :; done; cat "$GEO_DIR/response" > "$last"; }
ipset_load_file(){ cp "$1" "$GEO_DIR/next"; }
ipset(){
    case "$1" in
    create|destroy) :;;
    list) echo "Number of entries: $COUNT";;
    swap) printf 'swap\\n' >> "$GEO_DIR/swaps";;
    *) return 1;;
    esac
}
update_ru_country
'''
        for content, count, ok in [('5.0.0.0/8\n',1,True),('bad\n',1,False),
                                   ('0.0.0.0/0\n',1,False),('5.0.0.0/8\n',0,False)]:
            with tempfile.TemporaryDirectory() as d:
                root=Path(d)
                cache=root/'ru-direct.cidr'
                cache.write_text('1.0.0.0/8\n')
                (root/'response').write_text(content)
                r=subprocess.run(['sh','-c',script],capture_output=True,text=True,
                                 env=dict(os.environ,GEO_DIR=d,COUNT=str(count)))
                self.assertEqual(r.returncode==0,ok,r.stderr)
                self.assertEqual(cache.read_text(),content if ok else '1.0.0.0/8\n')
                self.assertEqual((root/'swaps').exists(),ok)
