package main

// extraFixtures — дополнительные шаблоны поверх samplesrc.
// Форматы совпадают с парсерами network_monitor; IP будут подставлены генератором.
var extraFixtures = []struct {
	Vendor string
	Line   string
}{
	{Vendor: "fortigate", Line: `CEF:0|Fortinet|FortiGate|7.4|00013|traffic|5|src=10.10.5.42 dst=198.51.100.88 spt=52341 dpt=443 proto=6 act=accept app=HTTPS FTNTFGTpolicyid=12 FTNTFGTsrcintfrole=lan FTNTFGTdstintfrole=wan out=2048 in=8192 FTNTFGTeventtime=1700000100`},
	{Vendor: "fortigate", Line: `CEF:0|Fortinet|FortiGate|7.4|00014|traffic|4|src=203.0.113.44 dst=10.20.1.15 spt=41200 dpt=22 proto=6 act=deny app=SSH FTNTFGTpolicyid=99 FTNTFGTsrcintfrole=wan FTNTFGTdstintfrole=lan out=0 in=0 FTNTFGTeventtime=1700000200`},
	{Vendor: "usergate", Line: `CEF:0|UserGate|UGOS|7.2|100|Traffic|3|src=10.0.12.55 dst=203.0.113.90 spt=49152 dpt=53 act=allow proto=UDP rt=1700000300 cs1=DNS cs2=trust cs3=RU cs4=untrust out=128 in=256 cn1=1 cn2=1`},
	{Vendor: "usergate", Line: `CEF:0|UserGate|UGOS|7.2|100|Traffic|5|src=203.0.113.120 dst=10.0.12.80 spt=60001 dpt=3389 act=deny proto=TCP rt=1700000400 cs1=BlockRDP cs2=untrust cs3=CN cs4=trust out=0 in=0 cn1=0 cn2=0`},
	{Vendor: "cisco-asa", Line: `%ASA-6-302014: Teardown TCP connection 54321 for inside:10.1.1.50/52300 to outside:198.51.100.20/443 duration 0:05:12 bytes 1048576`},
	{Vendor: "cisco-asa", Line: `%ASA-4-106023: deny udp src outside:203.0.113.77/53 dst inside:10.1.2.10/33456 by access-group "OUTSIDE_IN" [0x0, 0x0]`},
	{Vendor: "cisco-asa", Line: `%ASA-6-106100: access-list acl_dmz denied tcp dmz/172.16.5.10(44000) -> inside/10.1.3.20(445) hit-cnt 3`},
	{Vendor: "cisco-ftd", Line: `%FTD-1-430002: EventPriority: Medium, DeviceUUID: def-456, FirstPacketSecond: 2024-01-15T10:22:00Z, ConnectionID: 99, SrcIP: 10.2.0.15, DstIP: 203.0.113.55, SrcPort: 52000, DstPort: 443, Protocol: tcp, IngressZone: inside, EgressZone: outside, AccessControlRuleAction: Allow, AccessControlRuleName: OutboundHTTPS, InitiatorBytes: 4096, ResponderBytes: 16384, InitiatorPackets: 20, ResponderPackets: 18`},
	{Vendor: "cisco-ftd", Line: `%FTD-4-313009: Denied ICMP type=8, for outside:203.0.113.66/0 (203.0.113.66/0) to inside:10.2.0.25/0`},
	{Vendor: "cowrie", Line: `{"eventid":"cowrie.session.connect","src_ip":"203.0.113.150","dst_ip":"10.0.50.10","src_port":54321,"dst_port":22,"protocol":"ssh","sensor":"honeypot2","timestamp":"2024-01-15T10:30:00.123456Z"}`},
	{Vendor: "cowrie", Line: `Jan 15 10:31:00 172.18.0.1 {'eventid': 'cowrie.login.failed', 'src_ip': '203.0.113.151', 'dst_ip': '10.0.50.11', 'src_port': 41000, 'dst_port': 22, 'protocol': 'ssh', 'sensor': 'hp3', 'username': 'admin'}`},
	{Vendor: "generic", Line: `src=10.50.1.100 dst=203.0.113.200 spt=60000 dpt=443 act=allow proto=tcp rule=AllowHTTPS out=5000 in=12000 cn1=10 cn2=20`},
	{Vendor: "generic", Line: `src=203.0.113.201 dst=10.50.2.50 spt=12345 dpt=445 act=deny proto=tcp rule=BlockSMB out=0 in=0 cn1=0 cn2=0`},
}
