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

---

## Extension Points

| Area | Approach |
|------|----------|
| New peer priority criteria | Implement new `assignmentPolicy`, register in `NewPriorityPolicy`. |
| Alternate peer store (e.g. SQL, Memcached) | Add new config block and implement `Store` interface. |
| Additional announce validation | Insert middleware / wrapper around `announce()` to enforce ACLs or token checks. |
| Enhanced origin selection | Modify `originstore` to weight origins by load / latency metrics. |
| Adaptive announce interval | Return per-peer dynamic interval based on health / completeness. |

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

---

## Future Enhancements (Ideas)

* Gossip-based secondary peer discovery to reduce announce dependency frequency.
* Bloom-filter / sketch-based summarization to shrink announce payload size for many torrents.
* Peer reputation scoring (upload contribution weighting) integrated into priority policy.
* Secure announce tokens / HMAC to prevent spoofing.
* Backpressure signals to origins to modulate seeding load.

---

## License

Apache License 2.0 (refer to root `LICENSE`).

---

## Contributing

Enhancements to peer selection, new store backends, and resiliency improvements are welcome. Provide benchmarks (announce throughput, latency) and test cases for new policies or cache behaviors.

---

## Summary

The tracker coordinates ephemeral peer connectivity with minimal persistent state, leveraging caching and pluggable prioritization to construct a robust, rapidly converging P2P overlay. Its lightweight design, clear extension seams, and resilience patterns are central to Kraken's ability to scale large, heterogeneous clusters efficiently.
