title Kraken Origin Chunked Upload, Replication, Write-Back

participant Client
participant HashRing
participant OriginOwner as Origin (Primary Owner)
participant CAS as CAStore
participant Uploader
participant Metainfo as MetainfoGenerator
participant WriteBack as WriteBackManager
participant Backend as RemoteBackend
participant Replica1
participant Replica2

Client->HashRing: Resolve owners for digest D
HashRing-->Client: Ordered owners [Origin, Replica1, Replica2]

== Start Upload ==
Client->OriginOwner: POST /namespace/ns/blobs/D/uploads
OriginOwner->Uploader: start(D)
Uploader->CAS: Check blob exists?
CAS-->Uploader: Not found
Uploader->CAS: Create upload temp file (uid)
Uploader-->OriginOwner: uid
OriginOwner-->Client: 200 Location: uid

== Chunked Patch Loop ==
loop For each chunk i
  Client->OriginOwner: PATCH /.../uploads/uid (Content-Range: start-end)
  OriginOwner->Uploader: patch(D, uid, start,end,chunk)
  Uploader->CAS: Seek + write bytes
  CAS-->Uploader: OK
  Uploader-->OriginOwner: OK
  OriginOwner-->Client: 200
end

== Commit ==
Client->OriginOwner: PUT /.../uploads/uid
OriginOwner->Uploader: commit(D, uid)
Uploader->CAS: Atomic move temp -> cache/D
CAS-->Uploader: OK
Uploader-->OriginOwner: OK

OriginOwner->Metainfo: Generate(D)
Metainfo->CAS: Read blob; compute piece hashes; write TorrentMeta
CAS-->Metainfo: OK
Metainfo-->OriginOwner: OK

OriginOwner->CAS: Set Persist metadata true
CAS-->OriginOwner: OK
OriginOwner->WriteBack: Enqueue Task(namespace,D,delay=0)
WriteBack-->OriginOwner: Ack

par Fan-out duplicate uploads
  OriginOwner->Replica1: Internal transfer (start/patch/commit)
  OriginOwner->Replica2: Internal transfer (start/patch/commit)
end

Replica1->CAS: Store D
Replica2->CAS: Store D

loop For each replica i
  OriginOwner->Replica(i): DuplicateUploadCommit(delay = stagger*(i+1))
  Replica(i)->WriteBack: Enqueue delayed task
end

== Async Write-Back Execution ==
WriteBack->CAS: Open blob D
WriteBack->Backend: PUT object namespace/D
Backend-->WriteBack: 200
WriteBack->CAS: Clear Persist metadata (optional policy)
WriteBack-->OriginOwner: Success (metrics)