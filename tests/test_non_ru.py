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
