# Kraken Origin Service

The `origin` service is the authoritative entrypoint of the Kraken content distribution network. It fronts remote object storage backends (S3 / GCS / HDFS / HTTP / Docker registries / custom testfs) and exposes a consistent HTTP API for:

* Accepting new blob uploads (content‑addressed by SHA256 digest).
* Generating & serving BitTorrent metainfo (torrent metadata) used by the P2P data plane.
* On‑demand lazy materialization (read‑through caching + asynchronous write‑back) of blobs from configured backends.
* Coordinated replication of newly uploaded content across an origin hash ring.
* Serving blobs directly to agents as an origin seeder when P2P is cold or unavailable.
* Cross‑cluster replication to remote origin deployments.

This document provides a deep technical dive into the origin module: architecture, request lifecycle, data structures, concurrency behavior, configuration surface, failure modes, operational concerns, and extension points.

---

## High‑Level Architecture

```
					  +-------------------------------+
	 Upload /     |                               |   Remote Cluster (optional)
	 Download --->|  Origin (this module)         |<---- replicateToRemote
					  |                               |
					  |  +-------------------------+  |    +------------------+
  Agents /       |  |  Blob Server (HTTP API)|  |    |  Remote Backends |
  Tooling        |  +-----------+-------------+  |    | (S3/GCS/HDFS/...)|
					  |              |                |    +---------+--------+
					  |              v                |              ^
					  |      CAStore (disk cache)     |              |
					  |              |                |              |
					  |     +--------+----------+     |    +---------+----------+
					  |     | Metainfo Generator |----+--->|  Backend Manager   |
					  |     +--------+----------+     |    +---------+----------+
					  |              |                       |  |  |  |
					  |     +--------v----------+            |  |  |  +--> Auth / Bandwidth watcher
					  |     | Blob Refresher    |<-----------+  |  +-----> Backend clients (typed)
					  |     +--------+----------+               +--------> Persisted Write‑Back tasks
					  |              |
					  |   +----------v-----------+   Hash ring membership & sharding
					  |   |  Replication /      |<-------------------------------+
					  |   |  Duplicate Uploads  |--------------------------------+
					  |   +---------------------+
					  +---------------+---------------+
											|
											v
								Local P2P Client Context
								(PeerContext: id, zone, cluster)
```

The origin cluster is a consistent hash ring of origin nodes. Each blob digest maps to a deterministic subset of origin nodes (replication set). Uploads go to the highest scoring owner which then performs best‑effort fan‑out replication (chunked transfer) to sibling owners. For remotely sourced blobs (cache miss), one owner pulls from remote storage and optionally triggers local replication.

### Core Components

| Component | Package | Responsibility |
|-----------|---------|----------------|
| `cmd` | `origin/cmd` | Flag parsing, configuration loading, dependency graph construction, process bootstrap (metrics, logging, nginx, hash ring, scheduler debug endpoints). |
| `blobserver.Server` | `origin/blobserver` | HTTP surface area for public & internal APIs; orchestrates uploads, downloads, metadata, replication, lifecycle, write‑back and cleanup. |
| `blobclient` | `origin/blobclient` | Programmatic client for server + cluster abstraction with backoff, polling, conflict handling, ownership resolution. |
| `CAStore` | `lib/store` | Local content‑addressable filesystem cache (upload staging, cache, metadata trees). |
| `backend.Manager` | `lib/backend` | Multi‑backend abstraction (S3/GCS/HDFS/HTTP/Registry); readiness probes; auth; bandwidth watcher for dynamic ring weighting (watcher plugged into hash ring). |
| `metainfogen.Generator` | `lib/metainfogen` | Generates torrent metainfo (piece hashing) lazily or after upload commit. |
| `blobrefresh.Refresher` | `lib/blobrefresh` | De‑duplicated, rate‑limited, asynchronous remote fetcher with hook callbacks (e.g. replication). |
| `persistedretry.Manager` + `writeback.Executor/Store` | `lib/persistedretry/writeback` | Reliable, crash‑tolerant write‑back task queue for async remote storage persistence of uploaded blobs. |
| `hashring.Ring` | `lib/hashring` | Deterministic mapping digest -> ordered list of origin addresses (replicas). Includes health filtering and optional bandwidth watch weighting. |
| `scheduler` | `lib/torrent/scheduler` | P2P piece scheduling (embedded debug reload endpoints). |
| `PeerContext` | `core` | Identity exposed to tracker / agents; couples blob server & p2p client. |
| `nginx` | `nginx` | Fronts blob server listener (TLS, static config templating). |

