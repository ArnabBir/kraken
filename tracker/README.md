# Kraken Tracker Service

The `tracker` service is the realtime coordination plane of Kraken's P2P distribution network. It ingests periodic announces from agents and origins, hands out optimized peer sets to downloading peers, surfaces torrent metainfo (delegated from origin cluster), and tolerates partial component unavailability via layered caching and prioritization policies.

This document provides a deep, low-level technical overview: architecture, announce lifecycle, peer selection algorithms, data structures, concurrency, caching, configuration surface, metrics, failure modes, and extension points.

---

## Responsibilities

* Maintain transient state: which peers (agents / origins) participate in which torrents (identified by `InfoHash`).
* Provide peers with a bounded, prioritized peer list for a torrent (handout) to construct a sparse, high-expansion graph.
* Include origin seeders opportunistically while preventing over-reliance on them.
* Expose torrent metainfo retrieval endpoint (proxying origin cluster) for late-binding piece scheduling.
* Remain stateless/durable-light: peer membership is implicitly refreshed by periodic announces; expired entries age out automatically (TTL strategy delegated to store implementations).

---

## High-Level Architecture

```
                   +-------------------+
   Agents / Origins|  Announce (HTTP)  |  GET /announce (v1 JSON) or POST /announce/{infohash} (v2)
         --------->|   Tracker Server  |----------------------------------+
                   +---------+---------+                                  |
                             |                                           |
                             v                                           v
                    +----------------+                         +------------------+
                    | Peer Store     |<--(Redis / Local)------>| Persistence Layer|
                    | (in-memory TTL)|                         | (optional Redis) |
                    +----------------+                         +------------------+
                             |
                             v
                    +----------------+         +-------------------+
                    | Handout Policy |<--------| Origin Store      |
                    | (priority sort)|         | (locations & pctx)|
                    +----------------+         +-------------------+
                             |                          ^
                             v                          |
                       Peer Handout (ordered list)      |
                                                        |
                                        +-------------------------------+
                                        | Origin Cluster (external API) |
                                        +-------------------------------+

```

Key internal modules:
* `peerstore`: Abstraction over peer presence keyed by `InfoHash`. Implementations:
  * Local in-memory store (default) with TTL windows.
  * Redis-backed store (optional) for horizontal scalability / multi-instance trackers.
* `originstore`: Caches origin ownership + peer contexts per digest using multi-level TTL with success/error differentiation and deduplicated requests.
* `peerhandoutpolicy`: Pluggable prioritization strategy for ordering candidate peers (default vs completeness policy). Returns sorted peers excluding the announcing peer.
* `trackerserver`: HTTP surface orchestrating announce flows, readiness gating, and metainfo proxying.
* `blobclient.ClusterClient`: For readiness and metainfo retrieval via origin cluster (consistent hashing, polling semantics).

---

## Data Model & Key Types

| Type | Source | Description |
|------|--------|-------------|
| `core.InfoHash` | P2P layer | 20 byte (SHA1 style) identifier for torrent (maps 1:1 to `core.Digest` after derivation). |
| `core.Digest` | Content addressing | SHA256 digest of blob; used for origin ownership & metainfo retrieval. |
| `core.PeerInfo` | Announce payload | Describes peer id, network address, zone, cluster, completion state (`Complete` boolean). |
| `announceclient.Request` | Client -> tracker | Contains digest (or indirectly infohash), peer info, torrent state. |
| `announceclient.Response` | Tracker -> client | Contains handout peer list + announce interval (next expected re-announce delay). |

Ephemeral nature: Peer presence is valid only until TTL expiry (configured in peerstore implementation). Peers must re-announce before expiry to remain discoverable.

---

## Protocol Specification (Announce)

### Version Negotiation
Clients select announce version (V1 or V2) locally; tracker currently serves both. Future deprecation path: remove V1 after migration (V2 path param avoids ambiguity and requires fewer bytes in body).

### Request (V2 preferred)
```
POST /announce/<infohash>
Content-Type: application/json

{
  "name": "<digest-hex>" ,      // Backwards compatibility field (to be removed)
  "digest": {                     // Optional; either digest struct or name is accepted
    "alg": "sha256",             // Provided implicitly by Hex string; existing clients embed fully
    "hex": "<64 hex chars>"      // (Simplified here; in code it's core.Digest marshaling)
  },
  "info_hash": "<20-byte hex>",  // Must match path parameter (ignored / validated eventually)
  "peer": {
    "peer_id": "<string>",
    "ip": "<ipv4/ipv6>",
    "port": <int>,
    "zone": "<az or rack>",
    "cluster": "<clustername>",
    "complete": <bool>
  }
}
```

