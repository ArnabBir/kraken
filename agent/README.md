## Agent Module

Kraken Agent is the node-side process running on every host (or Kubernetes node) which:
1. Participates in the P2P swarm for efficient blob/image layer distribution.
2. Exposes a local registry-compatible endpoint (fronted by nginx) to transparently serve container runtimes (Docker / containerd) image pulls from local cache or P2P.
3. Resolves tags to content digests via the build-index service and fetches torrent metadata / peer lists from trackers.
4. Orchestrates piece download and local content-addressable storage using the torrent scheduler and CADownloadStore.
5. Provides operational HTTP endpoints for health, readiness, preloading images, blacklisting peers, and dynamic scheduler config reload.

This document gives a deep technical dive into the agent code in this directory and its integration with the broader Kraken system (see `origin/README.md`, `tracker/README.md`, `build-index/README.md`, `proxy/README.md`, `lib/README.md`, `core/README.md`).

---
### 1. High-Level Architecture

```
		    +---------------- Registry Upstreams (origin/proxy) ----------------+
		    |                                                                  |
		    v                                                                  |
   +----------------------+        +--------------------+       +------------------+ 
   |  build-index (tags)  |        |    trackers        |       |     origin(s)     |
   +----------+-----------+        +---------+----------+       +---------+--------+ 
		  | Tag->Digest                 | Peer/announce               | HTTP CAS
		  v                             v                            v
	  (HTTPS client)                (Announce client)              (Fallback fetch)
		  +---------------------------------------------------------------+
		  |                                                               |
	  +-----v----------------+        +------------------+        +---------v---------+
	  |   Agent Server HTTP  |        | Torrent Scheduler|        |  CADownloadStore  |
	  |  (/tags, /blobs, ...) |<----->| (piece mgmt, P2P) |<------>|  CAS disk cache   |
	  +-----+----------------+        +---------+--------+        +---------+---------+
		  | Preload / local registry         |                         ^
		  v                                  |                        (reads)
	  +-----+----------------------+           |
	  | Local nginx + Registry API |<----------+ (Layer fetch via transferer)
	  |  :AgentRegistryPort        |                    (exposes Docker HTTP)
	  +----------------------------+
```

Core flows:
* Tag resolution: `/tags/{tag}` → build-index cluster (passive hash ring) → returns digest.
* Blob download: `/namespace/{ns}/blobs/{digest}` → local store hit? else schedule torrent download (announce to trackers, fetch piece lists, download pieces from peers, fallback to origin if needed) → stream to caller.
* Container runtime pull: local runtime points to agent's nginx which proxies to internal registry component which uses a `Transferer` that leverages local store + scheduler.
* Preload: `/preload/tags/{repo:tag}` triggers proactive pull into local runtime (docker or containerd) to reduce cold-start latency.

---
### 2. Components

| Component | File(s) | Responsibility |
|-----------|---------|----------------|
| Entry point | `main.go` | Parse flags, delegate to `cmd.Run` |
| CLI / Boot | `cmd/cmd.go`, `cmd/config.go` | Flag parsing, config loading (including secrets overlay), constructing dependencies, starting HTTP server, registry, nginx, heartbeat metric |
| Server | `agentserver/server.go` | HTTP routing (chi), handlers (download, tag, preload, delete, readiness, blacklist, config patch), metrics middleware |
| Client | `agentclient/client.go` | Programmatic HTTP client for other internal components/tests (tag resolve, download) |
| Scheduler | external (`lib/torrent/scheduler`) | Peer selection, piece download orchestration, blacklist maintenance, dynamic config reload |
| Store | `lib/store` (CADownloadStore) | CAS file-based content storage & in-progress download coordination |
| Upstreams | `build-index/tagclient`, `tracker/announceclient`, `upstream` | Remote service discovery/requests (tag, peer lists) |
| Container Runtime | `lib/containerruntime` | Interface to docker daemon / containerd for preload operations |
| Registry | `lib/dockerregistry` + nginx | Presents transparent Docker registry API bound to local cached content |
| Metrics | `metrics` + tally middleware | Request status counters, latency timers, heartbeat counter |
| Security / TLS | `httputil.TLSConfig` | mTLS / TLS client config for upstream calls |

---
### 3. HTTP API Surface (Agent Server)

