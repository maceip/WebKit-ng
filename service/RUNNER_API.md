# Runner API Contract

The dashboard service is the control plane for repeatability work. Agents should
use these HTTP endpoints for git state, dependency state, logging, and build
launch instead of starting unmanaged shell or SSM commands.

## Source

```bash
curl http://localhost:8787/git
curl -X POST http://localhost:8787/git/pull \
  -H 'content-type: application/json' \
  -d '{}'
```

`POST /git/pull` runs `git pull --ff-only` in the repository root and appends
output to `var/logs/api-git-pull.log`.

## Dependencies

```bash
curl http://localhost:8787/dependencies
curl http://localhost:8787/dependencies/status
```

`GET /dependencies/status` checks the local runner commands that the service
needs to orchestrate builds. It is a status endpoint, not an installer.

## Logs

```bash
curl http://localhost:8787/logs
curl 'http://localhost:8787/logs/<name>?tail=1000'
curl 'http://localhost:8787/builds/<build-id>/logs/windows?tail=4000'
```

Build scripts should write through the service log paths so the dashboard can
tail them. Completed Windows artifacts must include `patch-manifest.json`,
`manifest-pre.json`, `manifest-post.json`, and validation JSON.

## Builds

```bash
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{
    "platforms": ["windows"],
    "presets": { "windows": "webgpu-dawn" },
    "phase": 2,
    "reason": "compute readback retry"
  }'
```

For Windows WebGPU/Dawn presets, `phase` is optional but preferred. When present,
the service normalizes the reason as `webgpu phase <N>: ...`; when absent it uses
a neutral `webgpu:` prefix rather than assuming a default milestone. The integer
is a **tag for searchability and checkpoints**; it does **not** define scope.
**Scope for milestones exists only in** `WebKit-ng/DOCUMENTATION.md`. The Windows
WebGPU/Dawn preset owns source selection and feature flags. Do not start a raw
SSM command for this lane; if the dashboard cannot express the operation, extend
the API first.

Phase checkpoints can also carry `phase`:

```bash
curl -X POST http://localhost:8787/builds/<build-id>/checkpoint \
  -H 'content-type: application/json' \
  -d '{"phase":2}'
```

If no message is supplied, the service writes a phase-specific checkpoint with
artifact and validation-report links for Windows WebGPU builds.

## Android (default: remote Linux SSM)

The child build inherits **`process.env`** plus **`platformEnv.android`**. **`build.sh`**
defaults to the standard remote instance (`i-08a3afbbac86a0002`) unless **`NG_ANDROID_LOCAL=1`**.
Put **`NG_ANDROID_BUILDER_ANDROID_HOME`**, **`NG_ANDROID_REGION`**, **`AWS_REGION`**, and
**`NG_ARTIFACT_BUCKET`** in repo **`.env`** if you use **`npm start`**.

Same marker contract as macOS: **`var/ANDROID_ACTIVE_BUILD.env`**, **`*-android.service.log`**.

```bash
curl -X POST http://127.0.0.1:8787/builds \
  -H 'content-type: application/json' \
  -d '{"platforms": ["android"], "reason": "android default remote"}'
```

Override instance or force local via **`platformEnv.android`** (e.g. **`NG_ANDROID_INSTANCE_ID`**, **`NG_ANDROID_LOCAL`**).

---
