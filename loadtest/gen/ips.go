package main

import (
	"math/rand"
	"regexp"
	"strconv"
	"strings"
)

// ipSide — роль адреса в строке лога (для реалистичной подстановки).
type ipSide int

const (
	sideUnknown ipSide = iota
	sideSrc
	sideDst
	sideInternal
	sideExternal
)

var (
	cefSrcRe = regexp.MustCompile(`(?i)(?:^|[\s|])(?:src|src_ip)=([\d.]+)`)
	cefDstRe = regexp.MustCompile(`(?i)(?:^|[\s|])(?:dst|dst_ip)=([\d.]+)`)
	kvSrcRe  = regexp.MustCompile(`(?i)\bSrcIP:\s*([\d.]+)`)
	kvDstRe  = regexp.MustCompile(`(?i)\bDstIP:\s*([\d.]+)`)
	jsonSrc  = regexp.MustCompile(`"src_ip"\s*:\s*"([\d.]+)"`)
	jsonDst  = regexp.MustCompile(`"dst_ip"\s*:\s*"([\d.]+)"`)
	// Cisco: from ZONE:IP ... to ZONE:IP (Built connection)
	ciscoToRe = regexp.MustCompile(
		`(?i)for\s+(?:outside|inside|dmz|lan|wan|trust|untrust)\s*:\s*([\d.]+)/\d+.*?\bto\s+(?:outside|inside|dmz|lan|wan|trust|untrust)\s*:\s*([\d.]+)/\d+`,
	)
	// Cisco deny: from IP to IP
	ciscoFromToRe = regexp.MustCompile(`(?i)\bfrom\s+([\d.]+)/\d+\s+to\s+([\d.]+)/\d+`)
	// Cisco 106023: src zone:IP ... dst zone:IP
	ciscoSrcDstRe = regexp.MustCompile(
		`(?i)\bsrc\s+(?:outside|inside|dmz|lan|wan|trust|untrust)\s*:\s*([\d.]+).*?\bdst\s+(?:outside|inside|dmz|lan|wan|trust|untrust)\s*:\s*([\d.]+)`,
	)
	// Cisco ICMP: faddr=dst, laddr=src
	ciscoICMPRe = regexp.MustCompile(`(?i)faddr\s+([\d.]+)/\d+.*?laddr\s+([\d.]+)/\d+`)
	// Cisco arrow: inside/IP(port) -> outside/IP(port)
	ciscoArrowRe = regexp.MustCompile(
		`(?i)(?:outside|inside|dmz|lan|wan|trust|untrust)/([\d.]+)\(\d+\)\s*->\s*(?:outside|inside|dmz|lan|wan|trust|untrust)/([\d.]+)\(\d+\)`,
	)
)

func extractSrcDstPair(line string) (src, dst string, ok bool) {
	try := func(s, d string) (string, string, bool) {
		if s != "" && d != "" && s != d {
			return s, d, true
		}
		return "", "", false
	}
	if m := cefSrcRe.FindStringSubmatch(line); len(m) > 1 {
		src = m[1]
	}
	if m := cefDstRe.FindStringSubmatch(line); len(m) > 1 {
		dst = m[1]
	}
	if s, d, ok := try(src, dst); ok {
		return s, d, true
	}
	if m := kvSrcRe.FindStringSubmatch(line); len(m) > 1 {
		src = m[1]
	}
	if m := kvDstRe.FindStringSubmatch(line); len(m) > 1 {
		dst = m[1]
	}
	if s, d, ok := try(src, dst); ok {
		return s, d, true
	}
	if m := jsonSrc.FindStringSubmatch(line); len(m) > 1 {
		src = m[1]
	}
	if m := jsonDst.FindStringSubmatch(line); len(m) > 1 {
		dst = m[1]
	}
	if s, d, ok := try(src, dst); ok {
		return s, d, true
	}
	for _, re := range []*regexp.Regexp{ciscoToRe, ciscoFromToRe, ciscoSrcDstRe, ciscoArrowRe} {
		if m := re.FindStringSubmatch(line); len(m) > 2 {
			if s, d, ok := try(m[1], m[2]); ok {
				return s, d, true
			}
		}
	}
	// ICMP: faddr = dst (foreign), laddr = src (local)
	if m := ciscoICMPRe.FindStringSubmatch(line); len(m) > 2 {
		if s, d, ok := try(m[2], m[1]); ok {
			return s, d, true
		}
	}
	return "", "", false
}

