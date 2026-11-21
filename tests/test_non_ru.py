import ipaddress
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_recovery import MAIN, ROOT, functions

COMMON = (ROOT/'addon/awg-common.sh').read_text()

class NonRu(unittest.TestCase):
    def installed(self, count, policy="vpn_non_ru", extra=""):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'ru-direct.cidr').write_text('5.0.0.0/8\n')
            script = COMMON + '\n' + functions(MAIN,'setup_non_ru_default','country_mark_ingress','ru_country_set_healthy') + '''
ipset(){ case "$1" in list) echo "Number of entries: $COUNT";; esac; }
ipset_load_file(){ :; }
iptables(){ echo "$*"; }
get_setting(){ echo "$EXTRA"; }
setup_non_ru_default "$POLICY"
'''
            return subprocess.run(['sh','-c',script],text=True,capture_output=True,
                env=dict(os.environ,GEO_DIR=d,COUNT=str(count),IFACE='awg0',POLICY=policy,EXTRA=extra,AWG_CHAIN='AWG',IPSET_NAME='awg_dst',FWMARK='0x100'))

    def test_incomplete_country_set_never_installs_catchall(self):
        for count in (0,2):
            result=self.installed(count)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(result.stdout,'')

    def route_fn(self, policy, extra=''):
        r=self.installed(1, policy, extra)
        self.assertEqual(r.returncode,0,r.stderr)
        rules=[x.split()[4:] for x in r.stdout.splitlines()]
        def route(ip, iface='br0', mark='0', original=True, ipsec=False, src='10.77.0.9'):
            for args in rules:
                def arg(k): return args[args.index(k)+1]
                if '-i' in args:
                    f=arg('-i')
                    if not (iface.startswith(f[:-1]) if f.endswith('+') else iface==f): continue
                if '--pol' in args and not ipsec: continue
                if '--ctdir' in args and not original: continue
                if '--mark' in args:
                    at=args.index('--mark')
                    value,mask=arg('--mark').split('/')
                    match=int(mark,0) & int(mask,0) == int(value,0)
                    if match == (args[at-1]=='!'): continue
                if '-d' in args and ipaddress.ip_address(ip) not in ipaddress.ip_network(arg('-d')): continue
                if '-s' in args and ipaddress.ip_address(src) not in ipaddress.ip_network(arg('-s')): continue
                if '--match-set' in args:
                    match = ip=='5.1.2.3' if arg('--match-set')=='awg_dst' else ip.startswith('5.')
                    if match == ('!' in args): continue
                if 'RETURN' in args: break
                if 'MARK' in args: mark=args[-1]
            return mark
        return route

    def test_effective_policy(self):
        route=self.route_fn('vpn_non_ru')
        for addr,expected in [('5.1.2.3','0x100'),('5.2.2.2','0'),('8.8.8.8','0x100'),('10.94.216.10','0')]:
            self.assertEqual(route(addr),expected)
        for iface in ('awgs0','wgs1','tun21','ppp0','awg0'):
            self.assertEqual(route('8.8.8.8',iface),'0')
        self.assertEqual(route('8.8.8.8',mark='0x101'),'0x101')

    def test_vpn_ingress_scope_and_precedence(self):
        route=self.route_fn('vpn_non_ru_vpn','ipsec@10.77.0.0/24,tailscale0@100.64.1.0/24')
        for iface in ('awgs0','wgs1','tun21','tap22'):
            for ip,expected in [('5.1.2.3','0x100'),('5.2.2.2','0'),('8.8.8.8','0x100'),('10.94.216.10','0')]:
                self.assertEqual(route(ip,iface),expected)
            self.assertEqual(route('8.8.8.8',iface,mark='0x101'),'0x101')
            self.assertEqual(route('8.8.8.8',iface,original=False),'0')
        for iface in ('eth0','wgc1','tun11','ppp0','awg0','tailscale0'):
            self.assertEqual(route('8.8.8.8',iface),'0')
        self.assertEqual(route('8.8.8.8','eth0',ipsec=True),'0x100')
        self.assertEqual(route('8.8.8.8','eth0',ipsec=True,src='10.88.0.1'),'0')
        self.assertEqual(route('8.8.8.8','awg0',ipsec=True),'0')
        self.assertEqual(route('8.8.8.8','tailscale0',src='100.64.1.5'),'0x100')

    def test_refuses_unsafe_extra_selectors(self):
        for value in ['+@10.0.0.0/8','awg0@10.0.0.0/8','eth0@10.0.0.0/8',
                      'ipsec','ipsec@0.0.0.0/0','ppp+@10.0.0.0/8','tun11@10.0.0.0/8',
                      'ipsec@10.0.0.999/24','wgc1@1.2.3.4/32']:
            r=self.installed(1,'vpn_non_ru_vpn',value)
            self.assertNotEqual(r.returncode,0,value)

    def test_ipsec_firmware_mark(self):
        flag='0x08000000'
        pool='ipsec@10.77.0.0/24'
        route=self.route_fn('vpn_non_ru_vpn',pool)
        for addr,want in [('8.8.8.8','0x100'),('5.1.2.3','0x100'),('5.2.2.2',flag),('10.0.1.1',flag)]:
            self.assertEqual(route(addr,'eth0',mark=flag,ipsec=True),want)
        for kw in [dict(ipsec=False),dict(original=False),dict(src='10.88.0.1')]:
            self.assertEqual(route('8.8.8.8','eth0',mark=flag,**dict({'ipsec':True},**kw)),flag)
        for mark in ['0x101','0x08000101','0x66']:
            self.assertEqual(route('8.8.8.8','eth0',mark=mark,ipsec=True),mark)
        for policy,extra in [('vpn_non_ru',pool),('vpn_non_ru_vpn','')]:
            self.assertEqual(self.route_fn(policy,extra)('8.8.8.8','eth0',mark=flag,ipsec=True),flag)

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
        script = COMMON + '\n' + functions(MAIN, 'register_managed_cron') + '''
remove_managed_cron(){ :; }
antifilter_enabled(){ return 1; }
cru(){ echo "$*"; }
get_setting(){ case "$1" in awg_geo_autoupdate) echo "$AUTO";; awg_default_policy) echo "$POLICY";; esac; }
register_managed_cron
'''
        for policy, auto, job in [('vpn_non_ru','0','update_ru'), ('vpn_non_ru','1','update_geo'),
                                  ('vpn_non_ru_vpn','0','update_ru'), ('vpn_non_ru_vpn','1','update_geo'),
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
