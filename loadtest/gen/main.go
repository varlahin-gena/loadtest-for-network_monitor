package main

//go:generate bash ../scripts/sync-samples.sh

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ---- CLI ----

var (
	fMode        = flag.String("mode", "http", "http | udp (udp = raw syslog to syslog-ng)")
	fURL         = flag.String("url", "http://127.0.0.1:8080/api/ingest", "ingest endpoint (http mode)")
	fSyslog      = flag.String("syslog", "127.0.0.1:514", "syslog udp addr (udp mode)")
	fCType       = flag.String("content-type", "text/plain", "Content-Type for http mode")
	fStages      = flag.String("stages", "5000:2m,10000:3m,25000:3m,50000:3m", "EPS ramp stages: target:dur,target:dur")
	fStartRate   = flag.Float64("start-rate", 500, "initial EPS before first stage")
	fWorkers     = flag.Int("workers", 16, "HTTP sender goroutines (4 vCPU -> держи 8-24)")
	fBatch       = flag.Int("batch", 5000, "events per request (newline-joined) = размер INSERT-батча в CH")
	fMix         = flag.String("mix", "fortigate=40,usergate=20,cisco-asa=15,cisco-ftd=10,cowrie=10,generic=5", "vendor weights")
	fHotIPs      = flag.Int("hot-ips", 50, "count of 'hot' src/dst IPs (Zipf head)")
	fTotalIPs    = flag.Int("total-ips", 200000, "IP address space for Zipf substitution")
	fZipfS       = flag.Float64("zipf-s", 1.2, "Zipf skew (>1). Higher = more concentrated")
	fDirty       = flag.Float64("dirty-rate", 0.0, "fraction [0..1] of malformed events (tests parse_errors path)")
	fIncludeSkip = flag.Bool("include-skip", false, "include Skip:true samples (tests parser Skipped path)")
	fReport      = flag.Duration("report", 5*time.Second, "metrics report interval")
	fTimeout     = flag.Duration("timeout", 10*time.Second, "http request timeout")
)

// ---- rate stages ----

type stage struct {
	target float64
	dur    time.Duration
}

func parseStages(s string) ([]stage, time.Duration) {
	var out []stage
	var total time.Duration
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			log.Fatalf("bad stage %q", part)
		}
		t, err := strconv.ParseFloat(kv[0], 64)
		if err != nil {
			log.Fatalf("bad target %q: %v", kv[0], err)
		}
		d, err := time.ParseDuration(kv[1])
		if err != nil {
			log.Fatalf("bad dur %q: %v", kv[1], err)
		}
		out = append(out, stage{t, d})
		total += d
	}
	if len(out) == 0 {
		log.Fatal("no stages parsed")
	}
	return out, total
}

// rateAt: линейный ramp от предыдущего target к target этапа за его длительность.
func rateAt(elapsed time.Duration, start float64, stages []stage) float64 {
	prev := start
	var acc time.Duration
	for _, st := range stages {
		if elapsed < acc+st.dur {
			frac := float64(elapsed-acc) / float64(st.dur)
			return prev + (st.target-prev)*frac
		}
		acc += st.dur
		prev = st.target
	}
	return prev // после этапов держим последний target
}

// ---- latency histogram (bucketed, atomic) ----

var histBounds = []float64{1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000} // ms

type hist struct {
	buckets []int64 // len = len(histBounds)+1
}

func newHist() *hist { return &hist{buckets: make([]int64, len(histBounds)+1)} }

func (h *hist) add(ms float64) {
	i := sort.SearchFloat64s(histBounds, ms)
	atomic.AddInt64(&h.buckets[i], 1)
}

func (h *hist) percentile(p float64) float64 {
	var total int64
	for i := range h.buckets {
		total += atomic.LoadInt64(&h.buckets[i])
	}
	if total == 0 {
		return 0
	}
	target := int64(float64(total) * p)
	var cum int64
	for i := range h.buckets {
		cum += atomic.LoadInt64(&h.buckets[i])
		if cum >= target {
			if i >= len(histBounds) {
				return histBounds[len(histBounds)-1]
			}
			return histBounds[i]
		}
	}
	return histBounds[len(histBounds)-1]
}

// ---- global counters ----

var (
	cSent    int64
	cOK      int64
	cFail    int64
	cEvents  int64
	cDropped int64
	H        = newHist()
)