### Response
```
200 OK
{
  "peers": [ { "peer_id": "...", "ip": "...", "port": 15000, "complete": false, ... }, ...],
  "interval": 3000000000   // nanoseconds (time.Duration JSON encoding)
}
```

### Error Responses (Representative)
| Condition | HTTP | Body | Notes |
|-----------|------|------|------|
| Malformed JSON | 500 | status wrapper | Handler returns internal decode error (legacy pattern). |
| Invalid infohash hex | 500 | status wrapper | Parsing error before announce logic. |
| Peer store and origin store both fail / empty | 500 | `no peers available` | Combines aggregated errors (see `errutil.Join`). |

Note: Some internal errors surface as 500 rather than structured codes to keep client logic simple (either treat as transient and retry, or fallback to prior peer set). Future improvement: adopt explicit 4xx vs 5xx separation for invalid client input vs server issues.

---

## Announce Lifecycle

1. Peer constructs `announceclient.Request` with torrent digest or infohash, own `PeerInfo`, and completion flag.
2. Sends either:
   * V1: `GET /announce` (legacy) with JSON body.
   * V2: `POST /announce/{infohash}` with JSON body (infohash path param authoritative).
3. Server deserializes, validates digest & infohash (hex parsing), and updates peer store (`peerStore.UpdatePeer`).
4. Retrieves candidate peer set:
   * `peerStore.GetPeers(infohash, limit)` — random subset (implementation gives approximate uniform sampling) up to `PeerHandoutLimit`.
   * `originStore.GetOrigins(digest)` — cached origin seeders (converted to `PeerInfo` with `Complete=true`). Unavailable origins omitted.
5. Concatenates peers + origins; if announcing peer is marked `Complete == true`, returns empty list (seeder does not need additional peers).
6. Sorts peer list using configured priority policy (see below).
7. Responds with sorted peers + `AnnounceInterval` (client re-announce period). If no peers available, returns error.
8. Client integrates returned peers into its connection manager / scheduler.

Concurrency: The update + handout path is intentionally lock-minimal; peer store handles concurrency internally; policy sorting operates on snapshot slice.

---

## Peer Store Implementations

Interface:
```
type Store interface {
  Close()
  GetPeers(h core.InfoHash, n int) ([]*core.PeerInfo, error)
  UpdatePeer(h core.InfoHash, peer *core.PeerInfo) error
}
```

### Local (In-Process)
* Maintains per-infohash buckets keyed by peer id.
* TTL segmentation windows (config) allow approximate random sampling by window merging.
* Suited for single tracker or small cluster deployments.

### Redis Store
* Enabled via config (`peerstore.redis.enabled`).
* Uses Redis sorted sets / data structures to bucket peers with timestamps, enabling TTL eviction by periodic scans.
* Supports horizontal scaling: multiple tracker instances share peer presence population.

Failure Tolerance: If Redis unavailable and not configured with local fallback, tracker loses ability to hand out dynamic peers (origins still provided via originstore).

### LocalStore Internal Algorithm
* Data structure per `InfoHash`: `peerGroup` containing slice (`peerList`) + map (`peerMap`) of `peerEntry`.
* Update path: O(1) append & map insert; expiration timestamp set to `now + TTL` (config default 5h).
* Cleanup goroutines:
  * Entry cleanup every 5m: scans groups, collects expired indices, removes in-place via swap-delete for O(e) where e is number expired.
  * Group cleanup every 1h: removes whole groups whose `lastExpiresAt < now` (fast path ensures minimal locking contention).
* Random sampling: `rand.Perm(len(peerList))[:n]` yields unique indices; may include slightly expired entries (favor speed over strict freshness). Expired peers disappear gradually after next cleanup cycle.

Trade-offs: Simplicity & speed; accepts modest staleness. Useful for small / test clusters or where Redis not available.

### RedisStore Internal Algorithm
* Time partitioning: Peers bucketed into fixed-size windows (`PeerSetWindowSize` default 1h). Window key: `peerset:<infohash>:<windowEpoch>`.
* Peer serialized string: `peer_id:ip:port:completeBit`.
* TTL: Each window expires at `windowEpoch + windowSize * MaxPeerSetWindows` ensuring sliding retention across multiple windows (e.g. 5 windows => 5h retention by default).
* Update: `SADD` + `EXPIREAT` pipeline. O(1) for Set insertion.
* Sampling: shuffle window order; call `SRANDMEMBER` per window until `n` unique peers accumulated. Completion bit collapsed (logical OR) across windows to reflect latest seeder state.
* De-dup: Map keyed by (peerID, ip, port) ensures uniqueness; final array built from map.

