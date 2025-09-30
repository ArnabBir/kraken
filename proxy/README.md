# Kraken Proxy Service

The `proxy` module provides proactive and on-demand warming of the Kraken origin + build-index layers for container image distribution. It ingests Docker Registry event notifications ("preheat"), supports explicit prefetch requests for image tags ("prefetch"), overrides the Docker Registry catalog endpoint for large-scale virtual repositories, and fronts multiple internal HTTP services behind a single nginx layer.

This document delivers an end-to-end, low-level technical deep dive suitable for contributors: architecture, request lifecycles, concurrency, caching semantics, integration points with other Kraken subsystems (origin + build-index), configuration, metrics, error semantics, extensibility, security, and operational guidance.

---

## Responsibilities & Scope

| Responsibility | Description |
|----------------|-------------|
| Preheat | React to asynchronous Docker registry push notifications and trigger early caching of all referenced layers at origins. |
| Prefetch | Accept an API call specifying a fully-qualified tag and proactively download manifest + referenced layers (best-effort). |
| Registry Override | Provide a curated `_catalog` view by aggregating tag listings from build-index, enabling logical multi-tenant repository discovery. |
| Multi-Service Orchestration | Start and supervise: proxy HTTP server (preheat/prefetch), registry override server, internal Docker registry HTTP server, and nginx front-end. |
| Transfer Integration | Compose a read/write transfer pipeline via `transfer.ReadWriteTransferer` bridging tag resolution (build-index) and content retrieval (origins) into a local CAS. |

Out of scope: peer-to-peer distribution (handled by agents), replication or retention policies (handled by origin/build-index), authentication (expected via surrounding infrastructure / nginx config).

---

## High-Level Architecture

```
		      +----------------------------+
External Triggers ->|  Proxy Server (chi HTTP)   |--+-- /registry/notifications (Preheat)
 (Docker events,    |    /proxy/v1/registry/...  |  |-- /proxy/v1/registry/prefetch (Prefetch)
  CI pipelines)     +--------------+-------------+  |
					|                |
					v                |
				Preheat Handler         | Prefetch Handler
				(manifest walk)         | (tag -> manifest -> layers)
					|                |
	      +---------------------+----------------+------------------+
	      |                                                        |
	      v                                                        v
   Origin Cluster (blobclient.ClusterClient)            Build-Index Cluster (tagclient)
	      |                                                        |
	      v                                                        |
   Metainfo / Blob Download (CAS warm)                                |
	      |                                                        |
	      +-------------------+------------------------------------+
				     v
			     Local CAStore (CAS)

   +-------------------------+       +-----------------------------+
   | Registry Override Server|<----->| Build-Index Tag List API    |
   +------------+------------+       +-----------------------------+
		  |
		  v
	    /v2/_catalog

		     +------------------------------------+
		     |          nginx Frontend            |
    Clients  <---->| TLS termination + port fanout      |<--- (Ports array)
		     +----------------+-------------------+
					 |
	 +---------------------------+------------------------------+
	 |       Internal HTTP endpoints (registry, proxy, override)|
	 +----------------------------------------------------------+
```

Key Processes started (goroutines):
* `proxyserver.ListenAndServe` – preheat & prefetch APIs.
* Docker registry (from `dockerregistry.Config`) – serves client pulls/pushes (integrated with Kraken transferer). 
* `registryoverride.ListenAndServe` – overrides `_catalog` endpoint.
* `nginx.Run` – consolidated ingress (ports supplied by CLI). 

---

## Bootstrap Flow (`cmd.Run`)

1. Parse CLI flags (`--port`, `--config`, `--cluster`, `--secrets`).
2. Load YAML config (then overlay secrets file if provided) into `cmd.Config` struct.
3. Initialize logging (zap) and metrics (tally) scopes; emit version metric asynchronously.
4. Instantiate local `CAStore` (content addressable store) for caching downloaded manifests / layers.
5. Build TLS client config and host lists for origin + build-index clusters (w/ healthcheck injection).
6. Construct: 
   * `blobclient.ClusterClient` (origin interaction: `DownloadBlob`, `GetMetaInfo`).
   * `tagclient.ClusterClient` (build-index: tag resolution and pagination queries).
