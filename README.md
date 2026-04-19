# Elastic CCS Demo Environment

A local Docker Compose stack demonstrating a two-cluster Elastic deployment with Cross-Cluster Search, APM, Fleet-managed Synthetic Monitoring, Filebeat, Metricbeat, and Heartbeat.

---

## Architecture

```
┌──────────── cluster-west (Operations / NOC) ──────────────┐
│  west-es01/02/03   — CCS reader, alerting                 │
│  kibana-west  (port 5601) — dashboards, alerts, CCS views │
│  west-metricbeat   — stack monitoring (local only)         │
│  alert-setup       — 3 CCS alerting rules watching east   │
└────────────────────────────┬───────────────────────────────┘
            CCS (net-ccs)    │   reads cluster-east:* indices
┌──────────── cluster-east ──┴── (Production) ──────────────┐
│  east-es01/02/03   — ALL observability data lives here     │
│  kibana-east  (port 5602) — APM, Logs, ML, Synthetics     │
│  east-apm-server  (port 8201) ←─ all APM traces            │
│  east-filebeat + east-metricbeat + heartbeat                │
│  Fleet Server (port 8220) + elastic-agent-synthetics        │
│  ML jobs: error rate, latency outliers, log rate            │
│                                                             │
│  ├─ east-gateway         (port 8001)  Python                │
│  ├─ east-catalog         (internal)   Java                  │
│  ├─ east-inventory       (internal)   Go                    │
│  ├─ east-pricing         (internal)   .NET                  │
│  ├─ east-reviews         (internal)   PHP                   │
│  ├─ east-orders          (internal)   Ruby                  │
│  ├─ east-recommendations (internal)   Rust                  │
│  └─ west-webapp          (port 8000)  Python (APM → east)   │
│                                                             │
│  search-es01    (port 9202) — application search backend    │
│  kibana-search  (port 5603) — Kibana for search cluster     │
│    aircraft index: lexical + search-as-you-type + suggest   │
└─────────────────────────────────────────────────────────────┘

Landing page (port 8080) — investigation narratives + service links.
Traffic generator (loadgen) hits all endpoints every 3s.
```

---

## Quick Start

### Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- At least 16 GB RAM allocated to Docker
- Ports 5601, 5602, 5603, 8000, 8001, 8002, 8080, 8200, 8201, 8220, 9200, 9201, 9202 free

### 1. Configure `.env`

Copy the defaults and set your passwords:

