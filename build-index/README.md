# Kraken Build-Index Service

The `build-index` service provides durable, eventually replicated mapping from human-readable image tags (e.g. `repo/app:version`) to content-addressable digests (root manifest blob digests) and orchestrates asynchronous cross-cluster tag replication. It complements the `origin` service which stores blob data; `build-index` stores lightweight tag -> digest bindings and ensures referenced blob dependencies are present before accepting a tag write.

This document offers a deep technical reference for the module: architecture, request lifecycle, data model, replication pipeline, on-disk layout, concurrency patterns, configuration, metrics, failure semantics, and extension points.

---

## Role in Overall System

In Kraken, blobs (layers, configs, manifests) are addressed by SHA256 digests and distributed via P2P + origin. Users, CI pipelines, and tooling interact through image tags; `build-index` bridges this semantic layer by storing the association of tag -> manifest digest. It also propagates new tags to remote clusters (multi-region / DR / edge) based on matching rules.

Unlike a traditional monolithic Docker registry, Kraken intentionally decouples large binary storage (origin/backends) from lightweight metadata (build-index) to:
* Scale tag mutation/lookup independently.
* Reduce write amplification: tag writes are small, idempotent, and asynchronous from blob durability.
* Support rule-driven multi-cluster replication without replaying entire blob histories.

---

## High-Level Architecture

```
								 +------------------------------+          +-----------------------------+
	 Client / CI ->|  build-index Tag Server      |--tasks--> |  Persisted Retry Managers   |
								 |  (HTTP API)                  |           |  (tag replication, writeback)|
								 +---------+--------------------+           +--------------+--------------+
													 |                                        |
													 v                                        v
										+-------------+                           +-------------+
										| Tag Store   |--(persist:true metadata)-> | SimpleStore |
										| (CAS-like)  |                           | (disk files)|
										+------+------+                           +------+------+ 
													 |                                       ^
				 +-----------------+----------------+                      |
				 |  Backend Manager (multi backend) |<--writeback----------+
				 +-----------------+----------------+
													 |
											 Remote Backends (S3 / GCS / HDFS / Registry / SQL / Shadow / HTTP)

									(dependencies)
													 ^
													 | Resolve & Stat
								 +---------+----------+
								 |  Origin Cluster    |
								 +--------------------+

```

Key flows:
* Tag PUT: Validate referenced manifest + dependencies exist in origin cluster; write tag locally; enqueue write-back task to backend; optionally replicate across peers + remote clusters.
* Tag GET: Resolve from local file cache first; fallback to remote backend fetch.
* Replication: Background workers consume persisted tasks to replicate tags (and ensure dependent blobs at destination cluster) with delay staggering to smooth load.

---

## Core Components

| Component | Package | Responsibility |
|-----------|---------|----------------|
| `cmd` | `build-index/cmd` | Flag parsing, config loading, dependency wiring (stores, managers, server, nginx). |
| `tagserver.Server` | `build-index/tagserver` | HTTP API routes, validation, duplicate task fan-out, remote replication scheduling, readiness. |
| `tagstore.Store` | `build-index/tagstore` | Two-level storage (local disk + remote backend) with write-back, persist metadata. |
| `tagtype.Map` | `build-index/tagtype` | Namespace pattern -> dependency resolver (docker vs default). |
| `tagreplication` | `lib/persistedretry/tagreplication` | Persisted replication tasks (tag + digest + dependency list + destination + delay). |
| `writeback` | `lib/persistedretry/writeback` | Generic persisted retry framework; here used for uploading tags to backend durable store. |
| `backend.Manager` | `lib/backend` | Chooses backend per tag namespace; readiness; auth; specialized client capabilities. |
| `blobclient.ClusterClient` | `origin/blobclient` | Ensures dependent blobs exist in origin cluster during PUT. |
| `SimpleStore` | `lib/store` (`NewSimpleStore`) | Minimal file store for tag cache (filename = tag, content = digest string). |
| `hostlist` | `lib/hostlist` | Peer discovery for duplicate task fan-out (neighbors). |

