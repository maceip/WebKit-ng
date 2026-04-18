# Sync

This directory owns the portable sync loopback boundary. It is modeled on
Chromium's loopback sync server and `/command` RPC, but it does not link
Chromium `base`, `net`, profiles, services, or UI.

Current portable pieces:

- `LoopbackSyncServer`: in-process server with store birthdays, progress
  markers, monotonic server versions, permanent roots, tombstones, and conflict
  detection.
- `LoopbackSyncClient`: local client state with dirty commits, get-updates, and
  birthday handling.
- `LoopbackSyncRpcService`: Chromium-shaped `/command` RPC boundary for commit,
  get-updates, and clear-server-data.
- `SyncTypes`: typed records and requests used by the portable core.

The exact Chromium protocol corpus is preserved under:

```text
third_party/chromium_sync_loopback
```

That import includes Chromium's loopback server implementation and sync
protocol `.proto` files. The next step is a generated-protobuf wire adapter that
maps `sync_pb::ClientToServerMessage` and `sync_pb::ClientToServerResponse` to
the portable `LoopbackSyncRpcService`, keeping the real on-wire format
compatible with Chromium's sync `/command` endpoint.

---