```bash
cp .env.example .env   # if one exists, otherwise edit .env directly
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `ELASTIC_PASSWORD` | `changeme` | Superuser password for all clusters |
| `KIBANA_PASSWORD` | `changeme` | `kibana_system` account on cluster-west |
| `EAST_KIBANA_PASSWORD` | `east-changeme` | `kibana_system` account on cluster-east |
| `SEARCH_KIBANA_PASSWORD` | `search-changeme` | `kibana_system` account on search cluster |
| `STACK_VERSION` | `8.19.14` | Elastic stack version |
| `LICENSE` | `trial` | `basic` or `trial` (enables 30-day trial) |

### 2. Start the stack

```bash
docker compose up -d
```

First boot takes 3–5 minutes. The `setup` service generates TLS certificates and provisions users before the rest of the stack starts.

### 3. Access the services

| Service | URL | Notes |
|---|---|---|
| **Landing page** | https://localhost:8080 | Links to all services + investigation playbooks |
| **Kibana — West** | https://localhost:5601 | NOC / CCS coordinator — alerts, CCS dashboards |
| **Kibana — East** | https://localhost:5602 | Production — APM, Logs, ML, Synthetics, SLOs |
| **Kibana — Search** | https://localhost:5603 | Search cluster — aircraft index, mappings |
| **West Webapp** | https://localhost:8000 | APM demo app |
| **Development Gateway** | https://localhost:8001 | Microservices with anomalies enabled |
| **Production Gateway** | https://localhost:8002 | Microservices, stable (no anomalies) |
| **West ES API** | https://localhost:9200 | |
| **East ES API** | https://localhost:9201 | |
| **Search ES API** | https://localhost:9202 | Application search backend |

Default credentials: **`elastic` / `changeme`** (set by `ELASTIC_PASSWORD` in `.env`).

> Kibana uses self-signed TLS — your browser will show a certificate warning. Accept it to proceed.

---

## What's in the Stack

### Cross-Cluster Search (CCS)

`cluster-west` is configured as the CCS coordinator. From Kibana-West you can query `cluster-east:*` indices alongside local indices in a single search. This demonstrates federated search across security boundaries without replicating data.

### APM & Distributed Tracing

A single APM Server on the east cluster (`east-apm-server`, port 8201) receives all traces. There is no APM server on west — west reads APM data via CCS.

**`west-webapp`** (port 8000) — a standalone Python service demonstrating APM transactions, error capture, and custom messages. Despite its name, its APM traces ship to `east-apm-server` so all observability data lives on east.

**East** — a seven-service microservice architecture, one service per language:

| Service | Language / Framework | Role |
|---|---|---|
| `east-gateway` | Python / FastAPI | User-facing API + EUI-styled UI. Fans requests out to all backend services via `httpx`. |
| `east-catalog` | Java / Spring Boot | Product catalog. Simulates DB queries with occasional slow-query spans (~15% chance). |
| `east-inventory` | Go / net/http | Stock level checks. Returns per-product availability with variable latency. |
| `east-pricing` | .NET / ASP.NET Core | Dynamic pricing engine. Returns prices with simulated discount logic. |
| `east-reviews` | PHP / Slim | Product review aggregation. Returns ratings and review counts. |
| `east-orders` | Ruby / Sinatra + Puma | Order management. Returns order history with occasional slow-query warnings (~12% chance). |
| `east-recommendations` | Rust / Axum | ML-style product scoring. Returns ranked recommendations via OTLP tracing (no native Rust APM agent). |

The APM agent (or OTLP exporter for Rust) automatically propagates `traceparent` headers through outbound calls, so APM shows a distributed trace spanning all seven services for each gateway request.

Each east service emits **ECS-formatted JSON logs** to stdout. Docker labels on each container instruct `east-filebeat`'s docker autodiscover to parse and ship the logs (with `trace.id` and `transaction.id` correlation fields) to `east-es01`.

### Application Search (search-es01)

A dedicated single-node Elasticsearch cluster (`search-es01`, port 9202) serves as the application search backend for the microservice suite. It's a separate cluster from the observability stack — this is an application-level dependency, the same way a real product would use Elasticsearch for search.

The `products` index contains 10 products with mappings for three search patterns:

| Search Type | Endpoint | Elasticsearch Feature | UI Behavior |
|---|---|---|---|
| **Lexical search** | `GET /search?q=` | `multi_match` with fuzziness across `name`, `description`, `tags`, `category` | Full search with relevance scoring |
| **Search-as-you-type** | `GET /search/asyoutype?q=` | `bool_prefix` query on `search_as_you_type` field type with 2-gram and 3-gram sub-fields | Results update as you type each character |
| **Typeahead / completion** | `GET /search/typeahead?q=` | Completion suggester with fuzzy matching and category context | Dropdown suggestions with category badges |

The gateway UI (https://localhost:8001) has a tabbed search bar where you can switch between the three modes and see results in real-time. Typeahead and search-as-you-type fire automatically with 200ms debounce.

#### Cascading Anomaly Pattern

All east services follow a **4-minute (240-second) cycle** with time-based degradation windows. During each window, the service introduces latency spikes and HTTP 503 errors. The windows are **staggered** to create a realistic cascading failure:

| Service | Degraded Window | Slow Requests | 503 Errors | Error Type |
|---|---|---|---|---|
| `east-catalog` | 168s–204s | 60% | 15% | DB connection pool exhaustion |
| `east-inventory` | 176s–204s | 50% | 10% | Depot sync timeout |
| `east-pricing` | 180s–204s | 45% | 10% | Cache miss / rate limit exceeded |
| `east-reviews` | 184s–204s | 40% | 12% | Connection pool exhausted |
| `east-orders` | 188s–204s | 50% | 12% | Database deadlock |
| `east-recommendations` | 192s–204s | 55% | 10% | Model inference timeout |

A **traffic generator** (`loadgen`) continuously hits all endpoints every 3 seconds, ensuring ML jobs have enough data points to establish baselines and detect the anomaly windows.

APM demo endpoints (both west and east):

| Endpoint | Effect |
|---|---|
| `GET /` | Renders the APM demo UI |
| `GET /error` | Raises `ZeroDivisionError` — captured as an APM error |
| `GET /custom_message/{msg}` | Sends a custom APM message event |
| `GET /catalog` | *(east-gateway only)* Proxies to east-catalog |
| `GET /inventory` | *(east-gateway only)* Proxies to east-inventory |
| `GET /pricing` | *(east-gateway only)* Proxies to east-pricing |
| `GET /reviews` | *(east-gateway only)* Proxies to east-reviews |
| `GET /orders` | *(east-gateway only)* Proxies to east-orders |
| `GET /recommendations` | *(east-gateway only)* Proxies to east-recommendations |
| `GET /search?q=` | *(east-gateway only)* Lexical search via search-es01 |
| `GET /search/asyoutype?q=` | *(east-gateway only)* Search-as-you-type via search-es01 |
| `GET /search/typeahead?q=` | *(east-gateway only)* Completion suggester via search-es01 |

### Synthetic Monitoring (Fleet-managed browser journeys)

A Fleet Server and `elastic-agent-complete` container run on `net-west`, registered as the **`docker-private`** private location in Kibana Synthetics. Three Playwright browser journeys run on a schedule from within the Docker network, clicking through the actual UIs rather than just pinging HTTP endpoints.

The `fleet-setup` service runs once on first boot to:
1. Initialise Fleet in Kibana
2. Create agent policies for Fleet Server and Synthetics
3. Register the `docker-private` private location
4. Write enrollment tokens to the shared `certs` volume

The `synthetics-setup` service then creates the three journeys below:

#### Journey 1 — Customer Shopping Journey (every 10 min)

**Target:** `https://east-gateway:8000/`