7. Create `transfer.ReadWriteTransferer` bridging tag lookups + origin CAS population.
8. Launch proxy HTTP server (`proxyserver.New`).
9. Instantiate (and serve) Docker registry with read/write parameters referencing transferer, CAS, metrics.
10. Launch registry override server.
11. Run nginx with a templated context containing all internal listener addresses (registry, override, proxy) building frontend bindings for provided ports.

Error semantics: any fatal initialization issue (`log.Fatalf`) terminates process early ensuring no partial service exposure.

---

## Configuration Surface (`cmd.Config`)

| Field | YAML | Purpose |
|-------|------|---------|
| `CAStore` | `castore` | Local on-disk / memory content store parameters (capacity, eviction). |
| `Registry` | `registry` | Embedded Docker registry configuration (listeners, storage driver, auth plugin integration). |
| `BuildIndex` | `build_index` | Active upstream host list for tag resolution cluster (with health checks, timeouts). |
| `Origin` | `origin` | Active upstream host list for origin cluster for blob downloads & metainfo. |
| `ZapLogging` | `zap` | Structured logging config (level, sampling, output). |
| `Metrics` | `metrics` | Backend metrics sink config (statsd, m3, etc.). |
| `RegistryOverride` | `registryoverride` | Override server listener binding. |
| `Server` | `server` | Proxy server listener config (preheat/prefetch endpoints). |
| `Nginx` | `nginx` | Nginx front configuration (template variables, TLS). |
| `TLS` | `tls` | Client-side TLS (CAs, certs) for connecting to internal clusters. |

Runtime Overrides: Secrets file overlay permits injecting TLS certs or credentials post base config load.

---

## Proxy HTTP Server Endpoints

| Method | Path | Handler | Purpose | Response Codes |
|--------|------|---------|---------|----------------|
| GET | `/health` | `healthHandler` | Liveness probe | 200 OK + body `OK` |
| POST | `/registry/notifications` | `PreheatHandler` | Ingest Docker registry event batch | 200 OK (always) / 500 decode error |
| POST | `/proxy/v1/registry/prefetch` | `PrefetchHandler` | Explicit prefetch by fully-qualified tag | 200 success JSON / 400 bad tag / 500 internal |
| (pprof) | `/debug/pprof/*` | stdlib mux | Profiling endpoints | 200 / 404 |
| GET | `/v2/_catalog` | registryoverride | Catalog listing w/ pagination | 200 JSON / 400 invalid query |

Middleware: `middleware.StatusCounter` (per-status counts), `middleware.LatencyTimer` (per-route latency histograms).

---

## Preheat Flow (Docker Registry Notifications)

Input: Batch JSON payload per Docker distribution notification spec. Each event has `Action`, `Target.MediaType`, `Target.Digest`, `Target.Repository`.

Filtering: Only events where `Action == push` and `Target.MediaType` matches `application/vnd.docker.distribution.manifest.v\d+` are processed.

Lifecycle:
1. Decode payload -> `Notification`.
2. Extract manifest push events.
3. For each manifest digest: `fetchManifest` using `clusterClient.DownloadBlob(repo, digest, buf)` with retry/backoff (up to 4 attempts, exponential 100ms base) to mask race between registry commit and notification emission.
4. Parse manifest (`dockerutil.ParseManifest`) -> iterate layer descriptors.
5. For each layer digest, invoke `clusterClient.GetMetaInfo(repo, layerDigest)` to trigger origin side metainfo generation or retrieval (warming origin). If asynchronous flag disabled (`synchronous==false`) request performed in goroutine.
6. Log successes/failures per layer; errors encountering 202 (Accepted) ignored (in-progress state acceptable).

Concurrency Model: Each manifest layer warming executed concurrently (one per goroutine) but only after manifest fetch consolidation. The manifest fetch itself loops serially until success, ensuring minimal fan-out before confirmation.

Error Handling: Malformed body -> 500; no explicit per-event status returned; system is best-effort warm path (idempotent operations). Partial failures logged, not surfaced to caller (Docker registry expects non-blocking behavior).

---

## Prefetch Flow (Explicit Tag Warm)

