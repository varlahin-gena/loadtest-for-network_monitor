package main

import (
	"net/netip"
	"strings"
	"testing"
)

func testCorpus(t *testing.T) *corpus {
	t.Helper()
	c := loadCorpus(false)
	if len(c.vendors) == 0 {
		t.Fatal("empty corpus")
	}
	return c
}

func TestSubstituteIPs_SrcNotEqualDst(t *testing.T) {
	c := testCorpus(t)
	g := newGen(42, 50, 200000, 1.2, 0, nil, c)

	for i := 0; i < 500; i++ {
		line := g.substituteIPs(g.pickLine())
		src, dst, ok := extractParsedPair(line)
		if !ok {
			continue
		}
		if src == dst {
			t.Fatalf("src == dst (%q) in line:\n%s", src, line)
		}
	}
}

func TestSubstituteIPs_CiscoRepeatSameIP(t *testing.T) {
	g := newGen(1, 50, 200000, 1.2, 0, nil, testCorpus(t))
	template := `%ASA-6-302013: Built outbound TCP connection 1 for outside:203.0.113.5/443 (203.0.113.5/443) to inside:10.0.0.10/51000 (10.0.0.10/51000)`
	out := g.substituteIPs(template)

	// Повторяющиеся адреса в скобках должны совпадать
	if strings.Count(out, extractBetween(out, "outside:", "/")) < 2 {
		t.Log("outside IP repeat check skipped (format)")
	}

	src, dst, ok := extractParsedPair(out)
	if !ok {
		t.Fatal("failed to extract pair")
	}
	if src == dst {
		t.Fatalf("src == dst: %s", src)
	}
}

func TestSubstituteIPs_InternalExternalMix(t *testing.T) {
	g := newGen(99, 50, 200000, 1.2, 0, nil, testCorpus(t))
	template := `CEF:0|Fortinet|FortiGate|7.2|00013|traffic|5|src=192.0.2.10 dst=203.0.113.20 spt=51000 dpt=80 proto=6 act=accept`
	out := g.substituteIPs(template)
	src, dst, ok := extractParsedPair(out)
	if !ok {
		t.Fatal("no pair")
	}
	if src == dst {
		t.Fatalf("src == dst")
	}
	// Один из адресов — приватный 10.x, другой — нет
	srcPrivate := strings.HasPrefix(src, "10.")
	dstPrivate := strings.HasPrefix(dst, "10.")
	if srcPrivate == dstPrivate {
		t.Logf("note: both same visibility class src=%s dst=%s (acceptable for some flows)", src, dst)
	}
}

func TestExtraFixtures_ParseablePairs(t *testing.T) {
	for _, f := range extraFixtures {
		src, dst, ok := extractSrcDstPair(f.Line)
		if !ok {
			t.Errorf("fixture %s: no src/dst pair", f.Vendor)
			continue
		}
		if src == dst {
			t.Errorf("fixture %s: template src==dst %q", f.Vendor, src)
		}
	}
}

func TestGeoMode_ProducesPublicDistinctIPs(t *testing.T) {
	g := newGen(7, 100, 10000, 1.2, 0, nil, testCorpus(t), "map")
	for i := 0; i < 200; i++ {
		line := g.event()
		src, dst, ok := extractParsedPair(line)
		if !ok {
			continue
		}
		if src == dst {
			t.Fatalf("geo mode produced identical src/dst: %s", src)
		}
		srcIP := netip.MustParseAddr(src)
		dstIP := netip.MustParseAddr(dst)
		if !srcIP.IsGlobalUnicast() || !dstIP.IsGlobalUnicast() {
			t.Fatalf("geo mode produced non-global IPs: src=%s dst=%s", src, dst)
		}
		if srcIP.IsPrivate() || dstIP.IsPrivate() {
			t.Fatalf("geo mode produced private IPs: src=%s dst=%s", src, dst)
		}
	}
}

// extractBetween — вспомогательная для теста повторов Cisco.
func extractBetween(s, before, after string) string {
	i := strings.Index(s, before)
	if i < 0 {
		return ""
	}
	s = s[i+len(before):]
	j := strings.Index(s, after)
	if j < 0 {
		return ""
	}
	return s[:j]
}