A shopper arrives at the east cluster storefront. The journey clicks through every downstream service button in sequence:

| Step | Service | Language |
|---|---|---|
| Load storefront | east-gateway | Python |
| Browse product catalog | east-catalog | Java |
| Check inventory levels | east-inventory | Go |
| Compare prices | east-pricing | .NET |
| Read customer reviews | east-reviews | PHP |
| Get recommendations | east-recommendations | Rust |
| Review order history | east-orders | Ruby |

Each click triggers a fan-out HTTP request through the gateway. The journey asserts the activity log shows ≥ 6 entries at the end. Every run produces a distributed APM trace spanning all 7 languages.

#### Journey 2 — APM Error Tracking & Custom Events (every 15 min)

**Target:** `https://west-webapp:8000/`

A QA engineer verifies APM instrumentation on the west cluster:
1. Triggers a deliberate `ZeroDivisionError` — confirms APM captures the stack trace as an error transaction
2. Fills the custom message input with `synthetic-monitor-check` and submits it — confirms custom APM event ingestion
3. Asserts the activity log shows ≥ 2 entries

#### Journey 3 — Demo Launchpad Health Check (every 20 min)

**Target:** `https://landing/` (nginx container, `net-west`)

Periodic sanity check on the demo landing page:
1. Loads the page and waits for the `<h1>` heading
2. Asserts both Kibana cluster links (`localhost:5601` and `localhost:5602`) are present
3. Asserts the east gateway link (`localhost:8001`) and "What this demo covers" section are visible

### Heartbeat (config-file monitors)

