# Chromium Sync Wire Protocol Plan

The target wire surface is Chromium's sync `/command` endpoint:

```text
POST /command
content-type: application/octet-stream
body: sync_pb.ClientToServerMessage
response body: sync_pb.ClientToServerResponse
```

The reference protocol and loopback implementation are preserved in:

```text
third_party/chromium_sync_loopback/components/sync/protocol
third_party/chromium_sync_loopback/components/sync/engine/loopback_server
```

## Current State

The portable core now implements the behavior we need independent of Chromium:

- `CommitMessage` equivalent: `CommitRequest`
- `GetUpdatesMessage` equivalent: `GetUpdatesRequest`
- `ClearServerDataMessage` equivalent: `LoopbackSyncRpcMethod::ClearServerData`
- store birthday validation
- per-type progress marker tokens
- monotonic server-assigned versions
- permanent roots
- tombstones
- optional strong conflict detection
- local client dirty-state commit and pull cycle

The `LoopbackSyncRpcService` exposes the Chromium-shaped command boundary:

```cpp
LoopbackSyncRpcService::commandHttpMethod() == "POST"
LoopbackSyncRpcService::commandPath() == "/command"
LoopbackSyncRpcService::wireContentType() == "application/octet-stream"
```

## Wire Adapter

`ChromiumSyncWireAdapter` depends on generated protobuf classes, not on
Chromium runtime code:

```text
sync_pb::ClientToServerMessage
  -> LoopbackSyncRpcRequest
  -> LoopbackSyncRpcService
  -> LoopbackSyncRpcResponse
  -> sync_pb::ClientToServerResponse
```

The adapter is the only production code in `src/ng/browser/sync` that includes
generated Chromium sync protobuf headers. The server/client state machine stays
portable and testable without protobuf.

## Build Dependency

`protoc` and `libprotobuf-dev` are required. CMake generates the preserved
Chromium sync `.proto` corpus into the build directory and links it into
`ng_chromium_sync_proto`.

The wire test serializes a real `ClientToServerMessage`, sends it through the
adapter, and deserializes `ClientToServerResponse`.

---