Purpose: On-demand acceleration for anticipated image pull (e.g., CI pipeline about to schedule multiple hosts).

Request Body:
```
{ "tag": "<registry-host>/<namespace>/<image:tag>", "trace_id": "<optional-id>" }
```

Steps:
1. Parse JSON; validate tag shape (components >= 3). `DefaultTagParser`: splits on `/`, takes `[1]` as namespace, `[2]` as `image:tag` composite.
2. Build key `<namespace>/<image:tag>` (URL-escaped) -> `tagClient.Get` -> digest of manifest (maps to content-addressed manifest blob).
3. Download manifest blob into buffer. Errors -> 500.
4. Attempt to decode as ManifestList; if valid, iterate child manifests, download each child manifest blob, aggregate layers; else parse as single Manifest.
5. Extract layer descriptors -> convert digests -> accumulate size.
6. Respond 200 immediately (non-blocking) with success JSON while asynchronous downloads proceed (unless `synchronous` flagged true in construction, currently false in `cmd.Run`).
7. Parallel layer downloads (goroutines) perform `DownloadBlob(namespace, digest, ioutil.Discard)` measuring per-blob duration and incrementing counters (downloaded/bytes). 202 responses ignored.
8. On completion: failures aggregated to metrics; logs include digest-specific errors.

Edge Cases:
* Invalid tag format -> HTTP 400.
* Tag not found in build-index -> HTTP 500 (internal error classification).
* Layers referencing non-existent blobs -> counted as failures per digest.

---

## Registry Override Catalog Pagination

Endpoint: `GET /v2/_catalog` with queries `?n=<limit>&last=<offset>`.

Behavior:
1. Parse query into `tagclient.ListFilter` (limit & offset).
2. Call `tagClient.ListWithPagination("", filter)` retrieving tag identifiers.
3. Split each tag on `:` retaining repository portion; aggregate unique repositories (using `stringset`).
4. Determine next offset via `listResp.GetOffset()`; when present, set `Link` header per Docker registry pagination spec (original scheme+host omitted—client reconstructs base path).
5. Return JSON: `{ "repositories": ["repo1", "repo2", ...] }`.

Error Cases: invalid limit (non-int or zero), duplicate query parameters, list pagination offset parse errors.

---

## Local Content Store (CAStore) Usage

Although the proxy downloads manifests and layers primarily to warm remote origins, the `transfer.ReadWriteTransferer` also writes into the local CAS, allowing subsequent registry pull operations served locally (subject to retention policy). CAS configuration (`castore`) defines capacity management strategy (LRU / size-based eviction as implemented in `lib/store`).

---

## Metrics

Global middleware:
* `status` counters per route.
* `latency` histograms per route.

Prefetch specific (sub-scope `prefetch`):
* `requests` – count of POST prefetch calls.
* `initiated` – count of accepted prefetch operations.
* `blob_download_time` – timer per individual blob download.
* `bytes_downloaded` – counter of total bytes requested (approx layer size sum).
* `blobs_downloaded` – successful layer count.
* `failed` – number of prefetch operations with at least one blob failure.

Version emission: background goroutine increments a version gauge / tag representing build metadata.

Operational Signals:
* Spike in `failed` correlated with origin errors -> inspect origin readiness / network.
* Low `bytes_downloaded` vs `initiated` suggests manifest-only warms (empty layers) or systematic early failure.

---

## Error Semantics Summary

| Context | Condition | HTTP | Notes |
|---------|-----------|------|-------|
| Preheat | Body decode fail | 500 | Notification rejected entirely. |
| Preheat | Manifest not found after retries | 200 | Logged; warm skipped (best-effort). |
| Prefetch | Invalid JSON / tag parse | 400 | Immediate error JSON response. |
| Prefetch | Tag client failure | 500 | Upstream build-index or network issue. |
| Prefetch | Manifest parse failure | 500 | Possibly unsupported media type. |
| Prefetch | Some layer downloads fail | 200 | Reported only via metrics/logs. |
| Catalog | Invalid query / limit | 400 | Input validation. |

Design Bias: Preheat/prefetch endpoints minimize user-visible failures; partial successes are acceptable if at least some warm operations succeed.

---

