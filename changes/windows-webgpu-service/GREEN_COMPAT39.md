# Windows WebGPU/Dawn Green Baseline

This is the recovery note for the first green Windows WebGPU/Dawn build.

## Green Build

- Build id: `dawn-api-compat39`
- Date: `2026-04-17`
- Windows instance: `i-05ab9a8ed6d325b3d`
- Region: `eu-west-1`
- Source preset: `iangrunert-win-gigacage-skia-fixes`
- Source repo: `https://github.com/iangrunert/WebKit.git`
- Source commit: `64f58084c78130b874d05dbcfb508147354095af`
- Workdir: `C:/Bootstrap/ng-webkit-dawn-api-compat39`
- Source checkout: `C:/W/nec6421af80557e`
- Result: `[9558/9558]` complete
- Duration: `1h:16m:56s`

## Artifacts

- Runtime/build artifact: `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-api-compat39`
- Green AMI: `ami-0151481223e75e08f`
- Green AMI name: `ng-webkit-win-dawn-green-20260417T124727Z`
- Green snapshot: `snap-0a16085d213ef3607`

The AMI was created after the green build. Check AWS for final AMI state before launching from it.

## Required Lane Settings

Use the canonical wrapper:

```bash
NG_WINDOWS_ENABLE_SCCACHE=1 ./scripts/run-windows-webgpu-dawn.sh <build-id>
```

The wrapper sets:

- `NG_WINDOWS_SOURCE_PRESET=iangrunert-win-gigacage-skia-fixes`
- `NG_WINDOWS_ENABLE_WEBGPU=1`
- `NG_WINDOWS_ENABLE_SCCACHE=1`

The Windows build script currently uses:

- `--makeargs=-j4`
- `-DENABLE_EXPERIMENTAL_FEATURES=ON`
- `-DENABLE_WEBXR=OFF`
- `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`
- `-flto=thin`
- `lld-link`
- stripped Release debug info through `patches/windows/0011-windows-strip-release-debug-info.patch`

## Patch Stack

The green build used all enabled Windows changes from `config/changes.json`, plus root Windows patches.

Change patches:

- `changes/windows-webgpu-service/patches/windows/0001-windows-dawn-request-adapter-runtime.patch`
- `changes/windows-webgpu-service/patches/windows/0002-windows-dawn-webgpu-ext-compat.patch`
- `changes/windows-webgpu-service/patches/windows/0003-windows-dawn-disable-webxr-impl.patch`
- `changes/windows-webgpu-service/patches/windows/0004-windows-dawn-adapter-compat.patch`
- `changes/windows-webgpu-service/patches/windows/0005-windows-dawn-api-compat.patch`
- `changes/windows-webgpu-service/patches/windows/0006-windows-dawn-bind-group-entry-compat.patch`
- `changes/windows-webgpu-service/patches/windows/0007-windows-dawn-bind-group-layout-next-in-chain.patch`
- `changes/windows-webgpu-service/patches/windows/0008-windows-dawn-pipeline-layout-immediate-size.patch`
- `changes/windows-webgpu-service/patches/windows/0009-windows-gate-remote-gpu-model-path.patch`
- `changes/windows-webgpu-service/patches/windows/0010-windows-gate-remote-gpu-proxy-model-path.patch`
- `changes/windows-webgpu-service/patches/windows/0011-windows-gate-remote-gpu-render-buffers.patch`
- `changes/windows-webgpu-service/patches/windows/0012-windows-webchromeclient-include-impl-headers.patch`
- `changes/windows-webgpu-service/patches/windows/0013-windows-include-more-cpp-headers.patch`
- `changes/windows-minibrowser-fluent-tabs/patches/windows/0001-windows-minibrowser-fluent-tabs.patch`
- `changes/windows-minibrowser-fluent-tabs/patches/windows/0002-windows-minibrowser-dialog-material-helper-access.patch`

Root Windows patches:

- `patches/windows/0001-windows-bmalloc-crt.patch`
- `patches/windows/0002-windows-webkitdirs-llvm-ninja.patch`
- `patches/windows/0003-windows-rewrite-compile-commands-pathsep.patch`
- `patches/windows/0004-windows-enable-webgpu-dawn.patch`
- `patches/windows/0005-windows-wgsl-generator-three-args.patch`
- `patches/windows/0006-windows-wgsl-atan2-math-macros.patch`
- `patches/windows/0007-windows-wgslc-iovalidator.patch`
- `patches/windows/0008-windows-clang-format-warning-compat.patch`
- `patches/windows/0009-windows-webgpu-device-unused-helpers.patch`
- `patches/windows/0010-windows-build-webkit-pass-ninja-makeargs.patch`
- `patches/windows/0011-windows-strip-release-debug-info.patch`

Future bundles include `patch-manifest.json` so the exact applied patch list and hashes travel with the build artifacts.

## Known Issue

`sccache` was configured in the green run but did not actually receive compile requests:

```text
Compile requests 0
Cache hits 0
Cache misses 0
```

Do not assume rebuilds are cached until `build.ninja` or sccache stats prove it. The runner now copies `patch-manifest.json` into artifacts and warns if a build requested sccache but recorded zero compile requests.

## Recovery Checklist

1. Prefer launching from AMI `ami-0151481223e75e08f` once AWS reports it available.
2. Use `./scripts/run-windows-webgpu-dawn.sh <new-id>`.
3. Keep `NG_WINDOWS_NINJA_JOBS=4` until memory and linker behavior are proven stable.
4. Keep `ENABLE_WEBXR=OFF`.
5. Verify artifacts contain `patch-manifest.json`, `manifest-pre.json`, `manifest-post.json`, `validation-report.json`, and `ng-webkit-windows-<id>.tar.gz`.
6. Fix sccache as a runner issue before expecting fast turnaround.