Advantages: Horizontal scaling (multi-tracker processes share state), stable memory footprint bounded by Redis capacity, approximate uniform random sample across recent temporal slices.

Limitations: Completion bit could lag if older window overrides; mitigate by reducing `MaxPeerSetWindows` or window size.

---

## Origin Store Caching (`originstore`)

Purpose: Provide resilient origin peer inclusion even when individual origin nodes are transiently unreachable.

Mechanisms:
* Two deduplicated limiter caches:
  * `locations` — digest -> list of origin addresses (hash ring via `blobclient.Locations`).
  * `peerContexts` — origin address -> `PeerContext` (converted to `PeerInfo`).
* Each request function returns value + TTL. Success and error TTLs differ (shorter TTL for errors to allow faster recovery).
* On error for specific origin address the system logs and continues; only if all addresses fail is an `allUnavailableError` returned (propagated with peer handout fallback to non-origin peers only).

This design prevents stampeding the origin cluster: multiple simultaneous announces for the same digest share a single inflight retrieval.

TTL Semantics:
| Field | Default | Meaning |
|-------|---------|---------|
| `LocationsTTL` | 10s | Cache of origin addresses for a digest after success. |
| `LocationsErrorTTL` | 1s | Retry quickly on errors discovering origin addresses. |
| `OriginContextTTL` | 10s | Cache of peer context (peer id / metadata) for an origin node. |
| `OriginUnavailableTTL` | 60s | Backoff period when origin address determined unavailable. |

Design Rationale: Short TTLs encourage responsiveness to origin scaling events; error TTL shorter for fast recovery; unavailability TTL longer to avoid hammering down nodes.

---

## Peer Handout Priority Policies

Policy plug-in architecture selects strategy via `peerhandoutpolicy.Config.Priority`.

General flow:
1. Convert candidate peer slice to `peerPriorityInfo{peer, priority, label}` using policy-specific `assignPriority`.
2. Sort ascending by integer priority.
3. Produce handout slice (excluding announcing self).
4. Emit gauge metrics per label category (`peerhandoutpolicy.count{label=...}`) representing distribution of handout categories per announce cycle.

Implemented Policies (summary based on file set):
* `default` policy (`_defaultPolicy`): Baseline random / heuristic ordering (exact weight derivation located in `default_policy.go`).
* `completeness` policy (`_completenessPolicy`): Prefers peers with higher piece availability / completion ratio to accelerate swarm bootstrap (details in `completeness_policy.go`).

Extensibility: New policies implement `assignmentPolicy` with `assignPriority(*PeerInfo) (priority int, label string)` returning lower integers for higher preference and optional label tokens for metrics grouping.

---

## Metainfo Retrieval Flow

Endpoint: `GET /namespace/{namespace}/blobs/{digest}/metainfo`
* Proxies call to origin cluster: `originCluster.GetMetaInfo(namespace, digest)` which may return 202/404/200 (the tracker reproduces origin error code & response payload transparently).
* Success path: Serializes `core.MetaInfo` to JSON; sets `Content-Type: application/json`.
* Timer metric: `trackerserver.get_metainfo` histogram.

Use Case: Agents fetching torrent metainfo to initiate piece scheduling after determining they require a blob (one tracker per cluster results in consistent origin metainfo caching probability).

---

## Readiness & Health

* `/health`: Always 200 if process alive.
* `/readiness`: Delegates to `originCluster.CheckReadiness()` — ensures origins/backends are prepared before admitting announces/metainfo traffic (protects swarm bootstrap correctness in early startup).

Production Deployments: Place behind load balancer performing active health checks; enforce slow start to prevent surge before caches warm.

---

## Configuration Reference (Subset)

| Field | Description |
|-------|-------------|
| `peerstore` | Redis vs local store selection + TTL window sizes and counts. |
| `originstore` | TTLs for locations success/error, origin context success/unavailable. |
| `trackerserver` | Listener (net/addr), announce interval, peer handout limit. |
| `peerhandoutpolicy` | `priority` enum selecting policy implementation. |
| `origin` | Upstream origin cluster host list (DNS or static) + healthchecks. |
| `tls` | Client TLS for origin communication. |
| `nginx` | Fronting proxy configuration (TLS termination, port mapping). |
| `metrics` | Backend metrics config (tally sink). |

