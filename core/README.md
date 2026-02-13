# Core Module

Authoritative definitions for Kraken's immutable content identifiers, piece-level integrity data, torrent metadata, and peer identity primitives. All higher-level services (origin, tracker, proxy, build-index, agents) depend on the invariants documented here.

---
## 1. Overview
The `core` package provides:

| Domain | Type(s) | Purpose |
|--------|---------|---------|
| Content Digest | `Digest`, `Digester`, `DigestList` | Canonical SHA256 blob identity + streaming computation + DB/JSON codecs |
| Torrent Identity | `InfoHash` | 20-byte SHA1 of bencoded *Info* struct (BitTorrent convention) |
| Torrent Metadata | `MetaInfo` (+ internal `info`) | Piece layout + per-piece checksums + blob length, serialized as JSON (bencode only for hashing) |
| Piece Integrity | `PieceHash()` | CRC32 (IEEE) per fixed-size piece for fast corruption detection |
| Peer Identity | `PeerID`, `PeerIDFactory` | Stable or random 20-byte identifiers for swarm membership (hex externally) |
| Peer Context | `PeerContext`, `PeerInfo` | Network + cluster scoping and per-torrent completion state |
| Blob Metadata | `BlobInfo` | Minimal size metadata used during planning |

Design goals:
1. Deterministic: identical content → identical `Digest`, `MetaInfo`, `InfoHash`.
2. Minimal: only store what downstream services require (digest hex reused as torrent name).
3. Streaming friendly: large blobs digested without buffering (see `Digester.Tee`).
4. Stable hashing surfaces: Changing piece hash algorithm or info encoding would invalidate existing swarms; guarded by encapsulation.

---
## 2. Digest Model
`Digest` encodes as `"<algorithm>:<hex>"`. Current algorithm: `sha256` (constant `SHA256`).

Invariants / validation:
* Algo must equal `sha256` (parsing rejects others).
* Hex length exactly 64 characters; verified via `ValidateSHA256` (also rejects non-hex chars).
* `ShardID()` returns first 4 hex chars (16-bit space) used by higher layers for bucket / ring pre-partitioning.

Database / JSON integration:
* Implements `driver.Valuer` / `sql.Scanner` (marshals as JSON string) for both single `Digest` and `DigestList`.
* JSON form is the raw string (e.g. `"sha256:abcd..."`).

Streaming computation:
* `Digester` wraps `crypto.SHA256.New()`.
* `FromReader` copies bytes into internal hash (`io.Copy`), O(n) time, O(1) memory.
* `Tee(r)` returns an `io.Reader` duplicating the stream into the hasher enabling concurrent upload + digest accumulation.

Failure modes:
* Malformed input: parsing functions return explicit errors; no silent fallback.
* Construction from an already validated hex digest (`NewSHA256DigestFromHex`) never recomputes the digest (caller must guarantee correctness—performance trade‑off).

---
## 3. Torrent Metadata (`MetaInfo`)
`MetaInfo` binds a blob digest to a *piece layout* (piece length + ordered CRC32 sums) and yields an `InfoHash`.

Internal `info` struct (bencoded for hash, JSON for storage):
```
PieceLength  int64    // target piece size (last piece may be smaller)
PieceSums    []uint32 // CRC32(IEEE) per piece, order-preserving
Name         string   // digest hex (not raw algo:hex) to avoid redundancy
Length       int64    // total blob length in bytes
```

Construction (`NewMetaInfo`):
1. Caller supplies trusted `Digest d`, blob stream, and `pieceLength` (>0).
2. `calcPieceSums` reads consecutive `pieceLength` chunks; for each chunk:
   * Allocate CRC32 hasher (`PieceHash()`), `io.CopyN` chunk bytes.
   * Append `Sum32()` to `PieceSums`.
   * Stop on short read (< piece length) or EOF.
3. Assemble `info` with `Name = d.Hex()`.
4. Bencode `info` deterministically, SHA1 hash → `InfoHash`.

Why CRC32 for pieces?
* Fast (single-pass, hardware assisted on many CPUs).
* Sufficient to detect accidental corruption during piece transfer.
* Full cryptographic assurance comes from end-to-end SHA256 digest validation at higher layers (e.g. origin on initial ingest, agents post-download if required). Collision risk for CRC32 across different pieces is acceptable given final digest.

Key accessors:
* `InfoHash()` authoritative torrent id.
* `Digest()` underlying blob digest (content identity across torrents/clusters).
* `Length()`, `PieceLength()`, `NumPieces()`, `GetPieceLength(i)`, `GetPieceSum(i)`.