---

## Process Bootstrap (`main.go` -> `cmd.Run`)

1. Parse flags (network identity, ports, zone/cluster, config, secrets).
2. Load YAML config(s); optionally overlay secrets file.
3. Configure zap logger + global sugar logger.
4. Initialize metrics scope and emit build/version tag.
5. Determine hostname (override or OS hostname) and ensure advertised address belongs to hash ring membership (fallback to local IP if DNS host mapping differs).
6. Discover / derive local peer IP if not provided.
7. Assemble core dependencies (order is important due to injection):
	* `store.NewCAStore` (content cache & upload staging) -> supplies file + metadata accessors.
	* `core.NewPeerContext` (peer identity) used later by replication & tracker compatibility.
	* `backend.NewManager` registers all imported backend client plugins (side‑effect package imports in `main.go` register themselves) and constructs readiness checks.
	* `localdb.New` for persisted task / writeback state.
	* `persistedretry.NewManager` with write‑back store+executor binding CAS + backend manager.
	* `metainfogen.New` constructs piece hashing generator that writes torrent metadata to CAS metadata store.
	* `blobrefresh.New` for asynchronous remote fetch orchestration.
	* `networkevent.NewProducer` (used by scheduler for instrumentation / network tracing).
	* `scheduler.NewOriginScheduler` (p2p scheduler tuned for origin seeding behavior).
	* `hostlist.New` builds dynamic host list for cluster membership (DNS based).
	* Client TLS config build.
	* `healthcheck.NewFilter` providing ring health gating logic.
	* `hashring.New` uses cluster + health + bandwidth watcher to maintain consistent hashing; asynchronous monitor goroutine started.
8. Build `blobserver.Server` injecting all above.
9. Mount scheduler debug endpoint `PATCH /x/config/scheduler` + server routes; start server listen goroutine.
10. Bootstrap nginx with templated port + upstream server socket; attach TLS.

---

## HTTP API Surface

### Public Endpoints

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/health` | Liveness probe | Always 200 OK when process up. |
| GET | `/readiness` | Readiness probe | 503 until all backends report readiness. |
| GET | `/blobs/{digest}/locations` | Discover replica owner addresses | Header `Origin-Locations` CSV. Uses hash ring (deterministic). |
| POST | `/namespace/{ns}/blobs/{digest}/uploads` | Start a chunked upload | Returns `Location` (UID) token. 409 if already exists. |
| PATCH | `/namespace/{ns}/blobs/{digest}/uploads/{uid}` | Stream chunk range | `Content-Range: start-end`, sequential or random access slices supported. 409 if blob already materialized. 404 if upload handle missing. |
| PUT | `/namespace/{ns}/blobs/{digest}/uploads/{uid}` | Commit upload | Asynchronous write‑back + local replication scheduling. 202 conflicts handled by verifying write‑back state. |
| GET | `/namespace/{ns}/blobs/{digest}` | Download blob | 202 if remote fetch pending, 404 if absent, 200 with content else. Content type `application/octet-stream-v1`. |
| POST | `/namespace/{ns}/blobs/{digest}/remote/{remoteDNS}` | Cross cluster replicate | Poll semantics: 202 accepted until local owner materializes blob. |
| POST | `/forcecleanup?ttl_hr=N` | Manual GC of stale / non-owned blobs | Returns JSON enumerating deletions + per-file errors. |

### Internal Endpoints (cluster / operational tooling)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/internal/blobs/{digest}/uploads` | Start internal transfer (replica fan‑out). |
| PATCH | `/internal/blobs/{digest}/uploads/{uid}` | Patch internal transfer chunk. |
| PUT | `/internal/blobs/{digest}/uploads/{uid}` | Commit internal transfer (no write-back). |
| DELETE | `/internal/blobs/{digest}` | Delete cached blob (idempotent). |
| POST | `/internal/blobs/{digest}/metainfo` | Overwrite torrent metainfo (benchmarking). |
| GET | `/internal/peercontext` | Retrieve peer identity metadata. |
| HEAD | `/internal/namespace/{ns}/blobs/{digest}` | Stat (local or remote backend check). Query `?local=true` restricts to cache presence. |
| GET | `/internal/namespace/{ns}/blobs/{digest}/metainfo` | Fetch (or trigger generation) of torrent metainfo (202 on pending remote fetch). |
| PUT | `/internal/duplicate/namespace/{ns}/blobs/{digest}/uploads/{uid}` | Commit duplicate upload with delayed write‑back request (stagger replication). |

