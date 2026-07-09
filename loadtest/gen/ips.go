package main

import (
	"regexp"
	"strconv"
	"strings"
)

type geoRoute struct {
	srcPrefix string
	dstPrefix string
}

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
	pySrc    = regexp.MustCompile(`'src_ip'\s*:\s*'([\d.]+)'`)
	pyDst    = regexp.MustCompile(`'dst_ip'\s*:\s*'([\d.]+)'`)
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
	if src == "" {
		if m := pySrc.FindStringSubmatch(line); len(m) > 1 {
			src = m[1]
		}
	}
	if dst == "" {
		if m := pyDst.FindStringSubmatch(line); len(m) > 1 {
			dst = m[1]
		}
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
	if g.geoMode == "map" {
		return g.geoEndpoint(true)
	}
	idx := g.zipf.Uint64()
	subnet := 1 + int(idx%250)
	host := 1 + g.r.Intn(253)
	return "10." + strconv.Itoa(subnet) + "." + strconv.Itoa(int(idx>>8)&0xFF) + "." + strconv.Itoa(host)
}

func (g *gen) externalIP() string {
	if g.geoMode == "map" {
		return g.geoEndpoint(false)
	}
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
	if g.geoMode == "map" {
		return g.geoEndpoint(true)
	}
	return "172.16." + strconv.Itoa(g.r.Intn(256)) + "." + strconv.Itoa(g.r.Intn(254)+1)
}

// makeTrafficPair возвращает пару src/dst: LAN↔WAN, гарантированно разные.
func (g *gen) makeTrafficPair() (src, dst string) {
	if g.geoMode == "map" {
		return g.makeGeoPair()
	}
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

func defaultGeoRoutes() []geoRoute {
	return []geoRoute{
		{srcPrefix: "8.8.8", dstPrefix: "1.1.1"},          // US -> global anycast
		{srcPrefix: "31.13.71", dstPrefix: "91.108.56"},   // Meta EU -> Telegram-ish
		{srcPrefix: "52.95.110", dstPrefix: "13.107.42"},  // AWS -> Microsoft
		{srcPrefix: "104.16.132", dstPrefix: "172.217.20"}, // Cloudflare -> Google
		{srcPrefix: "43.129.255", dstPrefix: "101.32.118"}, // Singapore/HK style
		{srcPrefix: "81.2.69", dstPrefix: "185.60.216"},   // UK/EU
		{srcPrefix: "23.38.97", dstPrefix: "210.140.92"},  // US CDN -> Japan
		{srcPrefix: "170.114.52", dstPrefix: "34.117.59"}, // Zoom-ish -> GCP
		{srcPrefix: "45.57.62", dstPrefix: "66.22.196"},   // CDN -> Fastly-ish
		{srcPrefix: "103.21.244", dstPrefix: "116.203.0"}, // India-ish -> Germany-ish
		{srcPrefix: "41.77.12", dstPrefix: "196.13.208"},  // Africa-ish
		{srcPrefix: "95.100.96", dstPrefix: "203.205.254"}, // EU -> APAC-ish
	}
}

func (g *gen) geoEndpoint(preferDst bool) string {
	route := g.geoHotSet[g.r.Intn(len(g.geoHotSet))]
	prefix := route.srcPrefix
	if preferDst {
		prefix = route.dstPrefix
		if g.r.Float64() < 0.35 {
			prefix = route.srcPrefix
		}
	} else if g.r.Float64() < 0.35 {
		prefix = route.dstPrefix
	}
	return prefix + "." + strconv.Itoa(1+g.r.Intn(220))
}

func (g *gen) makeGeoPair() (src, dst string) {
	route := g.geoHotSet[g.r.Intn(len(g.geoHotSet))]
	src = route.srcPrefix + "." + strconv.Itoa(1+g.r.Intn(220))
	dst = route.dstPrefix + "." + strconv.Itoa(1+g.r.Intn(220))
	if g.r.Float64() < 0.35 {
		src, dst = dst, src
	}
	if src == dst {
		dst = route.dstPrefix + "." + strconv.Itoa(221+g.r.Intn(30))
	}
	return src, dst
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