A Heartbeat container checks both Kibana instances, both Elasticsearch nodes, both webapps, and all seven east microservice health endpoints on a schedule. Data lands in `heartbeat-*` indices on `cluster-west`.

### Filebeat

`east-filebeat` is the sole Filebeat instance. It ships web access logs, PostgreSQL slow query logs, and API gateway metrics from `east_ingest_data/`, plus autodiscovers all microservice container logs via Docker labels. All data lands on `east-es01`. There is no west-filebeat — west has no application logs to collect.

### Metricbeat & Stack Monitoring

Stack monitoring is **local to each cluster** (not replicated):

| Instance | Scope | Ships to |
|---|---|---|
| `east-metricbeat` | Elasticsearch, Kibana, and Docker container metrics for all east services | `east-es01` |
| `west-metricbeat` | Elasticsearch and Kibana metrics only (stack monitoring) | `west-es01` |

Each Kibana's Stack Monitoring UI shows its own cluster's health. West sees west nodes; east sees east nodes, containers, and all service metrics.

### Machine Learning Anomaly Detection

Four ML jobs run continuously, partitioned by `service.name` with 5-minute bucket spans:

| Job | Type | What it detects |
|---|---|---|
| APM latency anomaly (built-in) | `high_mean` on `transaction.duration.us` | Unusual transaction durations across all APM services. Created via `POST /api/apm/settings/anomaly-detection/jobs`. |
| `demo-apm-error-rate` | `high_count` on failed outcomes | Spikes in error rate per service. Feeds from `traces-apm*` filtered to `event.outcome: failure`. |
| `demo-log-rate` | `high_count` on warn/error logs | Unusual rates of warning and error log messages per service. Feeds from `filebeat-*`. |
| `demo-latency-outliers` | `high_mean` on `transaction.duration.us` | Services with mean latency far above their baseline — finer-grained than the built-in job. |

All custom jobs write to `.ml-anomalies-custom-demo-ml` and have `model_plot_config.enabled: true` for rich visualization in the Anomaly Explorer.

### Cross-Cluster Alerting (West NOC → East Production)

Three alerting rules run in `kibana-west`, querying east data via CCS:

| Alert | Index Pattern | Condition |
|---|---|---|
| **East Microservices — High Error Rate** | `cluster-east:traces-apm*` | > 5 failed transactions in 5 min |
| **East Microservices — Degraded Mode Detected** | `cluster-east:filebeat-*` | > 3 degraded error/warn logs in 5 min |
| **East Microservices — Health Check Failure** | `cluster-east:heartbeat-*` | > 1 down status in 2 min |

These alerts demonstrate how an operations team on a separate cluster can monitor production without having direct access to the production Kibana.

### Guided Investigation Narratives