### Torrent Debug Endpoint

| Method | Path | Purpose |
|--------|------|---------|
| PATCH | `/x/config/scheduler` | Hot‑reload scheduler config (experimental). |

---

## Chunked Upload Protocol

1. Client issues start (`POST .../uploads`). Response header `Location: <uid>`.
2. Client slices blob stream into fixed or variable sized contiguous byte ranges and sends `PATCH` requests with `Content-Range: start-end` (inclusive exclusive semantics: server writes bytes [start, end) count = end-start).
3. Server writes to upload scratch file keyed by `uid` (seek + copy), rejecting further writes if final blob already exists (conflict) to deduplicate simultaneous upload attempts.
4. Commit (`PUT .../uploads/{uid}`):
	* Moves upload temp file atomically into CAS cache path `<digest>` (fail if not found or digest race / already exist).
	* Persists torrent metainfo (piece hashing) via `metainfoGenerator`.
	* Marks blob `Persist` metadata = true & enqueues asynchronous write‑back task to remote backend (namespace scoped) with optional delay for duplicate replication flows.
	* Initiates duplicate upload tasks to siblings (fan‑out) with staggered write‑back (see `DuplicateWriteBackStagger`) to reduce thundering herd on backend.

Conflict semantics: If another process already uploaded & committed identical digest, server returns 409 early while ensuring write‑back task present (idempotent success from client perspective).

---

## Remote Fetch Lifecycle (Lazy Cache Miss)

Triggered by `downloadBlob`, `getMetaInfo`, or `replicateToRemote` when a blob digest is not in CAS:

1. Handler calls `startRemoteBlobDownload(namespace, digest, replicateLocally)`.
2. `blobRefresher.Refresh` schedules a single worker fetch per digest (coalescing concurrent requests). Return codes:
	* 202 (pending) — worker started or already in progress.
	* 404 — backend reports not found.
	* 503 — refresher saturated (worker pool busy).
3. Optional `localReplicationHook` runs after successful fetch to push blob to sibling replicas (internal transfer) ensuring multi-owner availability quickly.
4. On success: CAS file present, metainfo can be generated lazily on demand (first metainfo request triggers generation if absent).

---

## Replication & Ownership

* Ownership list derived from `hashRing.Locations(digest)` returns ordered list of replica addresses.
* Upload replication strategy: first responder (highest hash score) commits upload, then iterates replicas concurrently via `applyToReplicas` invoking internal transfer (chunked) using `blobclient.TransferBlob`.
* Duplicate write‑back delay: each replica schedules its backend writeback with incremental delay = `DuplicateWriteBackStagger * (i+1)` to smooth backend load; initial owner writes back immediately.
* Local replication on remote fetch ensures a single backend download fans out to other owners for hot readiness.

Failure Cases:
* Individual replica transfer errors aggregated (logged) without failing overall upload commit.
* Write‑back task enqueue failure surfaces as request error (client should retry commit).

---

## Metadata & CAS Layout

`CAStore` surfaces high level operations used here:

