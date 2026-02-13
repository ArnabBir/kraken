title Kraken Origin Download Cache Miss with Remote Fetch & Local Replication

participant Client
participant OriginA as Origin (Owner A)
participant HashRing
participant BlobRefresher
participant Backend as RemoteBackend
participant CAS as CAStore
participant Hook as localReplicationHook
participant ReplicaB as Replica (Owner B)
participant ReplicaC as Replica (Owner C)

Client->HashRing: Resolve owners for D
HashRing-->Client: [OriginA, ReplicaB, ReplicaC]

Client->OriginA: GET /namespace/ns/blobs/D
OriginA->CAS: GetCacheFileReader(D)
CAS-->OriginA: NotFound
OriginA->BlobRefresher: Refresh(namespace,D, hook=replicateLocally)
BlobRefresher-->OriginA: Accepted (pending)
OriginA-->Client: 202 (pending fetch)

== Coalesced Remote Fetch (single worker) ==
BlobRefresher->Backend: GET object namespace/D
Backend-->BlobRefresher: 200 (stream)
BlobRefresher->CAS: Write cache file D
CAS-->BlobRefresher: OK
BlobRefresher->Hook: PostHook(D)

== Local Replication Fan-out ==
Hook->OriginA: replicateBlobLocally(D)
OriginA->ReplicaB: Internal transfer start
OriginA->ReplicaC: Internal transfer start
par Parallel transfers
  OriginA->ReplicaB: PATCH chunks -> commit
  OriginA->ReplicaC: PATCH chunks -> commit
end
ReplicaB->ReplicaB: Store D in CAS
ReplicaC->ReplicaC: Store D in CAS

== Subsequent Client Retry ==
Client->OriginA: GET /namespace/ns/blobs/D
OriginA->CAS: GetCacheFileReader(D)
CAS-->OriginA: OK (file handle)
OriginA-->Client: 200 (blob stream)

== Metainfo On Demand ==
Client->OriginA: GET /internal/namespace/ns/blobs/D/metainfo
OriginA->CAS: Get TorrentMeta
note over OriginA: If absent, generate via metainfo generator (not shown)
OriginA-->Client: 200 (metainfo)