---

## Data Model

| Artifact | Representation | Storage | Notes |
|----------|---------------|---------|-------|
| Tag | UTF-8 string (e.g. `repo/app:build123`) | Local file name, backend object key | Atomic mapping to single digest (no multi-value history). |
| Digest | `sha256:<hex>` canonical string | Stored as file content | Parsed / validated on load. |
| Dependencies | `[]Digest` | Included in replication task; not stored with tag | Derived via resolver at PUT time. |
| Persist Flag | `metadata.Persist(true)` | File metadata entry | Signals write-back / replication required before eviction (clean up path). |

No versioning: last writer wins (intentionally eventual for caching / replication simplicity). Clients relying on strong tag consistency should use unique, immutable tags.

---

## Request Lifecycle: PUT Tag

Sequence (simplified):
1. `PUT /tags/{tag}/digest/{digest}?replicate=true|false`
2. Server parses tag + digest; optional `replicate` query.
3. Resolve dependencies via `depResolver.Resolve(tag, digest)`:
	 * `docker` resolver: Inspects manifest at provided digest (via origin) to collect layer/config digests.
	 * `default` resolver: Returns digest only.
4. For each dependency digest: `originCluster.Stat(namespace=tag, dep)` — ensures blob content exists locally (prevents dangling tag referencing missing data).
5. Write tag to local disk (idempotent, allows overwrite). Add `Persist(true)` metadata.
6. Enqueue write-back task (or synchronous if `WriteThrough` enabled).
7. If `replicate=true`:
	 * Enqueue remote cluster replication tasks (one per matched remote rule).
	 * Duplicate replication tasks to neighbor peers with incremental delay (`DuplicateReplicateStagger`).
8. Duplicate tag put tasks to neighbor peers with incremental delay (`DuplicatePutStagger`) for resilience (each peer persists copy & executes write-back) — reduces single-node loss impact.
9. Return 200.

Error semantics:
* Missing dependency -> 4xx (wrapped error; client must upload missing blob first).
* Backend manager / store errors -> 5xx.

---

## Request Lifecycle: GET Tag

1. `GET /tags/{tag}`
2. Attempt read from local file store; if present return digest.
3. Fallback: select backend using `backend.Manager.GetClient(tag)`; download object content; validate digest format; return; (optionally rehydrate local cache — current code only reads).
4. 404 if neither local nor backend have tag.

HEAD `/tags/{tag}`: Checks existence only in remote backend (stat) — distinguishes authoritative persistence vs local ephemeral state.

List operations:
* `GET /list/<prefix>` — paginated listing across backend namespace.
* `GET /repositories/{repo}/tags` — legacy route projecting tags from internal layout.

---

## Replication Pipeline

Two replication vectors:

| Vector | Purpose | Mechanism |
|--------|---------|-----------|
| Remote Cluster Replication | Multi-region / DR distribution of tag mapping + ensuring referenced blobs exist at destination origins. | `tagreplication.Task(tag, digest, dependencies, destination, delay)` persisted; executor triggers origin cluster transfer for missing blobs then writes tag at remote build-index. |
| Neighbor Duplicate Tasks | Local high availability & load smoothing for remote replication / write-back. | Fan-out tasks with incremental delay to randomly ordered neighbors. Failure counters track if all duplicates failed. |

Delayed start (stagger) reduces concurrency spikes where many new tags would simultaneously trigger large remote blob transfers.

Dependency enforcement at destination: The remote tag replication executor (not shown here) uses dependencies list to ensure each referenced blob manifest/layer is present (fetch from origin remote cluster if absent) before committing tag.

---

## Write-Back (Durable Storage)

