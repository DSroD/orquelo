# Metrics

The server exposes Prometheus metrics (text format 0.0.4) on `GET /metrics` of a
**separate port**, `METRICS_PORT` (unset: no metrics endpoint). The main port serves
the SPA at `/metrics`, so the endpoint is never public. Keep `METRICS_PORT` off the public
ingress and let only your Prometheus reach it.

Durations are in seconds. Routes are templates (`/api/s/:pid/:code/vote`), never
concrete paths, so label cardinality stays bounded. Requests that match no route are
`route="static"` (SPA, assets) or `route="not_found"`; non-standard methods are `OTHER`.

## Application

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `orquelo_http_requests_total` | counter | method, route, status | Requests handled |
| `orquelo_http_request_duration_seconds` | histogram | method, route | Time until the response is returned. A stream counts until it starts, not until it ends |
| `orquelo_accounts` | gauge | | Registered accounts, including suspended accounts. Omitted if the database count fails |
| `orquelo_votes_total` | counter | result=`ok`\|`not_open`\|`invalid` | Vote attempts that reached the database (a single-choice poll given several options is rejected earlier and not counted) |
| `orquelo_hub_call_seconds` | histogram | | Round trip to the hub's manager thread, queue wait included |
| `orquelo_hub_push_seconds` | histogram | | Time the manager thread spends projecting and queueing snapshots for a session's subscribers |
| `orquelo_sse_messages_total` | counter | role, kind=`sent`\|`suppressed` | Snapshots queued, or skipped because that subscriber's projection did not change |
| `orquelo_sse_delivery_seconds` | histogram | role | Delay from the hub queueing a message to the stream writing it |
| `orquelo_sse_connections` | gauge | role | Open SSE subscriptions |
| `orquelo_sessions` | gauge | state=`loaded`\|`live` | Sessions cached in the hub; `live` = not ended |
| `orquelo_runs_open` | gauge | | Sessions with a poll run open |
| `orquelo_db_pool_wait_seconds` | histogram | | Time a thread waited to lease a pooled database connection (about 0 when one was free; up to the 5 s wait when the pool is full) |
| `orquelo_db_pool_timeouts_total` | counter | | Leases that gave up after the wait; the request is answered 503 |
| `orquelo_build_info` | gauge | racket_version | Always 1 |

`orquelo_sse_delivery_seconds` is measured up to the write into web-server's internal
chunk pipe, not the client socket: it shows server-side queueing, not network delay.

## Process

| Metric | Type | Meaning |
|---|---|---|
| `racket_memory_bytes` | gauge | Memory in use |
| `racket_memory_allocated_bytes_total` | counter | Bytes allocated since start |
| `racket_gc_seconds_total` | counter | Time in garbage collection |
| `racket_gc_pause_seconds{kind}` | histogram | Pause per collection, `minor` or `major` (incremental counts as major) |
| `racket_cpu_seconds_total` | counter | Process CPU time |
| `racket_threads` | gauge | Live threads of the server (found by walking its custodian tree) |
| `racket_thread_switches_total` | counter | Thread context switches (scheduling work; slot 4 of `vector-set-performance-stats!`) |
| `process_start_time_seconds` | gauge | Start time, Unix epoch |

## Queries

```promql
# successful core password logins over the last 24 hours, across replicas
sum(increase(orquelo_http_requests_total{method="POST",route="/auth/password",status="204"}[24h]))

# p95 delay between the hub queueing a snapshot and the stream writing it, per role
histogram_quantile(0.95, sum by (le, role) (rate(orquelo_sse_delivery_seconds_bucket[5m])))

# p99 request time per route
histogram_quantile(0.99, sum by (le, route) (rate(orquelo_http_request_duration_seconds_bucket[5m])))

# 5xx ratio
sum(rate(orquelo_http_requests_total{status=~"5.."}[5m])) / sum(rate(orquelo_http_requests_total[5m]))

# share of snapshots the diff suppression saved
sum(rate(orquelo_sse_messages_total{kind="suppressed"}[5m])) / sum(rate(orquelo_sse_messages_total[5m]))

# hub saturation: mean time to project one push
rate(orquelo_hub_push_seconds_sum[5m]) / rate(orquelo_hub_push_seconds_count[5m])

# pool saturation: share of leases that waited over 100 ms, and leases that timed out per second
1 - sum(rate(orquelo_db_pool_wait_seconds_bucket{le="0.1"}[5m])) / sum(rate(orquelo_db_pool_wait_seconds_count[5m]))
rate(orquelo_db_pool_timeouts_total[5m])

# major GC pause p99
histogram_quantile(0.99, sum by (le) (rate(racket_gc_pause_seconds_bucket{kind="major"}[5m])))

# memory per open stream
racket_memory_bytes / sum(orquelo_sse_connections)
```
