# Kraken Library Layer (`lib/`)

The `lib` directory houses reusable, production-grade subsystems which compose the core platform behaviors used by all Kraken services (origin, build-index, tracker, proxy, agents). This README is a deep technical reference detailing each package’s role, internal algorithms, configuration surfaces, extension points, and operational concerns.

---

## Contents

| Package | Purpose | Key Responsibilities |
|---------|---------|----------------------|
| `backend/` | Pluggable remote storage backends | Fetching, stat'ing, uploading blobs for namespaces (S3, GCS, HTTP, HDFS, Registry, Shadow, SQL, Noop). |
| `blobrefresh/` | Deduplicated remote blob -> local CAS refresh | On-demand background download + metainfo generation with concurrency + size gating. |
| `containerruntime/` | Container runtime abstraction | Provides `docker` and `containerd` clients bound to private registry endpoints. |
| `dockerregistry/` | Embedded registry integration | Wraps docker/distribution with Kraken storage/transfer hooks. |
| `hashring/` | Rendezvous hashing ring | Consistent hashing + health filtering + passive/active variants. |
| `healthcheck/` | Active + passive health filters | Determines healthy membership for rings & clusters. |
| `hostlist/` | DNS / static host resolution with TTL | Supplies dynamic address sets for upstreams. |
| `hrw/` | Hash utilities (Highest Random Weight) | Rendezvous hash primitives. |
| `metainfogen/` | Torrent metainfo generation | Deterministic piece length selection + on-disk metadata persistence. |
| `middleware/` | HTTP metrics instrumentation | Status counting + latency timing middlewares. |
| `persistedretry/` | Durable task + retry executor | Persistent store backed queue + timed polling + rate limiting. |
| `store/` | Content-addressable & upload stores | CAS with LRU, multi-volume hashing, upload staging, file operations. |
| `upstream/` | Host configuration with health integration | Builds active/passive lists & rings from host and health configs. |

Cross-cutting utilities (bandwidth limiter, memsize, log, dedup, etc.) live under `utils/` and are referenced heavily but not reiterated here.

---

## Dependency Graph (Conceptual)

```
	  +--------------+      +---------------+
	  |  hostlist    |----->| healthcheck   |
	  +------+-------+      +-------+-------+
		   |                      |
		   v                      v
	    +----------+        +---------------+
	    | hashring |<------>| upstream      |
	    +----------+        +---------------+
		    ^                     ^
		    |                     |
 +--------------+----+         +------+---------------+
 | persistedretry  |         |   blobrefresh          |
 +-------+----------+         +-----------+-----------+
	   |                                |
	   v                                v
   +-----------+                +------------------+
   | store/    |<---------------| metainfogen      |
   +-----------+                +------------------+
	   ^                                 ^
	   |                                 |
	   |                          +------+------+
	   |                          | dockerregistry |
	   |                          +------+------+
	   |                                 ^
	   v                                 |
     +---------+                     +------+------+
     | backend |<--------------------| containerruntime |
     +---------+                     +-------------+
```

Arrows denote primary read / call direction; some subsystems also report metrics or logs which are omitted for clarity.

---

## Backend Subsystem (`backend/`)

Provides namespace -> backend client resolution with optional bandwidth throttling and readiness semantics.

### Key Types
| Symbol | Role |
|--------|------|
| `Manager` | Holds ordered list of namespace regex -> client bindings. |
| `Config` | Per-binding configuration (namespace regex + backend map + bandwidth + readiness). |
| `AuthConfig` | Credential map overlay keyed by namespace. |
| `Client` (interface) | Abstract operations: `Download`, `Upload`, `Stat`, etc. Implementation-specific. |
| `ThrottledClient` | Decorator applying ingress/egress rate limiting. |

### Namespace Resolution Algorithm
1. Configuration supplies an ordered list of `Config` objects each with exactly one backend type entry (e.g. `{ "s3": {...} }`).
2. On `Manager.GetClient(namespace)`, iterate list linearly; first whose compiled regexp matches returns its client.
3. Special namespace `noop` returns `NoopClient` (provides predictable absent behavior).
4. Readiness: For clients with `MustReady = true`, `CheckReadiness` performs a `Stat` call on a synthetic `(namespace, ReadinessCheckName)` digest; any error other than `ErrBlobNotFound` indicates not ready.