After local disk tag write, a write-back task is scheduled unless `WriteThrough` forces synchronous commit:
1. Task executed: open local file (digest string) and stream to selected backend location (namespace mapping rules apply — often tag path itself).
2. On success: metadata persist flag may remain set until cleanup; future cleanup ensures tasks have executed before deletion.
3. Failures: persisted retry framework stores attempt state (in `localdb`), re-enqueues with backoff.

This provides crash tolerance: restarts reload tasks from `localdb` and continue.

---

## Configuration Keys (Subset)

Refer to `cmd.Config` struct.

| YAML | Field | Description |
|------|-------|-------------|
| `tagserver` | `tagserver.Config` | Listener, duplicate stagger values. |
| `tag_store` | `tagstore.Config` | Write-through toggle, etc. |
| `store` | `store.SimpleStoreConfig` | Root directory, capacities (if any). |
| `backend_manager` | `backend.ManagerConfig` | Timeouts, retries, metrics. |
| `backends` | `[]backend.Config` | Namespace -> backend mapping. |
| `auth` | `backend.AuthConfig` | Credential sources / auth strategies. |
| `tag_replication` | `persistedretry.Config` | Retry policy for tag replication tasks. |
| `writeback` | `persistedretry.Config` | Retry policy for tag write-back tasks. |
| `tag_types` | `[]tagtype.Config` | Regex namespace pattern + resolver type (`docker` or `default`). |
| `origin` | `upstream.ActiveConfig` | Origin cluster DNS/static host spec + health check. |
| `cluster` | `upstream.ActiveConfig` | Build-index peer cluster for duplication. |
| `remotes` | `tagreplication.RemotesConfig` | Remote cluster matching rules for replication. |
| `tls` | `httputil.TLSConfig` | Client TLS for contacting origins / peers / backends. |
| `nginx` | `nginx.Config` | Fronting proxy config. |

---

## HTTP API Summary

| Method | Path | Description | Notes |
|--------|------|-------------|-------|
| PUT | `/tags/{tag}/digest/{digest}` | Create/overwrite tag binding | Query `replicate=true` triggers remote replication scheduling. |
| HEAD | `/tags/{tag}` | Check tag exists in backend | Uses backend stat; local cache not authoritative. |
| GET | `/tags/{tag}` | Fetch digest string | 404 if missing. |
| GET | `/list/<prefix>` | List tags with prefix | Pagination via `limit`, `offset` (continuation token). |
| GET | `/repositories/{repo}/tags` | Legacy repo tag list | Derives tags from internal storage layout. |
| POST | `/remotes/tags/{tag}` | Trigger replication of existing tag | Resolves dependencies again to produce fresh tasks. |
| GET | `/origin` | Return local origin cluster stable DNS | Useful for diagnostics. |
| POST | `/internal/duplicate/remotes/tags/{tag}/digest/{digest}` | Duplicate remote replication task | JSON body includes `dependencies`, `delay`. |
| PUT | `/internal/duplicate/tags/{tag}/digest/{digest}` | Duplicate tag put task | Body supplies staging delay. |
| GET | `/health` | Liveness | 200 if process up. |
| GET | `/readiness` | Readiness | 503 until backend + origin cluster ready. |

---

## Dependency Resolution

Implemented strategies:
* `docker`: Query origin for manifest (by digest) and extract all associated layer/config digests forming dependency list. Tag PUT will reject if any dependency blob missing from origin cluster.
* `default`: No extra dependencies; only manifest digest.

Pattern matching: `tagtype.Map` iterates configured regex patterns in declaration order; first match selects resolver. Unmatched tag -> error (namespace not configured) and request fails.

---

## Duplicate Task Staggering

Two independent staggers mitigate correlated bursts:
| Stagger | Config Field | Applies To | Effect |
|---------|--------------|------------|--------|
| `DuplicatePutStagger` | `tagserver.Config` | Duplicate tag put tasks | Adds cumulative delay per neighbor; spreads write-back starts. |
| `DuplicateReplicateStagger` | `tagserver.Config` | Duplicate remote replication tasks | Staggers remote cluster tag + blob fetch bursts. |

