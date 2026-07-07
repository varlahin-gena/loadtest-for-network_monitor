import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const edgesLatency = new Trend('edges_latency', true);

export const options = {
  scenarios: {
    // "пользователи фронта", обновляющие карту
    dashboard_users: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { target: 5,  duration: '2m' },
        { target: 20, duration: '3m' },
        { target: 50, duration: '3m' },
        { target: 0,  duration: '1m' },
      ],
    },
  },
  thresholds: {
    'http_req_duration{endpoint:edges}': ['p(95)<1500', 'p(99)<3000'],
    'http_req_failed': ['rate<0.01'],
  },
};

// подгони параметры под реальные query params твоего aggregator API
const windows = [1, 7, 30];               // days
const filters = ['', 'blocked', 'allowed'];
const limits  = [500, 2000, 5000];

export default function () {
  const days   = windows[Math.floor(Math.random() * windows.length)];
  const filter = filters[Math.floor(Math.random() * filters.length)];
  const limit  = limits[Math.floor(Math.random() * limits.length)];

  let q = `days=${days}&limit=${limit}`;
  if (filter) q += `&filter=${filter}`;

  const edges = http.get(`${BASE}/api/edges?${q}`, { tags: { endpoint: 'edges' } });
  edgesLatency.add(edges.timings.duration);
  check(edges, { 'edges 200': (r) => r.status === 200 });

  http.get(`${BASE}/api/stats?${q}`, { tags: { endpoint: 'stats' } });

  sleep(Math.random() * 3 + 2); // пользователь смотрит на карту 2-5с
}