| Method | Path | Description | Success Code | Error Codes |
|--------|------|-------------|--------------|-------------|
| GET | `/health` | Liveness: probes torrent scheduler (`Probe()`) | 200 | 500 on probe failure |
| GET | `/readiness` | Concurrent readiness of scheduler, build-index, tracker (cached TTL) | 200 | 503 aggregated failures |
| GET | `/tags/{tag}` | Resolve tag → digest via build-index | 200 (digest string body) | 404 tag missing; 500 upstream error |
| GET | `/namespace/{ns}/blobs/{digest}` | Stream blob (download if absent) | 200 (raw bytes) | 404 torrent not found; 500 on scheduler/store errors |
| DELETE | `/blobs/{digest}` | Remove local torrent (scheduler removal) | 200 | 500 on failure |
| GET | `/preload/tags/{repo:tag}` | Ask local runtime to pull image (docker or containerd) | 200 | 500 unsupported runtime or pull failure |
| PATCH | `/x/config/scheduler` | Hot-reload scheduler config (json body of `scheduler.Config`) | 200 | 400 JSON decode; 500 internal |
| GET | `/x/blacklist` | Snapshot of currently blacklisted peer connections | 200 (JSON array) | 500 on snapshot failure |
| (pprof) | `/debug/pprof/...` | Performance diagnostics | 200 | - |

Notes:
* `parseDigest` accepts either raw 64-char hex or `sha256:<hex>` (TODO notes future stricter parsing).
* Readiness aggregates 3 probe errors; returns multiline message with each cause.
* Middleware attaches status/latency metrics (module tag `agentserver`).

---
### 4. Download Lifecycle (Detailed)

1. Client invokes `GET /namespace/{ns}/blobs/{digest}`.
2. Server attempts `CADownloadStore.Cache().GetFileReader(d.Hex())`.
3. Cache miss or download error sentinel:
   * Calls `scheduler.Download(namespace, digest)`.
   * Scheduler announces to tracker (announceclient) with `PeerContext` (includes PeerID, zone, cluster).
   * Retrieves `MetaInfo` (from tracker/origin pipeline) containing piece checksums and InfoHash.
   * Builds priority peer list; may fallback to origin(s) using configured strategy if swarm insufficient.
   * Streams pieces to temporary location; verifies per-piece CRC32; stores completed blob in CAS path keyed by digest hex.
4. Server re-opens file and streams to HTTP response.
5. Consumption drives backpressure naturally; scheduler adjusts concurrency if dynamic config changed (see PATCH endpoint).

Error Path:
* If scheduler returns `ErrTorrentNotFound`, respond 404 — indicates upstream tag or torrent metadata missing.
* Other errors bubble as 500; store errors wrapped with context.

---
### 5. Readiness Caching Logic

Config field: `AgentServer.readiness_cache_ttl` (unexported struct field name is lower-case but loaded via YAML tag). Semantics:
* If TTL > 0 and last success within TTL → short circuit with 200 without invoking probes.
* On failure responses TTL is not updated; subsequent requests perform full probe until a success.
* Probes run concurrently (three goroutines) joined via `sync.WaitGroup` to minimize latency.

---
### 6. Tag Resolution Flow

Client (internal or external tool):
```
GET /tags/<tag>
  -> agentserver.getTagHandler
    -> tagclient.Client.Get(tag)
	 -> build-index cluster (hash ring) returns digest
<digest-string>
```
The agent does not cache tag->digest mapping locally beyond HTTP response; caching strategy resides in build-index layer.

---
### 7. Preload Flow (Image Warmup)

Endpoint: `/preload/tags/{repo:tag}?runtime=<docker|containerd>&namespace=<ns-for-containerd>`
1. Parse `{repo}:{tag}` split by colon; error if not exactly two parts.
2. Select runtime (default `docker`).
3. Invoke appropriate runtime client pull:
   * Docker: `DockerClient().PullImage(repo, tag)`
   * Containerd: `ContainerdClient().PullImage(namespace, repo, tag)`
4. Runtime-level configuration ensures the agent's local registry is consulted, causing underlying layer downloads to route via the agent's cache + P2P.

---
### 8. Dynamic Scheduler Reload

* PATCH `/x/config/scheduler` with JSON body matching `scheduler.Config`.
* Decodes into struct; invokes `ReloadableScheduler.Reload(config)` with no restart.
* Enables live tuning: connection limits, piece parallelism, peer blacklist thresholds, etc.
* Safe because scheduler interface abstracts internal goroutines; reload applies new policy atomically.

---
### 9. Blacklist Introspection

* Scheduler maintains blacklist (e.g., peers misbehaving: slow, corrupt, failed pieces).
* `GET /x/blacklist` returns JSON array with `PeerID`, `InfoHash`, remaining duration until unblacklisted.
* Supports debugging swarm quality issues and verifying adaptive throttling.

---
### 10. Configuration Reference (Selected)

