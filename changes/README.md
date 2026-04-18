# WebKit Changes

This directory is the central place for product changes that must flow into every
downstream WebKit build.

Each change lives in `changes/<change-id>` and has:

- `manifest.json`: metadata, target platforms, and notes.
- `patches/common`: patches applied to every platform source tree.
- `patches/<platform>`: platform-specific patches.

Enable or disable changes in `config/changes.json`. Build scripts apply enabled
changes in that file before platform-specific legacy patches from `patches/*`.

Create a change:

```bash
./scripts/new-change.sh passkeys-credentials-get
```

Then add patches under the new change directory and set `"enabled": true` in
`config/changes.json`.

---