### Full YAML Example
```
peerstore:
  local:
    ttl: 5h
  redis:
    enabled: true
    addr: redis:6379
    peer_set_window_size: 1h
    max_peer_set_windows: 5
    dial_timeout: 5s
    read_timeout: 30s
    write_timeout: 30s
    max_idle_conns: 10
    max_active_conns: 500
    idle_conn_timeout: 60s
originstore:
  locations_ttl: 10s
  locations_error_ttl: 1s
  origin_context_ttl: 10s
  origin_unavailable_ttl: 1m
trackerserver:
  get_metainfo_limit: 1s
  announce_limit: 50
  announce_interval: 3s
  listener:
    net: tcp
    addr: 0.0.0.0:7200
peerhandoutpolicy:
  priority: completeness
origin:        # upstream origin cluster (active set)
  # (fields defined in upstream.ActiveConfig)
tls:
  # TLS client configuration for origin / build-index
metrics:
  # sink configuration
nginx:
  # optional front config if embedded
```

### Key Tuning Parameters
* `PeerHandoutLimit`: Larger values increase connectivity & redundancy but raise per-announce payload size and potential connection churn.
* `AnnounceInterval`: Lower interval accelerates convergence & stale peer cleanup but increases tracker load.
* `PeerStore TTL`: Determines retention window for non-reannouncing peers; tune against typical duration of blob downloads.
* `OriginStore LocationsTTL/OriginContextTTL`: Increase to reduce load on origins; decrease for faster origin join/leave detection.

---

## Metrics & Instrumentation

Tracker attaches middleware for per-route latency and status code counts:
* `trackerserver.request_latency{route=...}`
* `trackerserver.request_status{code=...}`

Custom metrics:
* `peerhandoutpolicy.count{label=<policy_label>}` gauges distribution of peers by priority buckets.
* `trackerserver.get_metainfo` timer (explicit start/stop).
* Version emitter attaches module build information (for fleet diff).

Observability Tips:
* Alert on sudden drop in average peers per handout (indicates peerstore or announce issues).
* Track origin inclusion rate: ratio of origin seeders among provided peers; if zero unexpectedly, originstore may be degraded.

### Metrics Catalog
| Metric Name | Type | Tags | Description |
|-------------|------|------|-------------|
| `trackerserver.request_status` | Counter | `code` | HTTP response status counts. |
| `trackerserver.request_latency` | Timer | `route` | Per-route latency distribution. |
| `peerhandoutpolicy.count` | Gauge | `label`, `priority` | Per-priority bucket peer count per announce cycle. |
| `trackerserver.get_metainfo` | Timer | none | Latency of metainfo retrieval proxy. |
| `version` (module) | Gauge/Counter | build info | Emitted once to tag service version (implementation specific). |
| (Redis internal) | External | n/a | Recommend complement with Redis ops/sec, latency. |

Suggested Additions (not yet implemented): announce error counter, peerstore sample size histogram, originstore cache hit ratio, dedup limiter contention gauge.

---

## Failure Modes & Resilience

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Redis unavailable | Handout limited to local tracker instance peers (if no local fallback) or total failure if single reliance | Multi-instance deployment with local failover or retry policy; monitor errors. |
| All origins unavailable for digest | Handout excludes origins; swarm bootstrap slower; metainfo may still be served if already cached at origin | originstore returns error; log aggregation; fallback purely P2P once initial seeds exist. |
| Slow origin metainfo generation | Clients receive 202 from origin (propagated); repeated backoff polls | Client cluster backoff logic. |
| Peer not re-announcing | Stale entry eventually evicted; may cause short-term handout inefficiency | Ensure announce interval < TTL; monitor dropouts. |
| Policy misconfiguration | Suboptimal peer ordering, slower piece spread | Revert to default; use metrics for validation. |

Grace under Load: Tracker performs minimal CPU work (JSON parsing, map updates, slice sort) per announce; ensure adequate CPU to avoid latency spikes. Backpressure arises only via upstream origins (metainfo path) or Redis.

---

## Concurrency & Caching Internals

* PeerStore concurrency handled by implementation (Redis network concurrency; local map with synchronization primitives — see implementation files for locking details).
* `dedup.Limiter` in `originstore` ensures only one concurrent request per key (digest or origin addr) in execution; others wait for completion or reuse cached result with TTL.
* Sorting algorithm: O(n log n) where n = candidate peers + origins (bounded by PeerHandoutLimit + origin replica count); negligible cost (< few hundred peers typical).