YAML keys (see `cmd/config.go`):
| Key | Type | Purpose |
|-----|------|---------|
| `zap` | zap.Config | Structured logging setup |
| `metrics` | metrics.Config | Tally reporter (M3 / StatsD) |
| `store` | CADownloadStoreConfig | Local CAS path, eviction, concurrency limits |
| `registry` | dockerregistry.Config | Embedded registry behavior/read-only flags |
| `scheduler` | scheduler.Config | P2P piece policies, timeouts, blacklist rules |
| `peer_id_factory` | string (`random`/`addr_hash`) | PeerID determinism strategy |
| `network_event` | networkevent.Config | Emission of network events (Kafka/etc) |
| `tracker` | PassiveHashRingConfig | Tracker upstream endpoints + ring refresh |
| `build_index` | PassiveConfig | Tag resolution upstream list |
| `agentserver` | agentserver.Config | Readiness cache TTL |
| `registry_backup` | string | Backup upstream registry fallback URL |
| `nginx` | nginx.Config | Front proxy for registry & agent server, access control |
| `tls` | httputil.TLSConfig | Client TLS parameters (certs, CA, skip verify) |
| `allowed_cidrs` | []string | Network ACL for nginx templating |
| `container_runtime` | containerruntime.Config | docker/containerd integration |
| `docker_daemon` | dockerdaemon.Config (deprecated) | Backwards compat mapping |

CLI flags specify network binding & cluster identity overriding config file where applicable.

---
### 11. Metrics

Agent emits:
* HTTP status counters by code (middleware.StatusCounter) with `module=agentserver`.
* HTTP latency histograms (middleware.LatencyTimer).
* `heartbeat` counter every 10s → active agent population gauge via rate.
* Scheduler / store metrics (not shown in this module; see `lib/torrent/scheduler` docs) like piece download latency, peer errors, blacklist counts.
* Registry / transfer metrics (upstream fetch latency, cache hit ratio) via transferer & store.

Operational guidance:
* Alert on sustained readiness failures > N seconds.
* Track 404 blob downloads to detect tag drift / build-index lag.
* Monitor blacklist growth for network degradation.

---
### 12. Error Handling Strategy

* Use `handler.Errorf` to wrap internal errors; some handlers map known sentinel errors to HTTP codes (e.g., 404, 503).
* Upstream errors are surfaced with context prefix ("get tag:", "download torrent:").
* `parseDigest` attempts hex-only then algo-prefixed parse; TODO indicates forthcoming stricter validation.
* Readiness aggregates and returns multi-line error message; caller tooling should treat non-200 as unhealthy irrespective of message content.

---
### 13. Concurrency Model

Server side:
* One goroutine per inbound HTTP request (standard Go net/http model).
* Readiness probes spawn 3 goroutines for parallel upstream checks.
* Scheduler internally manages goroutines per torrent (piece fetchers); safe via exposed interfaces (`Download`, `Probe`, `BlacklistSnapshot`, `Reload`).
* Heartbeat goroutine increments metric indefinitely.
* Registry + nginx each run in their own goroutines launched from `Run`.

Synchronization points:
* Readiness uses `sync.WaitGroup` and local error variables (race-safe because all assignments happen before `Wait()` completes then read after join; not concurrently mutated).
* `lastReady` mutated after successful readiness; no locking—data race acceptable? In production build race detector off; atomic not used because single-writer pattern (only readiness handler) and minimal impact if stale. Could be improved with atomic.Value for strict correctness.

---
### 14. Caching Layers

1. CAS Store (`CADownloadStore`): On-disk content keyed by digest hex; reused by registry & agent server downloads.
2. Readiness success cache (time-based TTL) avoids repetitive expensive upstream checks.
3. Implicit peer/regression caches inside scheduler (piece availability, peer performance) not detailed here.

No explicit in-memory tag cache (delegated to build-index for consistency & propagation semantics).

---
### 15. Security Considerations

* TLS: All upstream clients (trackers, build-index, registry fallback) constructed with provided TLS config — enforce cert validation unless explicitly disabled.
* Digest validation: Flexible parse currently accepts raw hex or algo:hex; future tightening should reduce ambiguity for SSRF/path traversal protections.
* Preload endpoint: Allows arbitrary image pulls; restrict via network ACL or internal auth if exposed beyond trusted operators.
* Blacklist data exposure: Contains PeerIDs and InfoHashes; not highly sensitive but could leak swarm topology; restrict external access if needed.
* Hot config patch: Powerful; consider RBAC / auth layer (currently none). Only enabled under `/x/` experimental namespace.
* Nginx fronting ensures container runtime only talks locally; external exposure should be controlled by cloud/network rules.

---
### 16. Failure Scenarios & Mitigations