func main() {
	flag.Parse()
	stages, total := parseStages(*fStages)

	mix := parseMix(*fMix)
	cor := loadCorpus(*fIncludeSkip)
	if len(cor.vendors) == 0 {
		log.Fatal("corpus is empty — запусти scripts/sync-samples.sh (go generate ./gen/...)")
	}
	log.Printf("scenario: mode=%s stages=%s total=%s workers=%d batch=%d dirty=%.2f include-skip=%v vendors=%v",
		*fMode, *fStages, total, *fWorkers, *fBatch, *fDirty, *fIncludeSkip, cor.vendors)

	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; log.Println("stopping..."); cancel() }()

	jobs := make(chan struct{}, *fWorkers*4)

	client := &http.Client{
		Timeout: *fTimeout,
		Transport: &http.Transport{
			MaxIdleConns:        *fWorkers * 2,
			MaxIdleConnsPerHost: *fWorkers * 2,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	var udpConn net.Conn
	if *fMode == "udp" {
		c, err := net.Dial("udp", *fSyslog)
		if err != nil {
			log.Fatalf("udp dial: %v", err)
		}
		udpConn = c
	}

	var wg sync.WaitGroup
	for i := 0; i < *fWorkers; i++ {
		wg.Add(1)
		go worker(ctx, i, jobs, &wg, client, udpConn, mix, cor)
	}

	go reporter(ctx, stages, *fStartRate)

	// dispatcher: дробное накопление токенов, ramp по времени.
	start := time.Now()
	tick := 10 * time.Millisecond
	ticker := time.NewTicker(tick)
	defer ticker.Stop()
	var carry float64
	deadline := start.Add(total)

loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case now := <-ticker.C:
			if now.After(deadline) {
				break loop
			}
			eps := rateAt(now.Sub(start), *fStartRate, stages)
			reqPerSec := eps / float64(*fBatch)
			carry += reqPerSec * tick.Seconds()
			n := int(carry)
			carry -= float64(n)
			for j := 0; j < n; j++ {
				select {
				case jobs <- struct{}{}:
				default:
					atomic.AddInt64(&cDropped, 1) // backpressure: воркеры не успевают
				}
			}
		}
	}

	cancel()
	close(jobs)
	wg.Wait()
	finalReport(time.Since(start))
}

func worker(ctx context.Context, id int, jobs <-chan struct{}, wg *sync.WaitGroup,
	client *http.Client, udp net.Conn, mix []weighted, cor *corpus) {
	defer wg.Done()

	g := newGen(int64(id)*7919+1, *fHotIPs, *fTotalIPs, *fZipfS, *fDirty, mix, cor)
	buf := &bytes.Buffer{}

	for range jobs {
		buf.Reset()
		for i := 0; i < *fBatch; i++ {
			buf.WriteString(g.event())
			buf.WriteByte('\n')
		}
		payload := buf.Bytes()
		atomic.AddInt64(&cSent, 1)
		atomic.AddInt64(&cEvents, int64(*fBatch))
		t0 := time.Now()

		if udp != nil {
			// syslog-путь: события шлём по одному
			ok := true
			for _, line := range bytes.Split(payload, []byte("\n")) {
				if len(line) == 0 {
					continue
				}
				if _, err := udp.Write(line); err != nil {
					ok = false
					break
				}
			}
			if ok {
				atomic.AddInt64(&cOK, 1)
			} else {
				atomic.AddInt64(&cFail, 1)
			}
		} else {
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, *fURL, bytes.NewReader(payload))
			if err != nil {
				atomic.AddInt64(&cFail, 1)
				continue
			}
			req.Header.Set("Content-Type", *fCType)
			resp, err := client.Do(req)
			if err != nil {
				atomic.AddInt64(&cFail, 1)
				continue
			}
			_ = resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				atomic.AddInt64(&cOK, 1)
			} else {
				atomic.AddInt64(&cFail, 1)
			}
		}

		H.add(float64(time.Since(t0).Microseconds()) / 1000.0)
	}
}

func reporter(ctx context.Context, stages []stage, start float64) {
	t := time.NewTicker(*fReport)
	defer t.Stop()
	var prevEvents int64
	begin := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			ev := atomic.LoadInt64(&cEvents)
			eps := float64(ev-prevEvents) / fReport.Seconds()
			prevEvents = ev
			target := rateAt(time.Since(begin), start, stages)
			log.Printf("t=%4.0fs target=%7.0f actual=%8.1f eps | ok=%d fail=%d dropped=%d | p50=%.0f p95=%.0f p99=%.0fms",
				time.Since(begin).Seconds(), target, eps,
				atomic.LoadInt64(&cOK), atomic.LoadInt64(&cFail), atomic.LoadInt64(&cDropped),
				H.percentile(0.50), H.percentile(0.95), H.percentile(0.99))
		}
	}
}

func finalReport(d time.Duration) {
	ev := atomic.LoadInt64(&cEvents)
	fmt.Println("\n================ SUMMARY ================")
	fmt.Printf("duration:         %s\n", d.Round(time.Second))
	fmt.Printf("events sent:      %d (avg %.0f eps)\n", ev, float64(ev)/d.Seconds())
	fmt.Printf("requests ok:      %d\n", atomic.LoadInt64(&cOK))
	fmt.Printf("requests fail:    %d\n", atomic.LoadInt64(&cFail))
	fmt.Printf("dispatcher drops: %d  (backpressure — воркеры насыщены)\n", atomic.LoadInt64(&cDropped))
	fmt.Printf("latency p50/p95/p99: %.0f / %.0f / %.0f ms\n",
		H.percentile(0.50), H.percentile(0.95), H.percentile(0.99))
	fmt.Println("=========================================")
}
