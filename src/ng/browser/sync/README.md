# Sync

This directory owns the portable sync loopback boundary. The initial
`SyncLoopbackStore` is an in-process server/client-compatible store with typed
commit and get-updates requests.

The long-term target is Chromium sync protocol and type compatibility without
linking Chromium profile, service, or process infrastructure. Browsers can run
as a loopback server, a client, or both against the same transport contract.

