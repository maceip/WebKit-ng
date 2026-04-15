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
