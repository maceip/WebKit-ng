# Runner

The runner is a small Node.js HTTP service in `service/` that turns
`./scripts/run-build.sh <platform> <id>` into an API. Every platform is driven
the same way: create a build id, spawn the platform shell script, tail its log
into `var/logs/`, and record state in `var/state.json`.

## Current state (2026-04-16)

- **REST API**: implemented (`service/src/server.js`, port 8787).
- **Dashboard**: bare-bones HTML at `GET /` (`service/public/index.html`): pick
  platforms, optional reason, start build, list builds, tail logs, cancel. API
  discovery JSON is `GET /meta` (what used to be on `/`).
- **Windows**: green via `run-build.sh windows <id>` with WebGPU/Dawn enabled
  on the iangrunert Gigacage/Skia fixes branch. Detached worker, marker poll,
  packaging, S3 upload, Dawn DLL load validation, and the Abseil/Dawn ABI
  packaging fix are now captured in repo-owned scripts.
- **macOS**: harness in place (launchctl-based detached worker, marker poll),
  but the build itself is currently failing on a libwebrtc
  `-Wconstant-conversion` error. Fix in progress (cast to `uint16_t` in
  `network_constants.h`).
- **Android**: local builds run end-to-end and artifacts land in S3.

## Endpoints

```
GET  /                              HTML dashboard (build UI)
GET  /meta                          JSON service name + endpoint list
GET  /platforms                     config/platforms.json, including presets
GET  /builds                        list all builds (from var/state.json)
POST /builds                        start a new build
GET  /builds/:id                    get a single build
GET  /builds/:id/artifacts          expected S3 artifact prefixes per platform
GET  /builds/:id/logs/:platform     stream the per-platform service log; add ?tail=200 for recent lines
POST /builds/:id/checkpoint         append a checkpoint note
POST /builds/:id/cancel             SIGTERM the running child processes
POST /builds/:id/restart            re-run the same build id
GET  /changes                       config/changes.json contents
GET  /dependencies                  config/dependencies.json + catalog
```

### Alerts (fail fast, not “inference”)

`scripts/notify.sh` runs on **bootstrap SSM failure**, **remote `BUILD_FAILED.txt`**, **marker poll timeout**, **unexpected marker output**, and (Windows only) **RUNNING with no `artifacts/` after `NG_WINDOWS_ALERT_AFTER_POLLS` polls** (~90s × N by default). Set `NG_ALERT_WEBHOOK_URL` (Slack-compatible `{"text":...}`) and/or `NG_ALERT_CMD` in `.env`. Bell + loud stderr line always.

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

# Windows WebGPU/Dawn lane, using the repo-owned preset
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{
    "platforms": ["windows"],
    "reason": "windows webgpu dawn repeatability",
    "presets": { "windows": "webgpu-dawn" }
  }'
```

The service creates a build id (timestamp + random), forks
`scripts/run-build.sh <platform> <id>` for each requested platform, and returns
`202 Accepted` with the build record. Status flips from `running` to
`succeeded` / `failed` / `cancelled` when each child exits.

`POST /builds` accepts `env` for all platform children, `platformEnv` for a
specific platform, and `presets` keyed by platform. Presets expand from
`config/platforms.json` first; `platformEnv` is then applied so one-off
overrides stay possible. Values are validated as environment-variable-safe
string, number, or boolean values and are persisted in the build request.
Requested platforms are validated against `config/platforms.json`; empty
platform stubs such as Linux and iOS are rejected until their scripts exist.

Build records include per-platform `pid`, `startedAt`, service log path, and
the expected S3 `artifactPrefix`. This keeps the HTTP service useful after the
SSM bootstrap hands off to detached workers.

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
- WebGPU must be enabled through WebKit's feature plumbing:
  `--webgpu -DENABLE_EXPERIMENTAL_FEATURES=ON`. A bare
  `-DENABLE_WEBGPU=ON` can be overwritten because the Win port declares the
  option `PRIVATE`.
- `BUILD_DONE.txt` is an upload-complete marker, not a compile-complete marker.
  The worker writes `BUILD_READY.txt` after `remote-build.ps1` returns, syncs
  artifacts to S3, and only then writes `BUILD_DONE.txt`.
- Keep `manifest-post.json` small. A previous green compile wedged after
  validation while PowerShell serialized a larger object graph. Full validation
  lives in `validation-report.json`; `manifest-post.json` links to it.
- Dawn runtime DLLs are not just "copy all DLLs from the build vcpkg tree".
  `webgpu_dawn.dll` imports Abseil symbols with an inline namespace. On the
  2026-04-16 green run, the build-local Abseil DLL was `lts_20250814` while
  Dawn needed `lts_20260107`. The packaging step now prefers
  `C:\vcpkg\installed\x64-windows-webkit\bin\abseil_dll.dll` when present and
  validates `webgpu_dawn.dll` with `LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)`.
- Canonical repeatable command:

  ```bash
  ./scripts/run-windows-webgpu-dawn.sh <build-id>
  ```
- The Windows validation probe records the first WebGPU/Dawn milestone in
  `validation-report.json.runtime`: `navigator.gpu`, `requestAdapter()`,
  `requestDevice()`, and `device.queue`. This does not imply presentation,
  canvas swapchain, or rendering.

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

1. **Richer dashboard**. In-page log preview, S3 artifact links / downloads, and
   restart-from-UI beyond the current minimal flows.
2. **Validation phase hardening**. Windows now writes the probe and DLL-load
   JSON and reports real adapter/device/queue state. The next Windows step is
   canvas presentation once the Dawn swapchain path exists; macOS still needs
   the equivalent `MiniBrowser.app` probe.
3. **macOS green**. Currently blocked on `libwebrtc`
   `network_constants.h -Wconstant-conversion` under Xcode 16. Patch in
   flight (explicit `static_cast<uint16_t>` around the wrap-around
   arithmetic).
4. **Linux + iOS**. Entries exist in `config/platforms.json` as `empty` and
   are not wired up.
