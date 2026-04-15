# Runner

The runner is a small Node.js HTTP service in `service/` that turns
`./scripts/run-build.sh <platform> <id>` into an API. Every platform is driven
the same way: create a build id, spawn the platform shell script, tail its log
into `var/logs/`, and record state in `var/state.json`.

## Current state (2026-04-15)

- **REST API**: implemented (`service/src/server.js`, port 8787).
- **Web UI**: not yet built. The API is consumable from curl today; a minimal
  HTML + vanilla JS frontend is the next item on the roadmap.
- **Windows**: green via `run-build.sh windows <id>` with 7 bundled patches,
  including WebGPU/Dawn enabled. Detached worker + marker poll, hangs and
  silent deaths are all fixed.
- **macOS**: harness in place (launchctl-based detached worker, marker poll),
  but the build itself is currently failing on a libwebrtc
  `-Wconstant-conversion` error. Fix in progress (cast to `uint16_t` in
  `network_constants.h`).
- **Android**: local builds run end-to-end and artifacts land in S3.

## Endpoints

```
GET  /                              service info + endpoint list
GET  /builds                        list all builds (from var/state.json)
POST /builds                        start a new build
GET  /builds/:id                    get a single build
GET  /builds/:id/logs/:platform     stream the per-platform service log
POST /builds/:id/checkpoint         append a checkpoint note
POST /builds/:id/cancel             SIGTERM the running child processes
POST /builds/:id/restart            re-run the same build id
GET  /changes                       config/changes.json contents
GET  /dependencies                  config/dependencies.json + catalog
```

### Starting a build

```bash
# Default platforms (android, windows, macos)
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{"reason": "nightly smoke"}'

# One platform only
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{"platforms": ["windows"], "reason": "windows fix-check"}'
```

The service creates a build id (timestamp + random), forks
`scripts/run-build.sh <platform> <id>` for each requested platform, and returns
`202 Accepted` with the build record. Status flips from `running` to
`succeeded` / `failed` / `cancelled` when each child exits.

> **Gap**: the service does not yet pass per-build environment variables
> through to the child (e.g. `NG_WINDOWS_ENABLE_WEBGPU=1`). Today that flag is
> set on the shell that starts the service. The next iteration will accept an
> `env` object in the POST body and forward it into the spawn.

## Build pipeline (per platform)

```
  run-build.sh <platform> <id>
          │
          ▼
  platforms/<platform>/build.sh
          │
          │  bundles patches + config + remote-build script,
          │  uploads to S3, kicks off a short SSM bootstrap
          ▼
  SSM bootstrap on builder
          │
          │  downloads bundle, starts a detached worker
          │  (launchctl on macOS, Start-Process on Windows),
          │  returns BOOTSTRAP_OK in <5s
          ▼
  worker runs remote-build.{ps1|sh}
          │
          │  clean checkout → apply patches → build →
          │  verify → tar bin/ → upload → write BUILD_DONE.txt
          ▼
  driver polls BUILD_DONE / BUILD_FAILED every 90s
          │
          ▼
  checkpoint.sh records completion; var/state.json updated
```

Each builder only ever has **one short SSM command at a time** (the bootstrap
or a marker-poll probe). Long-running xcodebuild/ninja sessions run
**outside** SSM so they aren't capped by its ~1h plugin timeout.

## Platform-specific notes

### Windows (`i-0d254760fe07c5e9f`, `eu-west-1`)

- Detachment: `Start-Process -WindowStyle Hidden` survives SSM session end.
  **Do not** use `-NoNewWindow -Wait` — it hangs post-build in headless
  SYSTEM sessions.
- Argument quoting: paths with spaces (`C:\Program Files\Amazon\AWSCLIV2\aws.exe`)
  must be quoted with backtick-quotes in `-ArgumentList` or parameter binding
  silently fails and the worker dies before any code runs.
- Git stderr: under `$ErrorActionPreference = "Stop"`, git's progress messages
  become a terminating `NativeCommandError`. All git calls go through
  `Invoke-Git` which sets `Continue` locally and checks `$LASTEXITCODE`.
- Archive: use `tar -czf` (ships in Windows 10+/Server 2019+), not
  `Compress-Archive` which is single-threaded and hangs on large trees.
- WebGPU: vcpkg ships Dawn as `webgpu_dawn.lib` / `webgpu_dawn.dll`; patch
  `0004` teaches `FindDawn.cmake` to look for those names and enables
  `ENABLE_WEBGPU` in `OptionsWin.cmake` (the upstream option is `PRIVATE`
  and cannot be overridden from the command line).

### macOS (`i-092d7452a5deac519`, `eu-central-1`)

- Detachment: `launchctl submit -l <label> -- bash …`. Plain `nohup + disown`
  does **not** survive SSM session cleanup on macOS — the agent kills the
  child. `launchctl submit` registers a launchd job in the System session,
  which does.
- `HOME` is not set in SSM root sessions; the build scripts explicitly set
  `HOME=/var/root` so `git config --global` and homebrew work.
- Dubious ownership: `git config --global --add safe.directory
  /Users/ec2-user/Work/WebKit` because the clone is owned by `ec2-user` but
  SSM commands run as root.
- Concurrency: two xcodebuild processes sharing the same WebKit checkout will
  corrupt `WebKitBuild/XCBuildData/build.db`. Only run one macOS build at a
  time, or use `NG_MACOS_USE_CLEAN_CHECKOUT=1` (per-build checkout).

### Android (local)

- Builds on this host. No SSM, no marker polling — just
  `run-build.sh android <id>` which calls `platforms/android/build.sh` and
  invokes `./gradlew`.

## Files

- `service/src/server.js` — HTTP service.
- `scripts/run-build.sh` — single entrypoint that routes to a platform script.
- `scripts/common.sh` — shared helpers (logging, marker polling,
  `ng_windows_ssm_poll_build_markers`, `ng_macos_ssm_poll_build_markers`).
- `scripts/windows-ssm-poll.sh` — standalone poll tool for re-attaching to an
  in-flight Windows build.
- `platforms/<platform>/build.sh` — stages the bundle, sends the SSM
  bootstrap command, invokes the marker poller.
- `platforms/windows/remote-build.ps1`, `ssm-worker.ps1` — PowerShell that
  runs on the Windows builder.
- `platforms/macos/remote-build.sh`, `ssm-worker.sh` — shell that runs on the
  macOS builder.
- `patches/<platform>/` — ordered patch series bundled with each build.
- `config/platforms.json`, `config/build-machines.json` — platform status and
  builder metadata.
- `var/state.json` — persistent build history consumed by the service.
- `var/logs/` — per-build per-platform log files.

## What is missing

1. **Web UI**. Plain HTML served from the Node service, with a row per build,
   a platform selector, expand-to-view logs, and a download button that hits
   the S3 artifact directly. The API can already drive it.
2. **Per-build env override**. `POST /builds` should accept an `env` object
   so WebGPU can be toggled per build from the UI without restarting the
   service.
3. **Validation phase**. After a build, actually run `MiniBrowser.exe` / the
   macOS `MiniBrowser.app` with a probe HTML that reports `navigator.gpu`
   state to a local HTTP listener, and attach the JSON result to the
   artifacts. Scoped but not yet shipped.
4. **macOS green**. Currently blocked on `libwebrtc`
   `network_constants.h -Wconstant-conversion` under Xcode 16. Patch in
   flight (explicit `static_cast<uint16_t>` around the wrap-around
   arithmetic).
5. **Linux + iOS**. Entries exist in `config/platforms.json` as `empty` and
   are not wired up.