func classifySide(context string) ipSide {
	ctx := strings.ToLower(context)
	switch {
	case strings.Contains(ctx, "src_ip"), strings.Contains(ctx, "srcip:"),
		strings.HasSuffix(ctx, "src="), strings.Contains(ctx, " src="),
		strings.Contains(ctx, "'src_ip'"):
		return sideSrc
	case strings.Contains(ctx, "dst_ip"), strings.Contains(ctx, "dstip:"),
		strings.HasSuffix(ctx, "dst="), strings.Contains(ctx, " dst="),
		strings.Contains(ctx, "'dst_ip'"):
		return sideDst
	case strings.Contains(ctx, "inside:"), strings.Contains(ctx, "inside/"),
		strings.Contains(ctx, " laddr "), strings.Contains(ctx, " gaddr "),
		strings.Contains(ctx, "lan/"), strings.Contains(ctx, "trust"):
		return sideInternal
	case strings.Contains(ctx, "outside:"), strings.Contains(ctx, "outside/"),
		strings.Contains(ctx, " faddr "), strings.Contains(ctx, "wan/"),
		strings.Contains(ctx, "untrust"):
		return sideExternal
	case strings.Contains(ctx, " from "):
		return sideSrc
	case strings.Contains(ctx, " to "):
		return sideDst
	default:
		return sideUnknown
	}
}

func (g *gen) internalIP() string {
	idx := g.zipf.Uint64()
	subnet := 1 + int(idx%250)
	host := 1 + g.r.Intn(253)
	return "10." + strconv.Itoa(subnet) + "." + strconv.Itoa(int(idx>>8)&0xFF) + "." + strconv.Itoa(host)
}

func (g *gen) externalIP() string {
	idx := g.zipf.Uint64()
	if int(idx) < g.hotIPs {
		return "203.0.113." + strconv.Itoa(int(idx)%254+1)
	}
	// Публичные диапазоны (не RFC1918): 198.18/15, 203.0.113, случайные /16
	switch g.r.Intn(4) {
	case 0:
		return "198.51.100." + strconv.Itoa(g.r.Intn(254)+1)
	case 1:
		return "203.0.113." + strconv.Itoa(g.r.Intn(254)+1)
	case 2:
		return "192.0.2." + strconv.Itoa(g.r.Intn(254)+1)
	default:
		a := 45 + g.r.Intn(200)
		return strconv.Itoa(a) + "." + strconv.Itoa(g.r.Intn(256)) + "." +
			strconv.Itoa(g.r.Intn(256)) + "." + strconv.Itoa(g.r.Intn(254)+1)
	}
}

func (g *gen) dmzIP() string {
	return "172.16." + strconv.Itoa(g.r.Intn(256)) + "." + strconv.Itoa(g.r.Intn(254)+1)
}

// makeTrafficPair возвращает пару src/dst: LAN↔WAN, гарантированно разные.
func (g *gen) makeTrafficPair() (src, dst string) {
	if g.r.Float64() < 0.55 {
		// исходящий: внутренняя сеть -> интернет
		src, dst = g.internalIP(), g.externalIP()
	} else {
		// входящий: интернет -> внутренняя сеть
		src, dst = g.externalIP(), g.internalIP()
	}
	for i := 0; src == dst && i < 16; i++ {
		dst = g.internalIP()
		if src == dst {
			dst = g.externalIP()
		}
	}
	return src, dst
}

func (g *gen) ipForSide(side ipSide, mapping map[string]string, used map[string]bool) string {
	pick := func(candidates ...string) string {
		for _, ip := range candidates {
			if ip != "" && !used[ip] {
				return ip
			}
		}
		for i := 0; i < 32; i++ {
			ip := g.externalIP()
			if !used[ip] {
				return ip
			}
		}
		return g.internalIP()
	}

	switch side {
	case sideSrc:
		return pick(g.externalIP(), g.internalIP())
	case sideDst:
		// стараемся не совпасть с уже назначенным src
		for _, src := range mapping {
			for i := 0; i < 32; i++ {
				ip := g.internalIP()
				if ip != src && !used[ip] {
					return ip
				}
				ip = g.externalIP()
				if ip != src && !used[ip] {
					return ip
				}
			}
		}
		return pick(g.internalIP(), g.externalIP())
	case sideInternal:
		return pick(g.internalIP(), g.dmzIP())
	case sideExternal:
		return pick(g.externalIP())
	default:
		if g.r.Float64() < 0.5 {
			return pick(g.internalIP())
		}
		return pick(g.externalIP())
	}
}

func (g *gen) seedPair(mapping map[string]string, used map[string]bool, srcOld, dstOld string) {
	srcNew, dstNew := g.makeTrafficPair()
	mapping[srcOld] = srcNew
	mapping[dstOld] = dstNew
	used[srcNew] = true
	used[dstNew] = true
}

// extractParsedPair вытаскивает src/dst из сгенерированной строки для тестов.
func extractParsedPair(line string) (src, dst string, ok bool) {
	return extractSrcDstPair(line)
}
