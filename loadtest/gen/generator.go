package main

import (
	"math/rand"
	"strconv"
	"strings"
)

type weighted struct {
	vendor string
	cum    int
}

func parseMix(s string) []weighted {
	var out []weighted
	sum := 0
	for _, p := range strings.Split(s, ",") {
		kv := strings.SplitN(strings.TrimSpace(p), "=", 2)
		if len(kv) != 2 {
			continue
		}
		w, _ := strconv.Atoi(kv[1])
		sum += w
		out = append(out, weighted{kv[0], sum})
	}
	if sum == 0 {
		return []weighted{{"fortigate", 1}}
	}
	return out
}

type gen struct {
	r        *rand.Rand
	zipf     *rand.Zipf
	hotIPs   int
	totalIPs int
	dirty    float64
	mix      []weighted
	mixTotal int
}

func newGen(seed int64, hot, total int, s, dirty float64, mix []weighted) *gen {
	r := rand.New(rand.NewSource(seed))
	// Zipf over [0, total-1], head = hottest
	z := rand.NewZipf(r, s, 1.0, uint64(total-1))
	return &gen{r: r, zipf: z, hotIPs: hot, totalIPs: total, dirty: dirty,
		mix: mix, mixTotal: mix[len(mix)-1].cum}
}

// ipFor returns a deterministic IP string for an index; Zipf makes low indices "hot".
func (g *gen) ip() string {
	idx := g.zipf.Uint64()
	// map index -> IP. Keep first hotIPs in a compact "server" range.
	if int(idx) < g.hotIPs {
		return "203.0.113." + strconv.Itoa(int(idx)%254+1)
	}
	a := 10 + int(idx>>16)%200
	b := int(idx>>8) & 0xFF
	c := int(idx) & 0xFF
	return strconv.Itoa(a) + "." + strconv.Itoa(b) + "." + strconv.Itoa(c) + "." +
		strconv.Itoa(g.r.Intn(254)+1)
}

func (g *gen) port() int { return g.r.Intn(60000) + 1024 }

func (g *gen) pickVendor() string {
	n := g.r.Intn(g.mixTotal)
	for _, w := range g.mix {
		if n < w.cum {
			return w.vendor
		}
	}
	return g.mix[0].vendor
}

func (g *gen) event() string {
	if g.dirty > 0 && g.r.Float64() < g.dirty {
		return garbage(g.r)
	}
	src, dst := g.ip(), g.ip()
	sp, dp := g.port(), 443
	if g.r.Intn(3) == 0 {
		dp = []int{22, 80, 3389, 8080, 53}[g.r.Intn(5)]
	}
	switch g.pickVendor() {
	case "fortigate":
		return sampleFortiGate(g.r, src, dst, sp, dp)
	case "cef":
		return sampleCEF(g.r, src, dst, sp, dp)
	case "usergate":
		return sampleUserGate(g.r, src, dst, sp, dp)
	case "cisco_asa":
		return sampleCiscoASA(g.r, src, dst, sp, dp)
	case "cisco_ftd":
		return sampleCiscoFTD(g.r, src, dst, sp, dp)
	case "cowrie":
		return sampleCowrie(g.r, src)
	default:
		return sampleFortiGate(g.r, src, dst, sp, dp)
	}
}
