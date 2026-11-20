"""Exercise the IPv4 policy inputs without touching the host network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_recovery import functions, MAIN, ROOT

COMMON = (ROOT/'addon/awg-common.sh').read_text()
HELPERS = functions(COMMON,'valid_ipv4')+'\n'+functions(MAIN,'get_endpoint','clear_endpoint_route','refresh_endpoint_route')
STUBS = """
AWG_BIN=awg_mock
IFACE=awg0
awg_mock(){ [ "$*" = 'show awg0 endpoints' ] || return 2; printf 'key %s\\n' "$PEER"; }
ip(){ echo "$*" >> "$TRACE"; case "$*" in '-4 route show default') echo 'default via 192.0.2.1 dev eth0';; *'route add'*) return "$ADD_RC";; esac; }
iptables(){ echo "$*" >> "$TRACE"; }
"""


class Endpoint(unittest.TestCase):
    def test_live_address_controls_ipv4_exclusion_and_route_ownership(self):
        setup = functions(MAIN,'setup_firewall_body')
        start = setup.index('    local endpoint')
        end = setup.index('    # --- Per-device',start)
        probes = 'rules(){\n'+setup[start:end]+'\n:; }\nAWG_CHAIN=AWG\nrules\nrefresh_endpoint_route\nclear_endpoint_route'
        for peer, want4 in [('203.0.113.8:44440',True),('[2001:db8::8]:44440',False),
                            ('(none)',False),('vpn.example:44440',False),('999.0.0.1:44440',False)]:
            for add_rc in (0,2):
                with self.subTest(peer=peer,add_rc=add_rc),tempfile.TemporaryDirectory() as d:
                    trace=Path(d,'calls')
                    conf=Path(d,'peer.conf')
                    conf.write_text('Endpoint = vpn.example:44440\n')
                    subprocess.run(['sh','-c',HELPERS+'\n'+STUBS+'\n'+probes],check=True,
                                   env=dict(os.environ,PEER=peer,CONF=str(conf),ADD_RC=str(add_rc),
                                            TRACE=str(trace),ENDPOINT_ROUTE_STATE=d+'/owned'))
                    lines=trace.read_text().splitlines()
                    self.assertIn('-t mangle -A AWG -d 224.0.0.0/4 -j RETURN',lines)
                    self.assertEqual('-t mangle -A AWG -d 203.0.113.8 -j RETURN' in lines,want4)
                    self.assertEqual(any('route add' in x for x in lines),want4)
                    self.assertEqual(any('route del' in x for x in lines),want4 and add_rc==0)
                    self.assertFalse(any('vpn.example' in x or '2001:db8' in x for x in lines))