---

## Security Considerations

* Tracker trusts announce payloads (peer id, completion flag); malicious peers could misrepresent completion to be excluded from uploads — mitigated by network-level auth or future integrity heuristics.
* TLS recommended (nginx front) to prevent passive network inspection / injection of announces.
* Potential abuse: Flood of bogus announces for random infohashes -> memory pressure; employ rate limiting / per-IP quotas outside tracker or extend server middleware.

### Hardening Recommendations
| Threat | Mitigation |
|--------|------------|
| Sybil attack inflating peer set | Enforce mTLS or per-peer auth token; cap peers per source IP / CIDR. |
| Infohash scanning (enumeration) | Rate limit announces with unknown digests; optional bloom filter of known digests. |
| Completion spoofing | Cross-check reported completion with observed upload stats (future metric). |
| Replay of stale announces | Include monotonic timestamp / nonce signed by agent key (future extension). |
| Resource exhaustion via large payloads | Enforce request size limit at reverse proxy (nginx) and early decode guard. |

---

## Extension Points

| Area | Approach |
|------|----------|
| New peer priority criteria | Implement new `assignmentPolicy`, register in `NewPriorityPolicy`. |
| Alternate peer store (e.g. SQL, Memcached) | Add new config block and implement `Store` interface. |
| Additional announce validation | Insert middleware / wrapper around `announce()` to enforce ACLs or token checks. |
| Enhanced origin selection | Modify `originstore` to weight origins by load / latency metrics. |
| Adaptive announce interval | Return per-peer dynamic interval based on health / completeness. |
| Custom discovery backends | Implement peerstore adapter for alternative KV (etcd, consul). |
| Enhanced metainfo routing | Layer LRU caching of metainfo in tracker to reduce origin calls. |
| Quota plugin | Pre-handout hook to enforce global / namespace peer caps. |

---

## Example Announce Sequence (V2)

```
POST /announce/<infohash>
Body: {
  "digest": "sha256:abc...",
  "info_hash": "ignored in v2 (path authoritative)",
  "peer": {
    "peer_id": "agent-123", "ip": "10.0.1.7", "port": 15000,
    "zone": "us-east-1a", "cluster": "prod01", "complete": false
  }
}
< 200 {
  "peers": [ {"peer_id": "agent-987", ...}, {"peer_id": "origin-1", "complete": true}, ...],
  "interval": 30
}
```

Peer then connects to provided peers (subject to its scheduler's connection limits) and begins piece exchange.

### Sequence Diagram (Abstract)
```
Agent                Tracker              PeerStore          OriginStore            OriginCluster
 |  Announce (d,h,p)  |                      |                   |                          |
 |------------------->|                      |                   |                          |
 |                    | UpdatePeer(h,p)      |                   |                          |
 |                    |--------------------->|                   |                          |
 |                    |   peers[]=...        |                   |                          |
 |                    |<---------------------|                   |                          |
 |                    | GetOrigins(d)        |                   |                          |
 |                    |------------------------------------------>|   locations / contexts   |
 |                    |                         origins[]         |<-------------------------|
 |                    | Merge+Sort peers+origins                  |                          |
 |   Response(peers)  |                      |                   |                          |
 |<-------------------|                      |                   |                          |
```

Sorting step applies chosen policy; origins appear as `Complete` seeders.

---

## Future Enhancements (Ideas)

* Gossip-based secondary peer discovery to reduce announce dependency frequency.
* Bloom-filter / sketch-based summarization to shrink announce payload size for many torrents.
* Peer reputation scoring (upload contribution weighting) integrated into priority policy.
* Secure announce tokens / HMAC to prevent spoofing.
* Backpressure signals to origins to modulate seeding load.
* Tracker-level L2 metainfo cache for hot torrents.
* Dynamic peer handout limits based on swarm size growth curves.
* Pluggable selection strategy aware of network topology (rack / AZ locality weighting).
* Redis bloom filter to detect duplicate announces faster.

---

## License

Apache License 2.0 (refer to root `LICENSE`).

---

## Contributing

Enhancements to peer selection, new store backends, and resiliency improvements are welcome. Provide benchmarks (announce throughput, latency) and test cases for new policies or cache behaviors.

---

## Summary

The tracker coordinates ephemeral peer connectivity with minimal persistent state, leveraging caching and pluggable prioritization to construct a robust, rapidly converging P2P overlay. Its lightweight design, clear extension seams, and resilience patterns are central to Kraken's ability to scale large, heterogeneous clusters efficiently.