Delay accumulation pattern:
```
delay = 0
for each neighbor in random order:
	delay += Stagger
	send Duplicate*(delay)
```

---

## Concurrency & Failure Modes

* Tag overwrites are allowed; last writer wins; duplicate tasks may race — final digest string is consistent due to atomic file replace and idempotent write-back (overwrites remote object with same content length usually negligible cost).
* Replication tasks are independent per destination; failure at one remote does not block local commit.
* Persisted retry ensures tasks survive process crashes; local disk file plus metadata must remain until success.
* If all neighbor duplicate fan-out operations fail, counters `duplicate_put_failures` or `duplicate_replicate_failures` increment (use for alerting).
* HEAD vs GET semantics avoid false positives from transient local state; HEAD ensures durable backend presence.

---

## Metrics (Indicative)

Middleware:
* Status code counters per route.
* Latency histograms per route.

Custom counters:
* `duplicate_put_failures`
* `duplicate_replicate_failures`

Additional metrics emitted by persistence and backend subsystems (retry counts, execution latency) via their own scopes.

---

## Security & Operational Notes

* Tag namespace hygiene: Encourage immutable tags; mutable tags (e.g. `latest`) risk race conditions across clusters; Kraken treats them as simple overwrites.
* Access control not enforced here; integrate reverse proxy / service mesh or extend with auth middleware.
* TLS termination via nginx; internal TLS for intra-cluster / origin calls via configured `httputil.TLSConfig`.
* Replication rule misconfiguration can cause tag storms; carefully scope `remotes` regex/prefix patterns.
* Monitor backlog size of persisted retry queues to detect downstream slowness.

---

## Extension Points

| Area | Approach |
|------|---------|
| New dependency resolver | Implement `DependencyResolver` and add new `Type` case in `tagtype.NewMap`. |
| Alternative replication policy | Wrap task creation with custom scheduling (priority, rate limiting). |
| Tag version history | Extend store layout to embed timestamp/version entries; adapt GET semantics. |
| Access control | Insert middleware before handler registration (e.g. verifying namespace claims). |
| Observability | Add more detailed counters (dependency size distribution, replication lag). |

---

## Example Tag PUT (with Replication)

```
PUT /tags/repo/app:build42/digest/sha256:abc...def?replicate=true
	-> resolve deps (docker resolver)
	-> stat each dep via origin cluster
	-> write local file 'repo/app:build42' containing digest string
	-> persist metadata (Persist=true)
	-> enqueue write-back to backend
	-> enqueue remote replication tasks (destinations matched)
	-> fan-out duplicate put + duplicate replicate tasks with stagger
200 OK
```

Client then:
```
GET /tags/repo/app:build42 -> sha256:abc...def
```

---

## Future Enhancements (Ideas)

* Tag lease / optimistic concurrency (If-Match header) for safe mutability.
* Batch tag PUT API (transactional group commit) for large manifest lists.
* Built-in tag garbage collection referencing DAG of manifests / layers (currently delegated to origin retention policies).
* Replication lag metrics (time from local PUT to remote success). 
* Optional digest canonicalization verifying digest matches retrieved manifest blob content before accept (strong integrity). 

---

## License

Apache License 2.0 (see repository root `LICENSE`).

---

## Contributing

Please follow root `CONTRIBUTING.md`. Include tests for new resolvers, replication rules, and store behaviors. Benchmark long tag lists & replicate queue saturation if altering pagination or retry schemes.

---

## Summary

`build-index` is a lightweight, durable, and extensible tag resolution and replication layer decoupled from blob storage. It enforces dependency presence, provides crash-tolerant asynchronous durability, and offers controlled multi-cluster propagation—forming the metadata backbone of Kraken's content distribution platform.

