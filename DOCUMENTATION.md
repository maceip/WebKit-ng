# WebKit-ng — program

**Prescriptive only:** priorities, Windows WebGPU **milestones**, and **gates**.  
**Not here:** S3 layout, build law, runner APIs, patch lists, verification detail—those stay in the linked files so this file stays short.

---

## Where the rest lives (process and data)

| Topic | File |
|------|------|
| Repo overview, downloads | `README.md` |
| Artifacts / S3 prefixes | `ASSETS.md` |
| Build policy & law | `BUILD_LAW.md`, `BUILD_AUTOMATION.md` |
| Runner & dashboard API | `RUNNER.md`, `service/RUNNER_API.md` |
| Windows host (disk, sccache, SSM) | `platforms/windows/WINDOWS_BUILDER.md` |
| Windows WebGPU commands & baselines | `platforms/windows/webgpu-dawn-runbook.md` |
| WebGPU lane scope & patches | `changes/windows-webgpu-service/README.md` |
| Green baseline record | `changes/windows-webgpu-service/GREEN_COMPAT39.md` |
| Dawn/runtime architecture | `changes/windows-webgpu-service/DESIGN.md` |
| macOS lane notes | `platforms/macos/notes.md` |

---

## WebGPU on Windows — strategy

1. **Ship Dawn in-process** with **D3D12** (`WGPUBackendType_D3D12`). Stay on this path until **canvas + present + `requestAnimationFrame`** works for real pages **or** a **written** decision blocks in-process.
2. **Do not** require GPU-process parity, Dawn Wire, or full CTS to ship interactive WebGPU.
3. **Coordinate** through the runner: `POST /builds`, checkpoints, preset `webgpu-dawn`. Default service port **8787**.

### Product bar (what “done” means for typical web content)

`navigator.gpu`, adapter, device, WGSL, canvas `getContext('webgpu')`, configure, render, **present**, stable **rAF** loop. Optional GPU features and full CTS are **not** required for that bar.

### Milestones (use these names in `reason` / checkpoints)

| # | Milestone | Exit (must all be true) |
|---|-----------|-------------------------|
| **1** | Foundations | `ENABLE_WEBGPU=ON` in cache; `webgpu_dawn.dll` loads beside MiniBrowser with Abseil match (load error 0); validation JSON + artifacts per runbook. |
| **2** | API shell + GPU core | Probe through **queue**; pumping verified (no hang); **compute readback** end-to-end on D3D12; WGSL stable for test shaders. **Canvas not required** to exit this milestone. |
| **3** | Canvas + present + rAF | `getContext('webgpu')`, HWND/surface path, visible frame (e.g. triangle / ball). |
| **4** | Multi-process WebGPU | **Only if** policy demands GPU process after milestone 3—Wire vs hand-written Remote; separate spec. |
| **5–6** | CTS lab / sustainment | Optional regression lab; then CI on product-bar smoke. |

### Out of scope for the lane (unless separate work)

- WebXR + WebGPU (`ENABLE_WEBXR=OFF` unless needed elsewhere).
- Reviving deleted `USE_DAWN` / old `platform/graphics/gpu/dawn` sources.
- “Conformance complete” as a ship gate.

---

## Entry

- **`platforms/windows/WEBGPU_WINDOWS_START_HERE.md`** — short index (points here + runbook + runner).
- **`platforms/windows/WEBGPU_WINDOWS_DAWN_MASTER_PLAN.md`** — legacy path; redirects conceptually to this file (no parallel essay).

---

## Editing rule

Change **strategy / milestones** here. Change **operations** in the table above, not in this section.
