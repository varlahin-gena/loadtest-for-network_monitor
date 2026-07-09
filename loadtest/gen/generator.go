package main

import (
	"math/rand"
	"regexp"
	"strconv"
	"strings"

	"loadtest/gen/samplesrc"
)

// ---- vendor mix ----

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
		if w <= 0 {
			continue
		}
		sum += w
		out = append(out, weighted{kv[0], sum})
	}
	return out
}

// ---- corpus (реальные образцы из network_monitor) ----

var ipRe = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)

type corpus struct {
	byVendor map[string][]string
	vendors  []string
}

// loadCorpus берёт строки из синхронизированного samplesrc + локальные fixtures.
// Skip:true (напр. cowrie.command.input без сетевой пары) по умолчанию исключаем —
// они тестируют путь "Skipped", а не путь вставки.
func loadCorpus(includeSkip bool) *corpus {
	c := &corpus{byVendor: map[string][]string{}}
	for _, s := range samplesrc.Samples() {
		if s.Skip && !includeSkip {
			continue
		}
		c.byVendor[s.Vendor] = append(c.byVendor[s.Vendor], s.Line)
	}
	for _, f := range extraFixtures {
		c.byVendor[f.Vendor] = append(c.byVendor[f.Vendor], f.Line)
	}
	for v := range c.byVendor {
		c.vendors = append(c.vendors, v)
	}
	return c
}

// ---- event generator ----

type gen struct {
	r        *rand.Rand
	zipf     *rand.Zipf
	hotIPs   int
	dirty    float64
	mix      []weighted
	mixTotal int
	corpus   *corpus
}

func newGen(seed int64, hot, total int, s, dirty float64, mix []weighted, c *corpus) *gen {
	r := rand.New(rand.NewSource(seed))
	z := rand.NewZipf(r, s, 1.0, uint64(total-1))
	mt := 0
	if len(mix) > 0 {
		mt = mix[len(mix)-1].cum
	}
	return &gen{r: r, zipf: z, hotIPs: hot, dirty: dirty, mix: mix, mixTotal: mt, corpus: c}
}

func (g *gen) pickVendor() string {
	n := g.r.Intn(g.mixTotal)
	for _, w := range g.mix {
		if n < w.cum {
			return w.vendor
		}
	}
	return g.mix[0].vendor
}

func (g *gen) pickLine() string {
	if g.mixTotal > 0 {
		if lines, ok := g.corpus.byVendor[g.pickVendor()]; ok && len(lines) > 0 {
			return lines[g.r.Intn(len(lines))]
		}
	}
	v := g.corpus.vendors[g.r.Intn(len(g.corpus.vendors))]
	lines := g.corpus.byVendor[v]
	return lines[g.r.Intn(len(lines))]
}

// substituteIPs заменяет IPv4 в шаблоне на реалистичные адреса:
//   - src/dst из разных пулов (LAN vs WAN), никогда не совпадают в паре;
//   - одинаковый исходный IP в строке -> один новый (Cisco "IP/port (IP/port)");
//   - контекст (inside/outside, src=, dst=) задаёт роль адреса.
func (g *gen) substituteIPs(line string) string {
	mapping := make(map[string]string, 8)
	used := make(map[string]bool, 8)

	if srcOld, dstOld, ok := extractSrcDstPair(line); ok {
		g.seedPair(mapping, used, srcOld, dstOld)
	}

	for _, idx := range ipRe.FindAllStringIndex(line, -1) {
		old := line[idx[0]:idx[1]]
		if _, exists := mapping[old]; exists {
			continue
		}
		ctxStart := idx[0] - 56
		if ctxStart < 0 {
			ctxStart = 0
		}
		side := classifySide(line[ctxStart:idx[0]])
		mapping[old] = g.ipForSide(side, mapping, used)
		used[mapping[old]] = true
	}

	// Финальная проверка: если в паре src/dst всё же совпали — развести dst.
	if srcOld, dstOld, ok := extractSrcDstPair(line); ok {
		if mapping[srcOld] != "" && mapping[srcOld] == mapping[dstOld] {
			for i := 0; i < 32; i++ {
				candidate := g.ipForSide(sideDst, mapping, used)
				if candidate != mapping[srcOld] {
					mapping[dstOld] = candidate
					break
				}
			}
		}
	}

	return ipRe.ReplaceAllStringFunc(line, func(old string) string {
		if nv, ok := mapping[old]; ok {
			return nv
		}
		return old
	})
}

func (g *gen) event() string {
	if g.dirty > 0 && g.r.Float64() < g.dirty {
		return garbage(g.r)
	}
	return g.substituteIPs(g.pickLine())
}

func garbage(r *rand.Rand) string {
	return "MALFORMED-" + strconv.Itoa(r.Intn(99999)) + " <<< not a valid firewall event >>>"
}
