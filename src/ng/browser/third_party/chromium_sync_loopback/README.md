# Chromium Sync Loopback Import

This directory preserves the Chromium loopback sync server source, sync
protocol definitions, and sync base types as upstream reference code.

Imported from local Chromium checkout:

```text
/home/cory/cef-automate/chromium/src
```

Included paths:

```text
components/sync/engine/loopback_server
components/sync/protocol
components/sync/base
```

The ng-webkit portable sync core in `include/ngwebkit/sync` and `core/sync`
does not include these headers directly. This import is the protocol/type source
of truth for porting the loopback behavior and for building a transport adapter
that looks like Chromium's `/command` sync RPC without requiring ng-webkit to
embed Chromium.

Chromium's original license and authors files are preserved as
`LICENSE.chromium` and `AUTHORS.chromium`.

---