The landing page (https://localhost:8080) includes four step-by-step investigation playbooks that walk through the core Elastic Observability workflow: **detect → triage → correlate → root-cause**. All investigations target **East Kibana** (port 5602) unless noted.

#### Investigation 1 — The Cascading Slowdown

**Scenario:** A mission coordinator reports the ops portal is slow. No single alert has fired yet.

1. **APM → Service Map** — Watch for services turning yellow/red. `east-catalog` degrades first at second 168 of the 4-minute cycle.
2. Click `east-catalog` → **Transactions** → filter to `GET /aircraft`. Sort by duration descending. P95 spikes from ~50ms to 800–1500ms.
3. Open a slow trace. **Trace waterfall** confirms 60–80% of total duration is inside the `east-catalog` span. The slowness is not in any downstream call.
4. Click **View in Discover** in the waterfall header. Discover opens pre-filtered to `trace.id: <id>`. Look for log lines with `scenario: degraded` and the message `"aircraft registry database connection pool exhausted"`.
5. Check `east-inventory`, `east-pricing`, and `east-orders` in APM. Each shows a degradation window starting later (176s, 180s, 188s) — the cascade in action.
6. **ML → Anomaly Explorer → `demo-latency-outliers`** — all six services appear in the swimlane. Anomaly scores align with the degradation windows in the reference table.

**Root cause:** `east-catalog` exhausts its DB connection pool. All dependent services begin returning 503s as upstream catalog calls time out, each with its own retry budget creating the stagger.

---

#### Investigation 2 — Error Spike Correlation

**Scenario:** The `demo-apm-error-rate` ML job fires. Multiple services show 503 errors simultaneously — one incident or six?

1. **ML → Anomaly Explorer → `demo-apm-error-rate`** — multiple services flagged in the same 5-minute bucket with anomaly scores of 50–95.
2. Click an anomaly cell → **View in APM**. The Errors tab shows the exception. Note the message — each language reports its failure differently (Java: `"db pool exhaustion"`, Ruby: `"database deadlock"`, Go: `"depot sync timeout"`).
3. **Observability → Logs → Explorer** (or Discover against `filebeat-*`). KQL: `log.level: (WARN OR ERROR) AND scenario: degraded`. All matching log lines cluster within the same 36-second degradation window.
4. Add `service.name` as a breakdown field. Six services, different messages, same timestamp cluster — the signature of a cascading failure, not independent bugs.
5. **Observability → Logs → Log Anomalies** — the `demo-log-rate` job surfaces the same window as an unusual log volume spike, corroborating the APM signal from a different data source.
6. **Observability → SLOs** — filter to affected services. Availability SLOs (99.5% target) are burning error budget during the degradation window.

**Root cause:** All 503 errors are downstream consequences of the same catalog failure. The polyglot error messages describe each service's local failure response, not the underlying cause — a common trap in microservice debugging.

---

#### Investigation 3 — The Latency Outlier

**Scenario:** SLO burn rate alert fires for Tanker Pairings. Latency is far outside bounds but error rate looks almost normal.

1. **ML → Anomaly Explorer → `demo-latency-outliers`** → **Single Metric Viewer** → partition `east-recommendations`. Model bound shows a normal baseline of 10–80ms. Actual values during degradation: 600–2000ms.
2. **APM → Services → east-recommendations → Transactions**. The **Latency distribution** histogram shows a bimodal shape — two distinct peaks, not a tail. This is a hard on/off toggle, not gradual drift.
3. Filter transactions by duration > 500ms. Open one. The trace waterfall shows the entire request time consumed inside a single `recommendations` span with no downstream calls. The slowness is internal.
4. Click **View in Discover** → find the log with `"Recommendation model timeout"`. The `transaction.id` in the log matches the trace.
5. Open a normal trace (duration < 100ms) from the same service. Same endpoint, same code path — the bimodal distribution is purely the degradation flag, not load-dependent.
6. **Observability → SLOs → east-recommendations latency SLO** (P95 < 500ms target). During the degradation window, P95 blows past 500ms and the error budget is actively burning.

**Root cause:** The Rust recommendation engine simulates a model inference timeout during second 192–204. It's the last service to degrade but has the most extreme latency. Low error rate (10%) combined with extreme latency makes it the hardest to catch without ML.

---

#### Investigation 4 — Cross-Cluster NOC View

**Scenario:** You're an ops engineer on the NOC team. You have read-only visibility into east production via CCS — no direct production access.

1. Open **West Kibana** (port 5601). Log in as `ccs-analyst / CcsAnalyst1!`. This account has cross-cluster read permissions but cannot modify east data.
2. **Observability → APM** — the data view is `cluster-east:traces-apm*`. East production APM data rendered in your local Kibana with no replication.
3. **Alerting → Rules** — three CCS alerting rules watching east: *High Error Rate*, *Degraded Mode Detected*, *Health Check Failure*. All query `cluster-east:*` index patterns. Rule owner is west; data is east.
4. When a degradation window hits, **Alerting → Alerts** — the *East Microservices — High Error Rate* rule fires. Alert context includes east trace data retrieved via CCS at alert evaluation time.
5. **Discover** → switch to the `cluster-east filebeat` data view → KQL: `scenario: degraded`. Full-text log search across east's filebeat indices, executed from west. No data movement.
6. Dev Tools: `GET cluster-east:filebeat-*/_count`. The CCS coordinator (west-es01) proxies the query to east-es01. Response time is typically < 50ms over the net-ccs Docker bridge.

**Architecture value:** CCS centralises alerting and NOC dashboards in one place while keeping production data isolated. A compromised NOC workstation cannot write to production indices. No ETL or data replication required.

---

## Restarting After a Stop

If the stack was stopped (e.g. host reboot, `docker compose down` without `-v`), restart with:

```bash
docker compose up -d
```

The `setup` and `fleet-setup` services are idempotent — they detect existing state (certificates, tokens) and skip re-initialisation.

To bring up individual services without triggering dependency restarts:

```bash
docker compose up -d --no-deps <service-name>
```

---

## Troubleshooting

**Kibana shows a certificate warning** — expected. The stack uses self-signed TLS. Accept the warning in your browser.

**APM Server shows `health: starting` for several minutes** — normal. APM Server waits for Elasticsearch to be fully ready before marking itself healthy.

**Fleet Server or elastic-agent-synthetics fails to start** — the `fleet-service-token` file in the `certs` volume may be empty. Check with:

```bash
docker compose exec setup cat config/certs/tokens/fleet-service-token
```

If empty, remove the tokens directory and re-run fleet-setup:

```bash
docker compose exec -u 0 setup rm -rf config/certs/tokens/
docker compose up -d --no-deps fleet-setup
docker compose up -d --no-deps fleet-server elastic-agent-synthetics
```

**Out of memory** — the full stack requires roughly 16 GB. Reduce `ES_MEM_LIMIT` and `EAST_ES_MEM_LIMIT` in `.env` if needed (e.g. `2147483648` = 2 GB per node).

---

## Project Structure

```
.
├── docker-compose.yml          # Root compose — include directives only
├── .env                        # Passwords, ports, stack version
├── compose/                    # Compose sub-files (included by root)
│   ├── setup.yml               # One-shot TLS + user provisioning
│   ├── cluster-west.yml        # West ES cluster, Kibana, APM, beats, webapp
│   ├── cluster-east.yml        # East ES cluster, Kibana, APM, beats, search, microservices (dev)
│   ├── cluster-east-prod.yml   # Production copy of east microservices (no anomalies)
│   └── fleet.yml               # Fleet Server, synthetics agent, heartbeat, landing
├── config/                     # Beat / Kibana configuration files
│   ├── heartbeat.yml           # Heartbeat monitor definitions
│   ├── west-filebeat.yml       # West filebeat config
│   ├── east-filebeat.yml       # East filebeat config (container log collection)
│   ├── west-metricbeat.yml     # West metricbeat config
│   ├── east-metricbeat.yml     # East metricbeat config
│   ├── kibana.yml              # West Kibana config
│   ├── kibana-east.yml         # East Kibana config (APM enabled)
│   └── kibana-search.yml       # Search cluster Kibana config
├── app/                        # West webapp (Python / FastAPI + APM)
│   ├── main.py
│   ├── templates/index.html
│   └── dockerfile
├── app-east/                   # East microservices (linux/amd64)
│   ├── gateway/                # Python / FastAPI  — API gateway + UI
│   ├── catalog/                # Java / Spring Boot — product catalog
│   ├── inventory/              # Go / net/http      — stock levels
│   ├── pricing/                # .NET / ASP.NET     — dynamic pricing
│   ├── reviews/                # PHP / Slim         — product reviews
│   ├── orders/                 # Ruby / Sinatra     — order management
│   └── recommendations/        # Rust / Axum        — product scoring
├── loadgen/                    # Traffic generator script (alpine/curl)
│   └── loadgen.sh
├── html/                       # Landing page (served by nginx)
│   └── index.html
├── filebeat_ingest_data/       # Sample air quality logs (west)
├── west_ingest_data/           # Sample app event logs (west)
└── east_ingest_data/           # Sample web/DB/API logs (east)
```
