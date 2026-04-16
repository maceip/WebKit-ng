# Windows WebGPU/Dawn Runbook

This is the repeatable path for the Windows WebGPU/Dawn lane. Keep this file
updated when the build runner learns a new Windows-specific failure mode.

## Canonical Command

```bash
./scripts/run-windows-webgpu-dawn.sh <build-id>
```

Equivalent web runner request:

```bash
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{
    "platforms": ["windows"],
    "reason": "windows webgpu dawn",
    "presets": { "windows": "webgpu-dawn" }
  }'
```

Useful service reads while the build is running:

```bash
curl http://localhost:8787/builds/<build-id>
curl 'http://localhost:8787/builds/<build-id>/logs/windows?tail=200'
curl http://localhost:8787/builds/<build-id>/artifacts
```

Expanded equivalent, for debugging without presets:

```bash
NG_WINDOWS_SOURCE_PRESET=iangrunert-win-gigacage-skia-fixes \
NG_WINDOWS_ENABLE_WEBGPU=1 \
./scripts/run-build.sh windows <build-id>
```

## Current Known-Good

- Build id: `dawn-d3d12-runtime-20260416T011849Z`
- Source: `iangrunert/WebKit@64f58084c78130b874d05dbcfb508147354095af`
- Builder: `i-0d254760fe07c5e9f`, `eu-west-1`
- Artifact prefix:
  `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/`
- Archive:
  `ng-webkit-windows-dawn-d3d12-runtime-20260416T011849Z.tar.gz`
- Compile result: all 9559 targets linked, including `bin\TestWebKit.exe`
- Dawn load check: `validation-recovered.json` reports
  `webgpuDawnLoadAfterMatchingAbseil.loaded=true`.
- Current milestone probe: `validation-report.json.runtime.smokePassed=true`
  means MiniBrowser exposed `navigator.gpu`, returned an adapter, created a
  device, and exposed `device.queue`.

## Build Runner Rules

1. Use the standard entrypoint only: `./scripts/run-build.sh windows <id>`.
2. Bundle repo patches and active changes; do not patch the Windows checkout by
   hand.
3. Start the worker detached from SSM, but keep SSM commands short.
4. Poll `BUILD_DONE.txt` / `BUILD_FAILED.txt`; do not infer completion from a
   green compile line.
5. Treat `BUILD_DONE.txt` as "uploaded to S3", not "remote-build.ps1 returned".
6. Upload logs, manifests, validation JSON, probe HTML, and the archive.
7. For WebGPU/Dawn, use `scripts/run-windows-webgpu-dawn.sh` or the
   `webgpu-dawn` service preset so the source branch and feature flags remain
   repo-owned.

## WebGPU/Dawn Build Requirements

- Use WebKit feature plumbing:
  `--webgpu -DENABLE_EXPERIMENTAL_FEATURES=ON`.
- Do not rely on only `-DENABLE_WEBGPU=ON`; the Win port declares the option
  `PRIVATE`, so command-line `-D` can be overwritten.
- `patches/windows/0004-windows-enable-webgpu-dawn.patch` owns:
  - `FindDawn.cmake` fallback for `dawn/dawn_proc_table.h`
  - `FindDawn.cmake` fallback for `webgpu_dawn`
  - Win `ENABLE_WEBGPU` default tied to experimental features
  - `find_package(Dawn REQUIRED)` when WebGPU is enabled
  - `--webgpu` support in `FeatureList.pm`
  - vcpkg `webgpu` manifest feature depending on `dawn`

## Runtime DLL Packaging

`webgpu_dawn.dll` and `abseil_dll.dll` are ABI-coupled by Abseil's inline
namespace. The 2026-04-16 green compile initially packaged a build-local
`abseil_dll.dll` exporting `absl::lts_20250814`, while `webgpu_dawn.dll`
imported `absl::lts_20260107`. That caused `LoadLibrary` error 126.

The packaging rule is:

1. Copy Dawn runtime DLLs from the build vcpkg tree.
2. Copy `webgpu_dawn.dll` from `C:\vcpkg\installed\x64-windows-webkit\bin` if
   the build output does not already contain it.
3. Prefer `C:\vcpkg\installed\x64-windows-webkit\bin\abseil_dll.dll` when
   present, because that is the DLL matching the installed Dawn package.
4. Validate with `LoadLibraryEx(path, 0, LOAD_WITH_ALTERED_SEARCH_PATH)`.

The acceptance JSON must show:

```json
{
  "webgpuDawnLoadAfterMatchingAbseil": {
    "loaded": true,
    "win32Error": 0
  }
}
```

## Runtime Probe Acceptance

The Windows validation phase writes `validate-probe.html` and launches
`MiniBrowser.exe` against it. For the first Dawn API milestone, the important
fields in `validation-report.json` are:

```json
{
  "runtime": {
    "gpuAvailable": true,
    "adapter": {},
    "device": {},
    "queueAvailable": true,
    "smokePassed": true
  }
}
```

This intentionally does not prove presentation, canvas swapchain, or rendering.
Those stay a separate milestone after requestAdapter/requestDevice/queue.

## Runtime Bring-Up Ladder

A green compile only means WebKit and Dawn agree enough to build. Treat it as
permission to start runtime work, not as proof that WebGPU is usable.

Bring WebGPU up in this order:

1. Confirm `navigator.gpu` exists in MiniBrowser.
2. Confirm `navigator.gpu.requestAdapter()` resolves.
3. Confirm `adapter.requestDevice()` resolves.
4. Confirm `device.queue` exists.
5. Run a compute-only buffer write/readback test with no canvas.
6. Create a shader module and compute pipeline.
7. Submit commands and verify mapped-buffer readback.
8. Re-enable the Windows presentation/canvas path only after compute works.
9. Configure a WebGPU canvas and draw one visible triangle.
10. Add smoke coverage so future compile fixes cannot silently break runtime.

Keep compute and presentation separate while debugging. If compute fails, debug
WebCore/Dawn object, callback, queue, and buffer plumbing. If compute works but
canvas fails, debug HWND/surface/swapchain/compositor integration.

## Worker Hang Avoidance

The historic "green compile but no artifact" failure was a PowerShell hang after
validation and before archive/upload. The fix is to keep `manifest-post.json`
small and acyclic:

- full runtime details go in `validation-report.json`
- recovery/runtime DLL details go in `validation-recovered.json`
- `manifest-post.json` stores filenames and scalar fields only

The worker writes:

- `BUILD_READY.txt` after `remote-build.ps1` returns
- S3 sync output to the worker log
- `BUILD_DONE.txt` only after S3 sync succeeds
- `BUILD_FAILED.txt` on any exception

## Fast Triage Commands

Reattach to the active Windows marker poll:

```bash
./scripts/windows-ssm-poll.sh
```

List a completed build:

```bash
aws s3 ls s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/<build-id>/ \
  --recursive --human-readable --summarize --region eu-central-1
```

Inspect Dawn load validation:

```bash
aws s3 cp s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/<build-id>/validation-recovered.json - \
  --region eu-central-1
```

If `webgpu_dawn.dll` fails to load, check the Abseil inline namespace in both
DLLs before rebuilding. The symptom is usually a packaged `abseil_dll.dll`
from one vcpkg tree and `webgpu_dawn.dll` from another.