| Operation | Usage |
|-----------|-------|
| `CreateUploadFile(uid, sizeHint)` | Begin chunked upload staging. |
| `GetUploadFileReadWriter(uid)` | Random access writes during PATCH. |
| `MoveUploadFileToCache(uid, digest)` | Atomic finalize commit (rename). |
| `GetCacheFileReader(digest)` | Serve / replicate / generate metainfo. |
| `GetCacheFileStat(digest)` | Existence + size; gating replication or stat endpoints. |
| `SetCacheFileMetadata(digest, meta)` | Attach strongly typed metadata records (torrent metainfo, persist flag). |
| `DeleteCacheFile(digest)` | Force removal (GC / manual). |

Metadata records used:
* `metadata.TorrentMeta` — serialized torrent file (piece hashes, piece length, total length).
* `metadata.Persist` — boolean indicating remote write‑back required / performed (used by cleanup & race safety around duplicate commit).

---

## Write‑Back Mechanism

After successful external upload commit or duplicate commit:

1. Persist metadata flag true.
2. Enqueue `writeback.Task(namespace, digestHex, delay)` into persisted retry manager.
3. Executor reads blob from CAS and streams to backend client for namespace.
4. Retriable errors persisted; tasks retried with backoff until success (or manual intervention). Ensures durability even across origin restarts.

When cleanup needs to evict a file, and `Persist` is true, any outstanding tasks are synchronously executed (`SyncExec`) before deletion to avoid data loss.

---

## Cleanup & Eviction

`/forcecleanup?ttl_hr=N` enumerates all cached blobs:

Algorithm per file:
1. Determine expiration by `ModTime` > TTL OR current node no longer owns digest per hash ring.
2. If candidate for removal and `Persist` true, locate any writeback tasks; synchronously execute outstanding tasks; clear persist metadata.
3. Delete cache file + associated metadata.
4. Aggregate JSON response lists `deleted` and `errors`.

Note: This manual endpoint is intentionally human friendly (hours granularity) and not optimized for large dataset churn. Production deployments should pair with automated eviction policies (outside scope here) or rely on TTL + ring churn triggers.

---

## Client Libraries (`blobclient`)

The client layer abstracts individual origin vs cluster semantics.

| Interface | Highlights |
|-----------|-----------|
| `Client` | Direct HTTP wrapper; chunked upload helpers (`TransferBlob`, `UploadBlob`, `DuplicateUploadBlob`), polling sentinel codes (202), stat locality option, forced cleanup, metainfo / replication endpoints. |
| `ClusterClient` | Resolves digest -> ordered clients (ownership) via `ClientResolver` then implements higher level logic: upload conflict fallback, randomized stat, polling loops with exponential backoff for asynchronous remote fetch states. |

Polling Mechanism (`Poll`):
* Iterate ordered origin clients; for each, loop with exponential backoff until request succeeds or terminal error.
* 202 responses drive sleep/backoff; 4xx (non‑retryable) abort early; 5xx accumulate error and proceed to next origin.
* Aggregated errors reported if all owners fail.

Conflict Handling: Upload path treats HTTP 409 as idempotent success higher up (caller interprets absence of actual upload requirement).

Cluster Readiness: Randomly samples one resolved owner using a synthetic `backend.ReadinessCheckDigest` sentinel to probe readiness quickly.

---

## Concurrency & Synchronization

* Upload patch operations rely on file seek + sequential copy; expected to be serialized by client (no server‑side lock besides atomic rename at commit). Parallel patch ranges overlapping may corrupt data; not officially supported.
* Replication to replicas executes in parallel goroutines (fan‑out) with aggregated error capture—does not block client success except for initial commit requirement.
* Remote fetch refresher guarantees only one backend fetch per digest (debounce) — details in `blobrefresh.Refresher` (outside this module) but relied upon here for 202 semantics.
* Write‑back tasks persisted; races between duplicate upload commit windows mitigated by always ensuring `Persist` metadata set before enqueuing tasks.
* Cleanup enumerates & may run write‑backs synchronously; potential large latency if many persisted tasks outstanding—designed for manual invocation.

---

## Error Semantics & HTTP Codes