### Bandwidth Throttling
* If `Bandwidth.Enable` true, wraps client using limiter (`bandwidth.NewLimiter`) controlling ingress/egress tokens per second.
* Global dynamic adjustment: `Manager.AdjustBandwidth(denominator)` divides configured rates uniformly across clients supporting throttling.

### Extension Points
* Add new backend: register factory via `getFactory(name)`; implement `Create(config, auth, stats, logger) (Client, error)`.
* Backpressure: integrate circuit breaker before throttle.

---

## Blob Refresh (`blobrefresh/`)

Deduplicated asynchronous remote fetch + torrent metainfo generation for a digest.

### Flow
1. Client invokes `Refresher.Refresh(namespace, digest)`.
2. Manager resolves backend client for namespace.
3. Performs `Stat` (synchronous): distinguishes exist vs not found vs other error.
4. Size guard: rejects if blob exceeds configured `SizeLimit` (if > 0).
5. Dedup key = `<namespace>:<digest>` fed into `dedup.RequestCache.Start` which ensures at most one active download.
6. Background goroutine downloads blob into CAS (`cas.WriteCacheFile`) and times operation. On success increments `downloads` counter.
7. Invokes `metainfogen.Generator.Generate` to compute metainfo & persist metadata.
8. Executes any supplied `PostHook` callbacks.

### Errors
| Error | Meaning |
|-------|---------|
| `ErrPending` | Existing in-progress download. Caller can poll later. |
| `ErrNotFound` | Backend client reports blob missing. |
| `ErrWorkersBusy` | Dedup worker pool saturated (capacity gating). |

### Guarantees
* Idempotent: Multiple simultaneous refresh requests collapse into single download.
* At-least-once triggers on transient errors (retry by caller). No internal persistence of failures beyond dedup in-flight map.

---

## Container Runtime (`containerruntime/`)

Abstracts container platform integration (Docker daemon + containerd) for operations needing local image management bound to a Kraken-backed registry host.

| Component | Role |
|-----------|------|
| `Factory` | Builds runtime-specific clients given config + registry base reference. |
| `DockerClient` | Pull / tag / push operations via Docker HTTP API. |
| `containerd.Client` | containerd namespace operations. |

Extension: Add new runtime by extending `Config` and updating factory to include new client constructor.

---

## Docker Registry Integration (`dockerregistry/`)

Wraps upstream `docker/distribution` registry with a custom storage driver bridging Kraken CAS + transfer logic.

### Parameter Construction
* `ReadWriteParameters` injects `transferer`, `castore`, metrics scope under constructor label `rw`.
* Config modifies upstream storage driver section to install Kraken driver & disables internal redirect logic (handled by proxy/nginx layer).

### Data Paths
| Path | Behavior |
|------|----------|
| Manifest Upload | Writes manifest object then triggers preheat event downstream. |
| Blob Upload | Streamed into upload store then committed to CAS verified by digest. |
| Blob Download | Served from local CAS or proxied via Kraken distribution (P2P + origin). |

---

## Hash Ring (`hashring/`)

Rendezvous (Highest Random Weight) hashing with health filtering to select replica owners for a digest shard.

### Algorithm
1. On `Refresh`, resolve current address set from `hostlist.List`.
2. Build HRW hash with weight=100 per address if membership changed.
3. Determine healthy set via `healthcheck.Filter` run.
4. `Locations(d)` retrieves ordered node list sized to membership; iterates until `MaxReplica` healthy addresses gathered; fallback rules ensure at least one address always returned.

### Passive vs Active
* Active: External monitor periodically executes health probes updating filter state.
* Passive: Health derived from transient request failures (see `healthcheck.PassiveFilter`).

### Watchers
Registered via options to react (e.g., update caches) to membership changes.

---

## Health Checking (`healthcheck/`)

Two complementary mechanisms:
| Component | Purpose |
|----------|---------|
| `Filter` + `Monitor` | Active probing with thresholds: `Fails`, `Passes`, `Timeout`, `Interval`. |
| `PassiveFilter` | Marks hosts unhealthy based on `Fails` occurrences within `FailTimeout`; keeps them unhealthy for that window. |

