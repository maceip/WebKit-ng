# Windows WebGPU Service Change

This change lane owns the custom Windows WebGPU service work.

The Windows build can compile with WebGPU/Dawn enabled, but runtime acceptance
requires a service/process path that makes WebGPU usable from MiniBrowser. Keep
that work isolated here so it can be enabled, disabled, reviewed, and reverted
separately from generic Windows build fixes.

## Scope

Allowed here:

- Windows-only WebKit patches required for the WebGPU service.
- Cross-platform WebKit interface patches only when they are required by the
  service boundary.
- Runtime validation changes that prove `navigator.gpu.requestAdapter()`
  succeeds.

## Source Preset

For this lane, use the Windows memory/Gigacage/Skia fixes branch as the source
baseline:

```bash
NG_WINDOWS_SOURCE_PRESET=iangrunert-win-gigacage-skia-fixes \
NG_WINDOWS_ENABLE_WEBGPU=1 \
./scripts/run-build.sh windows <build-id>
```

The preset currently resolves to:

```text
https://github.com/iangrunert/WebKit.git
64f58084c78130b874d05dbcfb508147354095af
```

Override `NG_WINDOWS_WEBKIT_URL` or `NG_WINDOWS_WEBKIT_COMMIT` only when testing
a newer explicit commit.

## Dawn CMake Note

Do not use `USE_DAWN` as the Windows WebGPU switch. In current WebKit, the only
remaining Windows reference is a stale `PlatformWin.cmake` hook into
`Source/WebCore/platform/graphics/gpu/dawn`, whose sources are no longer present.
The active path for this lane is `ENABLE_WEBGPU=ON`, Dawn resolution through
`FindDawn.cmake`, and runtime fixes in `Modules/WebGPU/Implementation`.

## First Runtime Slice

`patches/windows/0001-windows-dawn-request-adapter-runtime.patch` wires a
Windows-only `navigator.gpu` backing directly in WebCore. It deliberately avoids
turning on `HAVE_WEBGPU_IMPLEMENTATION` for Windows, because that switch pulls in
the current Cocoa GPU-process and presentation stack. The slice loads
`webgpu_dawn.dll` at runtime, creates a Dawn instance, and resolves
`requestAdapter()` only when Dawn returns a real adapter.

This is intentionally adapter-only. `requestDevice()` still returns `null`;
canvas presentation and GPU-process remoting remain separate follow-up surfaces.

Not allowed here:

- Auth/passkey work.
- Extension shim work.
- Generic Windows compiler or dependency fixes that belong in `patches/windows`.
- Remote-only hotfixes on the Windows builder.

## Patch Layout

```text
changes/windows-webgpu-service/patches/common
changes/windows-webgpu-service/patches/windows
```

Keep patch numbering ordered within each directory.

## Acceptance

The build is not accepted from compile success alone. It needs:

- `ENABLE_WEBGPU:BOOL=ON` in `CMakeCache.txt`.
- Dawn DLLs present and loadable beside MiniBrowser.
- MiniBrowser launches.
- Runtime probe reports `navigator.gpu === true`.
- Runtime probe reports a non-null adapter from `navigator.gpu.requestAdapter()`.
- Manifest and validation artifacts uploaded by the standard Windows harness.