## Concurrency & Performance

* Prefetch fan-out per layer: each layer in its own goroutine; limited implicitly by manifest size distribution (typical < 30 layers). Potential future enhancement: worker pool or semaphore to cap concurrency.
* Preheat defers layer warming to goroutines when asynchronous flag false (currently asynchronous) ensuring rapid notification ACK.
* Manifest list expansion multiplies concurrency by number of platform manifests × layers per manifest.
* CAS locality: repeated prefetch of same layer incurs minimal cost if CAS hit logic short-circuits (download path handles 202 or already have piece semantics via origin).

Latency Critical Path: Prefetch initial response excludes layer downloads (returns after manifest decode) unless synchronous mode activated for debugging.

---

## Security Considerations

* No authentication built-in: rely on surrounding ingress (nginx) and network policy to restrict prefetch / notification endpoints.
* Potential abuse: flood of synthetic prefetch tags -> excessive origin downloads. Mitigation: external rate limiting + future quota middleware.
* Notification authenticity: Accepts posted JSON; deploy behind Docker registry configured to emit directly (avoid 3rd party injection).
* TLS: Terminated at nginx; internal upstream cluster calls use client TLS per config ensuring origin/build-index integrity.

---

## Extensibility Opportunities

| Area | Extension Strategy |
|------|--------------------|
| Tag parsing | Implement custom `TagParser` (e.g. multi-segment namespaces) injected in `NewPrefetchHandler`. |
| Prefetch scheduling | Add queue + worker pool for rate-controlled warming. |
| Media type support | Extend manifest parsing to handle OCI index / image layout variants explicitly. |
| Catalog filtering | Add allow/deny patterns before repository aggregation. |
| AuthN/AuthZ | Insert middleware before handlers for token validation. |
| Observability | Emit per-layer success/failure structured events (currently only counters). |

---

## Operational Runbook Highlights

| Symptom | Probable Cause | Action |
|---------|----------------|--------|
| High 500s on prefetch | Build-index cluster down | Check upstream health, fail open by disabling prefetch temporarily. |
| Preheat warming gaps | Registry emitted event before manifest ready | Validate exponential backoff window; consider raising retries. |
| Layer download failures logged | Origin partial outage | Compare with origin readiness metrics; tune origin store TTLs. |
| Catalog pagination inconsistent | Offset logic drift | Inspect `ListWithPagination` upstream responses for offset marker issues. |

Capacity Planning: Estimate QPS of prefetch + average layers per image; ensure concurrency does not saturate origin cluster. Tune prefetch concurrency if adding a worker model.

---

## Testing & Edge Cases (From `server_test.go`)

* Health endpoint returns constant `OK`. 
* Preheat ignores irrelevant events (non-push or non-manifest MIME types). 
* Prefetch rejects malformed tag formats. 
* Prefetch handles manifest-only vs multi-layer configs. 
* Prefetch counts success despite asynchronous layer downloads (test validates initial response path). 

Strategy: Additional tests can be added for manifest list expansion, partial layer failures, metrics emissions (using test tally scope), and tag pagination overflow.

---

## Future Enhancements

* Deduplicated in-flight prefetch (digest-level) to avoid parallel duplicate warms.
* Layer popularity tracking to inform eviction / prefetch prioritization.
* Pluggable prefetch policy (time-based, webhook triggers, predictive based on deployment schedules).
* Structured tracing integration (propagate `trace_id` through origin/build-index calls).
* Optional synchronous acknowledgment mode for CI gating (report success only when all layers warmed).

---

## Contribution Guidelines

When submitting changes:
* Include benchmarks or metrics deltas for concurrency-affecting modifications.
* Provide unit tests for new handlers or parsing logic.
* Maintain backward compatibility for config fields; introduce new YAML keys under additive semantics.
* Document new metrics and configuration in this README.

---

## License

Apache 2.0 (see root `LICENSE`).

---

## Summary

The proxy is the proactive warm layer in Kraken, bridging registry semantics with the origin + build-index clusters to reduce tail latency on large-scale image distribution. Its design favors best-effort, low-latency acknowledgment, modular extension (tag parsing, prefetch policy), and operational transparency via metrics and structured logging.