Active disabled via config flag; fallback yields all hosts considered unhealthy initially (`NoopFailed`) ensuring conservative selection until first success.

---

## Host List (`hostlist/`)

Resolves dynamic address sets via either static array or DNS record (record port appended to each entry). TTL-cached to reduce DNS churn.

| Feature | Notes |
|---------|-------|
| Static Validation | Ensures `host:port` format. |
| DNS Resolution | Looks up A records, attaches configured port. Empty record => error. |
| TTL | Governs cache re-resolution frequency (default 5s). |

---

## Metainfo Generation (`metainfogen/`)

Deterministic piece length selection based on blob size using configured length tiers (`PieceLengths`). Generates torrent-like `MetaInfo` and stores metadata (`metadata.TorrentMeta`) bound to digest key in CAS metadata store.

| Step | Description |
|------|-------------|
| Cache Stat | Obtain size; choose piece length tier. |
| Digest Verification | Provided by upstream CAS on write path. |
| Meta Construction | `core.NewMetaInfo(d, reader, pieceLength)` streaming piece hashing. |
| Metadata Persist | `SetCacheFileMetadata(digest.Hex(), torrentMeta)`. |

---

## Middleware (`middleware/`)

HTTP middleware wrappers for request latency & status instrumentation (tally timers and counters). Typical usage inside service router registration.

Extension: Add auth / tracing middlewares at this layer for cross-service consistency.

---

## Persisted Retry (`persistedretry/`)

Durable task execution with automatic retry polling.

### Core Interfaces
| Symbol | Description |
|--------|-------------|
| `Task` | Provides serialization, readiness predicate, timestamps, failure count, tags. |
| `Store` | Persists tasks (pending/failed lookup, mark transitions). |
| `Executor` | Executes a task (business logic). |
| `Manager` | Orchestrates worker goroutines, tickers, queuing, retry intervals. |

### Lifecycle
1. `Add`: Stores task as pending if ready; else failed. Optionally enqueues directly into `incoming` channel.
2. Workers (incoming + retry) drain channels executing tasks via Executor.
3. On success: remove from store. On failure: mark failed (persist failure count) for later polling.
4. Ticker loop periodically queries failed tasks; for each ready + backoff-satisfied task invokes `retry` to enqueue into retry channel.
5. Rate limiting: Sleep `limit = MaxTaskThroughput * totalWorkers` after each exec to bound throughput.

### Metrics (Implicit in code)
* `exec_failures` – executor returned error.
* `get_failed_failure` – retrieval of failed tasks failed.
* `task_failures` – per-task failure counter tagged with task tags.

Enhancements: Add histogram for execution latency, backlog depth gauges, per-task-type retry success ratio.

---

## Content Store (`store/`)

Implements content-addressable storage with separate upload staging and LRU-cached files.

### CAStore
| Component | Role |
|-----------|-----|
| `uploadStore` | Temporary files for streaming uploads before verification. |
| `cacheStore` | LRU-managed CAS for immutable objects. |
| `cleanupManager` | Periodic cleanup jobs for upload + cache directories. |

### Write Path
1. Create upload file (temp name); stream data.
2. Move finalize: verify digest (unless `SkipHashVerification` true) using streaming digester.
3. Rename/move into cache location; handle `os.IsExist` idempotently.

### Multi-Volume Sharding
* If `Volumes` configured, symlink fanout for 256 hex subdirectories distributed via rendezvous hash across physical volumes.
* Facilitates heterogeneous weighted disk distribution.