| Scenario | Code | Notes |
|----------|------|-------|
| Missing blob (stat/download/metainfo) | 202 then 200 or 404 | 202 means remote fetch initiated/pending; 404 means backend not found. |
| Upload start conflict (already cached) | 409 | Client may treat as success; server ensures write‑back state. |
| Upload patch conflict | 409 | Another upload finished; patch aborted. |
| Upload commit file missing | 404 | UID invalid or not started. |
| Duplicate commit invalid JSON | 400 | Input parse error. |
| Force cleanup bad ttl_hr | 400 | Input validation. |
| Backend not ready | 503 | Readiness probe failure. |
| Refresher saturation | 503 | Too many concurrent remote fetches. |

`blobclient` maps `404` on cluster download/stat into `ErrBlobNotFound` for ergonomic error handling across layers.

---

## Metrics & Instrumentation

* Global tally scope tagged with `module=blobserver`.
* Middleware records per‑endpoint latency histogram / status code counters.
* Custom timers / counters:
  * `replicate_blob` / `replicate_blob_errors` — local replication performance.
  * `duplicate_write_back_errors` — replication to replicas (duplicate upload scheduling) failures.
* Version emitter periodically publishes build version tags (for fleet debugging).

Extend by injecting additional middleware or tagging scope during server construction.

---

## Configuration Reference (`origin/cmd/config.go`)

YAML keys (subset – see struct for canonical names):

| Key | Type | Description |
|-----|------|-------------|
| `zap` | `zap.Config` | Structured logging configuration. |
| `cluster` | `hostlist.Config` | DNS / static host discovery for origin members. |
| `hashring` | `hashring.Config` | Hash ring parameters (replica count, refresh interval, weighting). |
| `healthcheck` | `healthcheck.FilterConfig` | Upstream health gating for ring membership. |
| `blobserver` | `blobserver.Config` | Listener (proto, addr) + duplicate writeback stagger. |
| `castore` | `store.CAStoreConfig` | Paths, capacities, eviction policies for local cache. |
| `scheduler` | `scheduler.Config` | P2P scheduler knobs (piece selection, concurrency). |
| `network_event` | `networkevent.Config` | Event emission endpoints / buffers. |
| `peer_id_factory` | `core.PeerIDFactory` | PeerID generation (prefixes, entropy). |
| `metrics` | `metrics.Config` | Backend (statsd, m3) endpoints, sampling. |
| `metainfogen` | `metainfogen.Config` | Piece length defaults, hashing parallelism. |
| `backend_manager` | `backend.ManagerConfig` | Global backend coordination (timeouts, retries). |
| `backends` | `[]backend.Config` | Per namespace backend definitions (type, bucket, root). |
| `auth` | `backend.AuthConfig` | Credentials / tokens / TLS for backends. |
| `blobrefresh` | `blobrefresh.Config` | Worker pool sizes, retry, TTL for refresh state. |
| `localdb` | `localdb.Config` | Storage for persistedretry (SQLite / Bolt etc.). |
| `writeback` | `persistedretry.Config` | Retry strategy, jitter, concurrency for writeback executor. |
| `nginx` | `nginx.Config` | Fronting proxy (ports, TLS termination, templating). |
| `tls` | `httputil.TLSConfig` | Client TLS (mutual TLS to other origins / backends). |

---

## Security Considerations

* Digest addressing (SHA256) provides content integrity — clients are expected to verify digest pre/post upload locally; server trusts path parameter and writes under that digest name (no recomputation inline for performance). For defense in depth operators can enable pre‑validation (extend uploader to hash and verify).
* Internal vs Public endpoints: segregation by path; deployments should restrict `/internal` network ACL to cluster / control plane only.
* TLS: Provided via nginx front; internal client TLS for intra‑cluster replication and remote cluster replication.
* Access control: Not implemented in this module; rely on network segmentation, frontend auth layers, or extend by adding middleware.
* Force cleanup is destructive; safeguard by limiting to administrative networks or require auth wrapper.

---

## Operational Best Practices

