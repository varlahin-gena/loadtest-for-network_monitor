import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const evLatency = new Trend('events_latency', true);

export const options = {
  scenarios: {
    dashboard_users: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { target: 5,  duration: '2m' },
        { target: 15, duration: '3m' },
        { target: 30, duration: '3m' },   // 30 одновременных "вкладок карты" — уже много для 4 vCPU
        { target: 0,  duration: '1m' },
      ],
    },
  },
  thresholds: {
    'http_req_duration{endpoint:events}': ['p(95)<2000', 'p(99)<4000'],
    'http_req_failed': ['rate<0.01'],
  },
};

const days     = [1, 7, 30];
const filters  = ['all', 'blocked', 'allowed'];
const groupBys = ['ip', 'subnet', 'country'];
const limits   = [500, 2000, 5000, 20000];  // 20000 = worst case (Go-агрегация + GC)

export default function () {
  const p = new URLSearchParams({
    days:            String(days[Math.floor(Math.random() * days.length)]),
    limit:           String(limits[Math.floor(Math.random() * limits.length)]),
    filter:          filters[Math.floor(Math.random() * filters.length)],
    group_by:        groupBys[Math.floor(Math.random() * groupBys.length)],
    include_unknown: Math.random() < 0.3 ? 'true' : 'false',
  }).toString();

  const res = http.get(`${BASE}/api/events?${p}`, { tags: { endpoint: 'events' } });
  evLatency.add(res.timings.duration);
  check(res, {
    'events 200': (r) => r.status === 200,
    'has lines':  (r) => r.status === 200 && r.body.includes('"lines"'),
  });

  sleep(Math.random() * 3 + 2);
}