Serialization:
* JSON: only stores `info` (for backward compatibility). On load: recompute `InfoHash` from stored `info` (guards against tampering) and reconstruct `Digest` from `Name`.
* No persistent storage of `InfoHash`; always recomputed → ensures deterministic reproducibility.

Piece length edge cases:
* Must be >0; zero / negative returns error.
* Last piece length = `Length - PieceLength * (NumPieces-1)` (derived in `GetPieceLength`).

Complexity:
* `calcPieceSums`: O(n/p)` hash initializations + O(n)` total I/O. Memory O(1) besides slice of uint32 (4 * numPieces bytes).

---
## 4. Torrent Identity (`InfoHash`)
* 20-byte SHA1 (BitTorrent spec) of bencoded `info` (ordering guaranteed by Go struct field order during bencode marshal).
* Methods: `Hex()`, `Bytes()`, `String()` (hex), constructors from hex (`NewInfoHashFromHex`) and raw `info` bytes (`NewInfoHashFromBytes`).
* Hex string invariant: length 40; decode must produce exactly 20 bytes, else error.
* Chosen for interoperability with existing ecosystem tooling (trackers, magnet links) though primary blob identity remains SHA256 digest.

Relationship Digest ↔ InfoHash:
* Digest identifies raw blob content.
* InfoHash identifies a particular *piece layout* for that blob. Same digest + different piece size ⇒ different InfoHash (and separate swarm) while still representing identical content.

---
## 5. Piece Hashing
`PieceHash()` returns a new `hash.Hash32` (CRC32 IEEE polynomial). A fresh hasher per piece keeps state independent and simplifies streaming. Changing this algorithm would invalidate existing MetaInfo objects (InfoHash changes) and must be versioned carefully (see Extension Points).