| Scenario | Symptom | Mitigation |
|----------|---------|-----------|
| Tracker unreachable | Readiness fails; scheduler download stalls until fallback | Ensure multi-endpoint ring and health monitoring |
| Build-index lag | Tag resolves to missing torrent | Retry; reconcile build pipeline; watch 404 metrics |
| Origin slow | Prolonged initial download | Tune piece size / concurrency; ensure origin replication | 
| Peer churn | Increased blacklist, slower swarm | Adjust scheduler thresholds via PATCH reload |
| Disk full | Store write errors | Eviction policy in store; external disk monitoring |
| TLS misconfig | Upstream connection failures | Validate certs at startup; fail fast |
| Scheduler config regression | Sudden performance drop | Rollback via previously known good config using PATCH |

---
### 17. Extension Points

| Area | Approach |
|------|----------|
| Authentication | Add middleware before handlers; sign requests or mTLS client cert mapping |
| Additional runtimes | Extend `containerruntime.Factory` to support CRI-O; map query param to implementation |
| Enhanced readiness | Add deeper CAS disk checks, free space thresholds |
| Digest strictness | Remove fallback parsing; enforce `sha256:<hex>` only |
| Scheduler strategies | Expose new fields in `scheduler.Config` (peer scoring weights, adaptive piece sizing) |
| Rate limiting | Add middleware: token bucket per endpoint / per IP |

---
### 18. Testing Strategy

`agentserver/server_test.go` covers:
* Tag resolution success & not found mapping to sentinel error.
* Download flow: store miss triggers mocked scheduler which writes blob; verifies content equality.
* Error propagation for not found vs unknown scheduler errors.
* Health handler probe pass/fail.
* Readiness handler matrix: scheduler/build-index/tracker permutations, cached TTL behavior including forced invalidation.
* PATCH scheduler config: JSON decode + Reload invocation.
* Blacklist handler: JSON shape.
* Preload handler: docker, containerd, unsupported runtime path.
* DELETE blob handler: scheduler.RemoveTorrent invoked.

Recommended additions:
* Race detector runs in CI to assert `lastReady` access safety.
* Benchmark download path with large blobs to evaluate memory overhead.
* Integration test: real scheduler with ephemeral tracker + origin container.

---
### 19. Operational Playbook

Startup sequence (simplified):
1. Load config (+ secrets overlay) → create logger / metrics scope.
2. Derive `PeerContext` (PeerIDFactory may hash IP:port for deterministic identity).
3. Initialize store, network event producer, tracker upstream ring, TLS, announce client.
4. Create scheduler with dependencies (store, network events, trackers, announce client, TLS).
5. Build build-index upstream cluster and tag client.
6. Create transferer + registry (read-only mode pointing at local CAS).
7. Start agent HTTP server, registry, nginx, heartbeat.
8. Agent ready to handle container runtime layer pulls & explicit API calls.

Observability triage:
* Check `/health` (should isolate scheduler health only).
* Check `/readiness` (aggregates external dependencies) – if failing parse multiline error to identify failing subsystem.
* Inspect `/x/blacklist` for unusual peer suppression patterns.
* Use pprof endpoints for CPU / memory anomalies.

Deployment notes:
* Run one agent per node for maximal locality.
* Ensure host's container runtime is pointed to agent's nginx listener (e.g., configure Docker daemon `--registry-mirror`).
* Provide consistent `cluster` and `zone` flags across deployment for accurate tracker peer locality policies.

---
### 20. Cross-Module Interactions

| External Module | Dependency Usage |
|-----------------|------------------|
| `core` | Digest parsing, PeerContext creation |
| `build-index` | Tag -> digest resolution via passive hash ring client |
| `tracker` | Announce / peer discovery (InfoHash based swarms) |
| `origin` | Fallback source for blobs (through scheduler upstream chain) |
| `proxy` | (Indirect) Preheating alignment strategies |
| `lib` | Store, scheduler, middleware, container runtime abstractions |

---
### 21. Future Enhancements

| Idea | Benefit |
|------|---------|
| Structured readiness JSON | Machine-friendly status dashboards |
| AuthN/Z on sensitive endpoints (`/x/*`) | Prevent accidental misuse |
| Pluggable piece verification (cryptographic) | Stronger per-piece integrity before final digest check |
| Adaptive peer scoring with historical RTT/throughput | Faster swarm convergence |
| gRPC control plane | Richer streaming diagnostics & config watch |
| Layer dedupe metrics surfaced | Visibility into cache efficiency |

---
### 22. Summary

The Agent is Kraken's on-host execution engine: bridging registry semantics, P2P distribution, and local runtime integration. Its design emphasizes streaming efficiency, minimal surface area for operations, and pluggability for evolving scheduler strategies while maintaining strict content integrity via core digest and torrent metadata invariants.

