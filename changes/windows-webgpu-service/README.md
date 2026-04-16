# Windows WebGPU Service Change

This change lane owns the custom Windows WebGPU service work.

See `DESIGN.md` for the Windows Dawn runtime map.

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

Older adapter-only snapshots returned `null` from `requestDevice()`. The in-tree
Windows WebGPU path with `HAVE(WEBGPU_IMPLEMENTATION)` wires Dawn through
`WebGPUAdapterImpl` / `WebGPUDeviceImpl` and pumps instance events so
`requestDevice()` can complete; canvas still needs Win `GPUCanvasContext` plus HWND
in `GPUPresentationContextDescriptor` for full presentation.

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

## Dawn event pumping (Windows)

Dawn may deliver `requestAdapter` / `requestDevice` callbacks asynchronously. WebCore
calls `wgpuInstanceProcessEvents` in a bounded loop after those entry points until the
callback runs (see `WebGPUImpl.cpp` and `WebGPUAdapterImpl.cpp`). If you add new
async WebGPU entry points on Windows, pump the same `WGPUInstance` the same way or
schedule periodic pumping on the UI message loop.

## HWND surface (presentation)

`GPUImpl::createPresentationContext` builds a `WGPUSurface` with
`WGPUSurfaceDescriptorFromWindowsHWND` when `PresentationContextDescriptor` supplies a
non-null `hwnd` (`WebGPUDawnCompat::createSurfaceForWindowsHWND`). Populate
`GPUPresentationContextDescriptor::hwnd` / `hinstance` from the native view when Win
canvas integration is wired. Until `GPUCanvasContext::create` is implemented for
Windows (`GPUCanvasContext.cpp` still returns `nullptr` on non-Cocoa), end-to-end
canvas WebGPU uses harness code or tests that fill those handles explicitly.

## Acceptance

The build is not accepted from compile success alone. Minimum lane checks:

- `ENABLE_WEBGPU:BOOL=ON` in `CMakeCache.txt`.
- Dawn DLLs present and loadable beside MiniBrowser.
- MiniBrowser launches.
- Runtime probe reports `navigator.gpu === true`.
- Runtime probe reports a non-null adapter from `navigator.gpu.requestAdapter()`.
- Manifest and validation artifacts uploaded by the standard Windows harness.

Extended ladder toward a rendered frame (“ball on screen”):

1. Non-null adapter (above).
2. `adapter.requestDevice()` resolves (pumping covers async device callbacks).
3. Swap chain / surface: non-null `hwnd` path + `PresentationContextImpl::configure`.
4. Queue submit + `present` without validation errors.
5. Optional: Win `GPUCanvasContext` so pages can call `getContext("webgpu")` without a custom harness.