---
## 6. Peer Identity & Context
### PeerID
* Fixed 20-byte array (`[20]byte`), hex encoded for external representation.
* Generation strategies (`PeerIDFactory`):
  - `random`: entropy via `rand.Read` (Go's `math/rand` default source is not cryptographically secure; if stronger unpredictability needed, migrate to `crypto/rand`).
  - `addr_hash`: SHA1(`ip:port`) → deterministic per network endpoint; ideal for stable identity across restarts.
* Ordering: `LessThan` lexicographic; used for consistent ordering decisions (e.g., deterministic peer list sorting).

Validation: `NewPeerID(hex)` enforces hex decode of exactly 20 bytes; otherwise `ErrInvalidPeerIDLength`.

### PeerContext
Captures runtime identity and logical placement:
```
IP, Port      // externally announced endpoint
PeerID        // derived via factory when context constructed
Zone, Cluster // topology & multi-cluster scoping
Origin        // boolean: is this an origin node
```
Constructor (`NewPeerContext`) validates non-empty IP / non-zero Port before generating PeerID. Any error (including from factory) aborts context creation.

### PeerInfo
Per-torrent view derived from `PeerContext` + completion state:
```
PeerID, IP, Port, Origin, Complete
```
Used by tracker responses / swarm assembly. Sorting support via `SortedByPeerID` (stable deterministic ordering aiding cache keys & tests).

---
## 7. BlobInfo
Minimal struct containing only `Size int64`. Acts as a lightweight carrier for size metadata where full `MetaInfo` (and piece sums) are unnecessary.

---
## 8. Invariants & Validation Summary
| Aspect | Invariant | Enforced By |
|--------|-----------|-------------|
| Digest algo | must be `sha256` | `ParseSHA256Digest` |
| Digest hex length | 64 chars | `ValidateSHA256` |
| ShardID slice | first 4 hex chars (no bounds check beyond validation) | `ShardID()` |
| InfoHash hex length | 40 chars, decodes to 20 bytes | `NewInfoHashFromHex` |
| PieceLength | > 0 | `calcPieceSums` |
| PeerID length | 20 bytes | `NewPeerID` |
| PeerContext IP | non-empty | `NewPeerContext` |
| PeerContext Port | > 0 | `NewPeerContext` |

Failure of any invariant → explicit error; no defaulting.

---
## 9. Sharding & Ring Integration
Higher layers (e.g. CAS backend placement, hashring in `lib/hashring`) frequently use early bits of digest space for preliminary shard selection / directory fanout. `Digest.ShardID()` (first 4 hex chars ≈ 16 bits) balances:
* Sufficient cardinality for most local filesystem fanouts.
* Cheap derivation (substring operation on already validated hex).

Important: This is NOT a cryptographic partition boundary—only a convenience. Consistent hashing decisions should use full digest bytes when risk of hotspotting matters.

---
## 10. Performance Characteristics
| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Streaming digest (`Digester.FromReader`) | O(n) time / O(1) space | Single pass; no buffering beyond hash state |
| MetaInfo build (`calcPieceSums`) | O(n) I/O + O(n/p) hash inits | Memory dominated by `PieceSums` slice |
| Serialization (marshal) | O(numPieces) | JSON encodes slice | 
| `GetPieceLength` | O(1) | Last piece arithmetic |
| Sorting Peers | O(k log k) | k = number of peers in response |

Hot Paths / Micro-optimizations:
* Piece hashing avoids allocations besides hasher and slice append.
* Uses standard library SHA256/SHA1 which leverage assembly implementations.
* CRC32 IEEE often hardware accelerated (slicing-by-8) on modern CPUs.

Potential bottlenecks: extremely large piece counts (very small piece size) inflate `PieceSums` memory; tune piece length to keep slice size reasonable.

---
## 11. Extension Points & Caution
| Extension | Guidance | Risk |
|-----------|----------|------|
| Additional digest algos | Would require broad schema changes; currently hard-coded `sha256` | Swarm fragmentation, backward incompatibility |
| Alternate piece checksum (e.g. SHA256 per piece) | Could improve corruption detection | Increases CPU + changes InfoHash (breaking existing torrents) |
| PeerID factories | Add new constants + switch branch | Collisions / privacy characteristics must be analyzed |
| Variable piece sizes (adaptive) | Not supported; would alter `info` semantics | Complex InfoHash divergence |

Any change affecting `info` bencoded bytes invalidates existing `InfoHash`; versioning plan and migration tooling required.

---
## 12. Security Considerations
* SHA256 chosen for strong preimage & collision resistance for blob identity.
* SHA1 only used for InfoHash (BitTorrent compatibility); not relied on for content authenticity—digest must be validated where trust matters.
* CRC32 is non-cryptographic: treat piece sums as early corruption indicators, not tamper-proof guarantees.
* Random PeerIDs use `math/rand` (non-crypto). If PeerID entropy becomes security sensitive (e.g., anonymity), migrate to `crypto/rand`.
* Input validation errors MUST be propagated—never ignore digest parse failures (prevents shard directory traversal via malformed hex).

---
## 13. Testing Guidance
Recommended unit test focus (see existing *_test.go files):
* Digest parsing rejects malformed strings (length off-by-one, bad hex chars, wrong algo).
* Determinism: same blob + piece length → identical `MetaInfo` (digest, infohash, piece sums).
* Piece boundary correctness: last piece shorter scenario.
* PeerID factories: deterministic address-hash; ensure random factory differs across runs.
* Serialization round-trip: `MetaInfo.Serialize()` then `DeserializeMetaInfo` reproduces identical `InfoHash` & structural fields.

Property-based tests (future): generate random byte slices and piece lengths, assert invariants (re-serialize / re-hash stable).

---
## 14. Usage Examples
Digest stream (upload pipeline):
```
d := core.NewDigester()
tee := d.Tee(fileReader) // pass tee to consumer while accumulating
// ... consume tee ...
finalDigest := d.Digest()
```

Build MetaInfo (after validating digest matches content upstream):
```
mi, err := core.NewMetaInfo(finalDigest, fileReader, 4*1024*1024) // 4MiB pieces
if err != nil { /* handle */ }
hash := mi.InfoHash()
```

Generate deterministic PeerContext (addr-hash):
```
pctx, err := core.NewPeerContext(core.AddrHashPeerIDFactory, "zone-a", "cluster-x", "10.0.0.5", 4500, false)
peerInfo := core.PeerInfoFromContext(pctx, false)
```

---
## 15. Inter-module References
* Origin service: uses `Digest` + `MetaInfo` during blob ingestion & replication (see `origin/README.md`).
* Tracker: indexes peers by `InfoHash`, returns `PeerInfo` objects (see `tracker/README.md`).
* Proxy & Build-Index: refer to `Digest` for registry tag resolution & preheat (see respective READMEs).
* Library layer: `hashring` may leverage `Digest.ShardID()` for subdirectory layout.

---
## 16. Future Enhancements
| Idea | Rationale |
|------|-----------|
| Pluggable piece checksum (CRC32C / BLAKE3) | Better CPU utilization or stronger error detection |
| Optional per-piece cryptographic hash | Stronger integrity at piece granularity for untrusted networks |
| Multi-algorithm digest negotiation | Transition path if SHA256 supplanted by stronger hash |
| Piece size auto-tuning heuristics | Balance between startup latency and parallelism automatically |
| Crypto-strength PeerID generation | Improve anonymity / collision guarantees |

---
## 17. Summary
The `core` module codifies Kraken's immutability and identity guarantees. Stable, minimal, deterministic primitives here allow higher layers to evolve independently while ensuring interoperability and data integrity across the ecosystem. Any change to hashing or serialization must be treated as a protocol evolution event.
