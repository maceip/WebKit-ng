# Windows Dawn WebGPU Runtime Design

This lane provides the ng-owned Windows WebGPU runtime path. The goal is not to
revive the stale `USE_DAWN` WebCore platform hook. The active integration point
is `ENABLE_WEBGPU=ON` plus a Windows-specific backend implementation under
`Source/WebCore/Modules/WebGPU/Implementation`.

## Backend Naming

Do not add `WGPUBackendType_Dawn` to WebKit's copied `WebGPU.h`.

`WGPUBackendType` describes graphics backends exposed by the WebGPU native ABI:
`D3D12`, `D3D11`, `Vulkan`, `Metal`, `OpenGL`, `OpenGLES`, `Null`, and
`Undefined`. Dawn is the implementation library/provider, not the graphics
backend. On Windows, the ng default should be:

```cpp
WGPUBackendType_D3D12
```

If we need a repo-owned selector, keep it outside the WGPU ABI:

```cpp
enum class NGWebGPUProvider {
    AppleWebGPU,
    Dawn,
};

enum class NGWebGPUBackend {
    Default,
    D3D12,
    Vulkan,
    D3D11,
    Null,
};
```

The selector maps to the real WGPU enum only at the request-adapter boundary.

## Integration Shape

Keep Apple's Cocoa/Metal `GPUImpl` intact for Cocoa. Add a Windows-only Dawn
implementation beside it:

```text
Source/WebCore/Modules/WebGPU/Implementation/
  WebGPUImpl.cpp                 Apple/Cocoa implementation
  WebGPUCreateImpl.cpp           Apple/Cocoa creation path
  WebGPUWindowsDawnGPU.{h,cpp}   ng Windows Dawn GPU object
  WebGPUWindowsDawnAdapter.{h,cpp}
  WebGPUWindowsDawnDevice.{h,cpp}
```

`Navigator::gpu()` becomes the first platform switch:

```cpp
#if PLATFORM(WIN) && ENABLE(WEBGPU)
    m_gpuForWebGPU = GPU::create(WebGPU::WindowsDawnGPU::create(...));
#elif HAVE(WEBGPU_IMPLEMENTATION)
    m_gpuForWebGPU = GPU::create(page->chrome().createGPUForWebGPU());
#endif
```

This avoids forcing non-Cocoa builds through `WebGPUCreateImpl.cpp`, which still
constructs Cocoa descriptors and requests Metal.

## Windows Dawn GPU

`WindowsDawnGPU` owns the Dawn instance and implements the `WebCore::WebGPU::GPU`
interface.

Responsibilities:

- Load or link `webgpu_dawn.dll`.
- Create one `WGPUInstance`.
- Resolve the backend selector to `WGPUBackendType_D3D12` by default.
- Implement `requestAdapter()` using a real `WGPURequestAdapterOptions`.
- Pump Dawn events if the callback is asynchronous.
- Return a real adapter wrapper or `nullptr`, never a partially initialized
  adapter.

Request-adapter shape:

```cpp
WGPURequestAdapterOptions options {
    .compatibleSurface = nullptr,
    .powerPreference = WGPUPowerPreference_HighPerformance,
    .backendType = WGPUBackendType_D3D12,
    .forceFallbackAdapter = false,
};

wgpuInstanceRequestAdapter(instance, &options, callback, userdata);
```

For bring-up only, `backendType = WGPUBackendType_Undefined` is acceptable if
Dawn's installed headers or runtime reject explicit D3D12. The acceptance target
remains a hardware D3D12 adapter.

## Adapter And Device

`WindowsDawnAdapter` should hold a `WGPUAdapter` and expose real properties,
features, and limits from Dawn. The first patch may hardcode minimum limits only
to prove `requestAdapter()` and JS visibility, but that is not shippable.

Next step after adapter:

```text
WindowsDawnAdapter::requestDevice()
  -> wgpuAdapterRequestDevice()
  -> WindowsDawnDevice
```

`WindowsDawnDevice` then becomes the owner/root for queue, buffers, textures,
samplers, shader modules, bind groups, command encoders, and pipelines. The
existing WebKit wrapper interfaces can be mirrored, but the backing handles must
be Dawn handles, not Cocoa WebGPU handles.

## Surface Path

Adapter-only validation proves:

```js
!!navigator.gpu
await navigator.gpu.requestAdapter()
```

Canvas presentation is a separate milestone. The Windows path needs a real
surface descriptor:

```cpp
WGPUSurfaceDescriptorFromWindowsHWND
```

That requires a WebCore/WebKit path from canvas/compositor state to an `HWND` or
another presentable native surface owned by the Windows port. Do not fake this in
`createPresentationContext()`. Return `nullptr` until a real surface contract is
implemented.

## Build Wiring

The active build switches are:

```bash
NG_WINDOWS_ENABLE_WEBGPU=1
NG_WINDOWS_SOURCE_PRESET=iangrunert-win-gigacage-skia-fixes
```

CMake requirements:

- `ENABLE_WEBGPU:BOOL=ON`
- `FindDawn.cmake` resolves vcpkg `webgpu_dawn`.
- `webgpu_dawn.dll` is present beside `MiniBrowser.exe`.
- Windows-only Dawn source files are appended from `PlatformWin.cmake` when
  `ENABLE_WEBGPU` is on.

Do not use `USE_DAWN`; it points at deleted WebCore Dawn sources.

## Acceptance Ladder

1. `navigator.gpu` exists.
2. `navigator.gpu.requestAdapter()` returns non-null.
3. Adapter info/features/limits come from Dawn, not hardcoded minimums.
4. `adapter.requestDevice()` returns non-null.
5. Device queue, buffer, shader-module, and command-encoder smoke tests pass.
6. Canvas `getContext("webgpu")` creates a presentation context.
7. A minimal rendered frame presents through the Windows compositor path.

Each rung needs a build artifact and runtime probe in the standard Windows
harness.

---
