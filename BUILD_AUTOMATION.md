# Build automation — operating rules

Forward-looking **requirements** for ng-webkit builds. **Platform-specific runbooks** hold mechanics; this file holds **policy** and **pointers**.

**Dashboard:** `service/src/server.js` — **`RUNNER.md`**, **`service/RUNNER_API.md`**.

---

## Platforms

| Platform | Doc / entry |
|----------|----------------|
| **Windows** (start here for infra) | **`platforms/windows/WINDOWS_BUILDER.md`** — compliance (`setup-deps`), **disk checks**, **sccache**, truth of `BUILD_DONE.txt`, runner curls |
| **macOS** | **`platforms/macos/notes.md`**, `platforms/macos/build.sh` |
| **Android** | **`platforms/android/setup-deps.sh`**, `platforms/android/build.sh` — **default: remote** Linux SSM builder; **`NG_ANDROID_LOCAL=1`** for local Gradle only (see **`RUNNER.md`**) |
| **iOS** | Not wired yet |

---

## Rules

1. **Turnaround:** Use **compiler caching** and **reuse** where scripts allow (Windows: **sccache** — mandatory unless `NG_WINDOWS_ALLOW_SCCACHE_OFF=1`).

2. **Truth:** **Never** treat “compile finished” as **shipped** for remote builds. Use **`BUILD_DONE.txt`** (upload complete), **`BUILD_FAILED.txt`**, and validation JSON — see **WINDOWS_BUILDER.md** §4.

3. **Disk:** **Full disk** must **fail fast** — Windows **`remote-build.ps1`** enforces **minimum free GiB** (`NG_WINDOWS_MIN_FREE_GB`, default **50**) before heavy work.

4. **Provisioning:** **No ad-hoc** Git/Ruby installs on shared builders. Use **`catalog-deps.sh`**, **`ship-deps.sh`**, **`platforms/*/setup-deps.*`**. If a script fails, **fix the script**.

5. **Coordination:** Prefer **`POST /builds`** + **`POST /builds/:id/checkpoint`** over unmanaged sessions.

---

## Dependency scripts (no `install-depth.sh` in this repo)

| Need | Script |
|------|--------|
| Catalog | `./scripts/catalog-deps.sh` |
| Ship to S3 / machine | `./scripts/ship-deps.sh <platform>` |
| Windows SSM host | `./platforms/windows/setup-deps.sh` |

---

## Related

- **`DOCUMENTATION.md`** — WebGPU/Dawn milestones and gates (prescriptive summary)  
- **`ASSETS.md`** — S3 layout

---