### Config Highlights
| Field | Default | Meaning |
|-------|---------|---------|
| `Capacity` | 1,000,000 entries | LRU capacity (# entries) for in-memory index. |
| `SkipHashVerification` | false | Trade integrity for write speed (testing only). |

---

## Upstream (`upstream/`)

Convenience builders combining host list + health configuration.

| Type | Behavior |
|------|----------|
| `ActiveConfig` | Hosts + active health (monitor+filter); `StableAddr` for advertisement. |
| `PassiveConfig` | Hosts + passive failure tracking. |
| `PassiveHashRingConfig` | Hosts + passive filter + rendezvous ring. |

Extension: Add `HybridConfig` mixing passive + active thresholds (future improvement).

---

## Configuration Reference (Selected)

| Subsystem | Key Fields | Notes |
|-----------|------------|-------|
| backend.Config | `namespace`, `backend`, `bandwidth`, `must_ready` | Namespace regex ordering matters. |
| blobrefresh.Config | `size_limit`, workers | Guard against very large blobs. |
| hashring.Config | `max_replica`, `refresh_interval` | Replica fanout vs redundancy tradeoff. |
| healthcheck.FilterConfig | `fails`, `passes`, `timeout` | Debounce flapping endpoints. |
| healthcheck.PassiveFilterConfig | `fails`, `fail_timeout` | Penalize burst failures. |
| hostlist.Config | `dns`, `static`, `ttl` | DNS precedence over static. |
| persistedretry.Config | `num_incoming_workers`, `retry_interval`, `incoming_buffer`, `max_task_throughput` | Throughput & fairness tuning. |
| store.CAStoreConfig | `capacity`, `volumes`, `skip_hash_verification` | Storage integrity & distribution. |

---

## Metrics & Observability (Common Patterns)

All subsystems tag metrics with `module=<name>`. Add subsystem-specific dimensions (e.g., `executor` in persistedretry, `priority` in peer handout policy outside lib). Services consuming `lib/` packages should propagate a root tally scope.

Recommended additional instrumentation (not all present):
* Latency timers around backend client operations (download/stat). 
* Cache hit ratios for CAS and metainfo retrieval. 
* Ring refresh durations and membership churn counters. 
* Persisted retry queue depth gauges.

---

## Extension Points Summary

| Area | How to Extend |
|------|---------------|
| Backends | Implement new factory, register name, supply config struct. |
| CAS Volumes | Provide additional `Volume` entries with weights. |
| Dedup Refresh Hooks | Implement `PostHook` to trigger replication or indexing events. |
| Persisted Retry Executors | Implement `Executor` with custom `Name()` for per-executor tagging. |
| Hash Ring Membership | Implement custom `hostlist.Resolver` (DNS SRV, service discovery API). |
| Health Strategy | Combine active + passive filters, or custom adaptive filter injecting SLO error budgets. |

---

## Security & Hardening Considerations

| Concern | Mitigation |
|---------|------------|
| Backend credential leakage | Store credentials in secrets overlay (AuthConfig) not code; restrict logs. |
| Malicious large blob ingestion | Enforce `blobrefresh.SizeLimit`, validate digest early, optional content scanning hook. |
| CAS tampering | Run on immutable storage volumes; disable `SkipHashVerification` in production. |
| Excessive task amplification | Rate limit persisted retry throughput, guard executor side-effects idempotently. |
| Health poisoning (false negatives) | Tune `fails/passes` thresholds; for passive filter separate transient network errors from application failures. |

---

## Operational Tips

* Monitor ring membership churn; unexpected churn implies DNS instability or health flapping.
* Track CAS cleanup durations; long runs may indicate slow disk or oversized capacity parameter.
* Periodically adjust backend bandwidth denominators under load to relieve saturation without redeploy.
* Validate persisted retry queue growth after outages; consider draining / batch throttling.

---

## Future Improvements (Ideas)

* Unified metrics schema + OpenTelemetry exporters across all modules.
* Adaptive ring replica count based on swarm size / load.
* Tiered CAS (SSD + HDD) via multi-volume weighting and hotness tracking.
* Backpressure integration between persisted retry and dedup refreshers.
* Pluggable encryption at rest in CAS volumes.

---

## Contributing

When adding new library modules:
1. Provide clear interface boundaries and minimal surface area. 
2. Supply configuration struct with sane defaults via `applyDefaults` pattern. 
3. Add unit tests covering error cases and concurrency invariants. 
4. Emit metrics with `module=<modulename>` tag consistently. 
5. Update this README (module table + relevant sections).

---

## License

Apache 2.0 (see root `LICENSE`).

---

## Summary

The `lib/` layer aggregates Kraken’s reusable primitives—consistent hashing, health gating, remote storage access, content-addressable persistence, deduplicated fetching, and durable retry orchestration—forming the backbone upon which higher-level services implement distribution logic. Its modular design and explicit configuration schemas enable incremental extension, observability, and robust operation at scale.

