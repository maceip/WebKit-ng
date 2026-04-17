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
    "reason": "windows webgpu dawn retry"
  }'
```

The Windows WebGPU/Dawn preset owns source selection and feature flags. Do not
start a raw SSM command for this lane; if the dashboard cannot express the
operation, extend the API first.
