# Third-Party Source References

`third_party/chromium_sync_loopback` preserves Chromium's loopback sync server,
sync base types, and sync protocol `.proto` files as the source reference for
the ng sync implementation.

Portable ng code must not include Chromium headers directly. Port behavior into
`src/ng/browser/sync`, then add explicit adapters where Chromium wire protocol
compatibility is required.

---