* Ensure hash ring member list is stable and all nodes agree; mismatched ring config leads to split brain replication sets and inefficient duplication.
* Monitor duplicate write‑back error counter; persistent non‑zero values indicate replication or backend reachability issues.
* Size `CAStore` capacity to hold working set of hot blobs + pending write‑back queue; saturation can throttle refresher or cause eviction churn.
* Tune `DuplicateWriteBackStagger` to balance backend spike mitigation vs delayed durability.
* Periodically audit `Persist` metadata leaks (files persisted but no tasks) via custom tooling using `/forcecleanup` dry run (extend endpoint for dry run if needed).
* Keep scheduler debug endpoint disabled or protected in production unless actively tuning P2P parameters.

---

## Extension Points

| Area | Strategy |
|------|----------|
| New remote storage backend | Implement `backend.Client` & register in init() via side‑effect import; configure in `backends` list. |
| Alternative replication policy | Wrap `applyToReplicas` or extend with prioritization logic (e.g., network topology aware ordering). |
| AuthZ / AuthN | Insert middleware before handler registration; validate namespace access. |
| Hash algorithm upgrade | Introduce dual‑write mode with new digest type in `core` & update clients; CAS storage keyed by new hex. |
| Observability | Add tally scopes or OpenTelemetry exporters around high latency paths (upload patch, backend fetch, writeback). |

---

## Example Upload (Pseudo Flow)

```
client -> POST /namespace/app/blobs/sha256:<digest>/uploads
< 200 Location: 9d23f...

client -> PATCH /namespace/app/blobs/sha256:<digest>/uploads/9d23f... (Content-Range: 0-4194304)
< 200
...
client -> PATCH ... (Content-Range: 4194304-8388608)
< 200

client -> PUT /namespace/app/blobs/sha256:<digest>/uploads/9d23f...
< 200  (write-back scheduled, replication fan-out started)

peer -> GET /namespace/app/blobs/sha256:<digest>
< 200 application/octet-stream-v1
```

### Example Download Miss

```
client -> GET /namespace/app/blobs/sha256:<digest>
< 202 (remote fetch started)

... (after backend download + local replication) ...

client -> GET /namespace/app/blobs/sha256:<digest>
< 200 (served from CAS)
```

---

## Testing Hooks & Benchmarking

* `OverwriteMetaInfo` endpoint allows forcing a custom piece length for synthetic benchmarking (affects swarm piece distribution efficiency).
* Duplicate upload API simulates stagger impacts and backend load shaping strategies.
* Pprof endpoints (`/debug/pprof`) exposed via mounted default mux for CPU / heap profiling (ensure protected in prod).

---

## Glossary

| Term | Definition |
|------|------------|
| CAS | Content Addressable Store; disk layer mapping digest -> file. |
| Digest | SHA256 hash (hex) identifying blob content. |
| Metainfo | Torrent metadata file (info dict) enabling piece wise P2P distribution. |
| Piece Length | Chunk size for torrent pieces; influences swarm parallelism. |
| Write‑Back | Asynchronous persist of uploaded blob to authoritative remote storage. |
| Replication Set | Ordered list of origin nodes assigned by hash ring for a given digest. |

---

## Future Enhancements (Ideas)

* Adaptive piece length selection based on blob size distribution and historical swarm performance.
* Prioritized replication using topology / latency metrics (rack / AZ awareness) instead of uniform fan‑out.
* Inline digest verification and optional server‑side compression negotiation.
* Pluggable auth middleware with per‑namespace policy controls.
* Opportunistic partial read streaming to start P2P seeding earlier (generate metainfo concurrently with upload patch). 

---

## License

Apache License 2.0 (see root `LICENSE`).

---

## Contributing

Contributions to extend backends, optimize replication, or improve documentation are welcome. Please follow repository `CONTRIBUTING.md` guidelines and include appropriate tests / benchmarks where meaningful.

---

## Summary

The origin service provides a robust, extensible, content‑addressed ingress and authoritative caching layer which bridges remote object storage and Kraken's peer‑to‑peer distribution plane. Its design emphasizes idempotent operations, asynchronous durability, deterministic sharding, and operational transparency, forming the backbone for efficient large scale artifact distribution.

