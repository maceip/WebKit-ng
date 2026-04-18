# WebGPU on Windows (Dawn / D3D12) — Unified Master Plan

This document **unifies and expands** material from:

- `webgpu-dawn-runbook.md` (operations, DLLs, known-good baselines)
- `changes/windows-webgpu-service/README.md` (lane scope, runtime slices)
- `changes/windows-webgpu-service/DESIGN.md` (architecture choices)
- `changes/windows-webgpu-service/GREEN_COMPAT39.md` (green baseline notes)
- `config/windows-webgpu-dawn-green.json` (preset values)

**Operational commands and runner etiquette** stay in the runbook; this file is the **single program plan** with **phased prescriptions**.

---

## 0. Planning principles (how we phase work)

1. **Prefer fewer, larger phases with a written spec** over many small chunks. Each phase below should have **clear exit criteria**, **scope boundaries**, and **enough design written down** (even a short internal doc) that another engineer can execute or review without oral history. Longer well-specified tranches reduce thrash; tiny unspecified patches are discouraged unless they are **pure** build/DLL fixes.

2. **Ship Dawn Native in-process first (strategy “5”)** until the **product bar** in §1.1 is met: **canvas + `configure` + `getCurrentTexture` + `present` + `requestAnimationFrame`** (e.g. bouncing ball) works reliably on Windows/D3D12 **with `WGPUInstance`/`HWND`/swapchain in one address space**, **or** until stakeholders **prove** that **in-process WebGPU is unacceptable** (security policy, sandbox requirements, perf ceiling—document the decision). **Do not** block the first shipped interactive WebGPU on **GPU-process parity** or on **Dawn Wire**.

3. **Only after** §1.1 is achieved **or** in-process is ruled out, plan a **separate, well-specified phase** for **multi-process WebGPU**: either continue **hand-written `Remote*` + WebKit IPC** (upstream shape) **or** evaluate **Dawn Wire** (strategy “4”) as a **strategic** serializer between processes. That phase is **architectural**—not the same as “finish canvas.”

4. **Optional** conformance (CTS) and **hardening** stay **after** the interactive WebGPU bar unless CTS is used only as a **non-blocking** regression aid.

### 0.5 Gates without bureaucracy (still real gates)

Avoid heavy **contracts**, sprawling **validation frameworks**, or process theater. Each phase still needs a **clear gate**: a **small, self-proving bundle** that answers *“this phase is done—here it is.”* Use a **one-page checklist** in-repo, a **single HTML probe**, a **short JSON** from an **existing** harness, or **one command** that exits 0 and prints the expected lines—**minimum viable proof**. A **machine or human** should verify in **minutes**. If the gate is too elaborate, **nobody will run it** and the plan becomes fiction. **Reuse** runbook patterns (`validation-report.json`, artifact manifests, probe HTML) before inventing a new validation product. Concrete **examples per phase**: **§4.1**.

### 0.6 Coordination: build dashboard and API (required for ng work)

**All lane work** that produces or consumes builds should **flow through** the **runner service** (**`service/src/server.js`**, dashboard **`service/public/index.html`**, default port **8787**) so there is a single **build id**, **log tail**, and **artifact** story. That is how humans and automation **coordinate**—not one-off SSM sessions as the default.

| Practice | Why |
|----------|-----|
| Start Windows WebGPU builds via **`POST /builds`** with **`presets.windows: "webgpu-dawn"`** and a **`reason`** that names **phase + intent** (e.g. `webgpu phase 2: compute readback`). | Searchable history; same entrypoint for everyone. |
| Use **`GET /builds/:id`**, **`GET /builds/:id/logs/windows?tail=…`** to inspect. | No guessing which log file. |
| When a **phase gate** (§4.1) is satisfied, record **`POST /builds/:id/checkpoint`** with a **one-line** note + optional link to commit/artifact. | Handoff without meetings; agents can poll state. |

**Onboarding:** **`WEBGPU_WINDOWS_START_HERE.md`** (this folder) is the **single entry** doc for engineers; it points here and to the runbook. **Do not** duplicate long API docs—use **`RUNNER.md`** and **`service/RUNNER_API.md`**.

**Org-wide build rules:** **`BUILD_AUTOMATION.md`**. **Windows** compliance, **disk headroom**, sccache, reporting: **`platforms/windows/WINDOWS_BUILDER.md`**.

**Growing the product (service/dashboard):** Small, incremental improvements belong in the plan—**§4.2**—so the control plane **improves with each phase** instead of a one-off “big dashboard” project.

---

## 1. Goals (priority order)

1. **Ship WebGPU in MiniBrowser on Windows** using **Dawn** with **`WGPUBackendType_D3D12`** (Dawn is the *library*; D3D12 is the *graphics backend* in the WebGPU C API).

2. **Real-site compatibility (required).** Pages that follow the **W3C WebGPU** API and typical patterns must work: **`navigator.gpu`**, **`requestAdapter` / `requestDevice`**, **canvas `getContext('webgpu')`**, **configure**, **WGSL shaders**, **render passes**, **`queue.submit`**, **`present`**, **`requestAnimationFrame`** loops—enough for **interactive demos** (e.g. a **bouncing ball**), tutorials, and mainstream content that does not rely on exotic optional features.

3. **Keep work reviewable and revertible:** Windows WebGPU service patches isolated under `changes/windows-webgpu-service/` unless a change must live in root `patches/windows/`.

**Explicitly not required for “done”:** **full gpuweb CTS pass rate**, **full conformance certification**, or **commitment to multi-process WebGPU before §1.1**—prefer **Dawn Native in-process (strategy (5))** until **canvas + present + rAF** work or until in-process is **proven unacceptable** (see **§0**, **§3.1**, **Phase 4**).

---

## 1.1 Product acceptance bar (“what must work”)

Treat this as the **definition of success** before worrying about CTS percentages:

| Capability | Required for typical web content |
|------------|----------------------------------|
| **Discovery & device** | `navigator.gpu`, `requestAdapter`, `requestDevice`, limits/features sane for D3D12 |
| **Canvas** | `HTMLCanvasElement` / `GPUCanvasContext`, `configure`, `getCurrentTexture`, aspect ratio / resize |
| **Rendering** | Render pipeline, vertex/index buffers, bind groups, **swapchain present**, depth/stencil as used by common samples |
| **Animation** | Stable **`requestAnimationFrame`** + submit + present each frame (bouncing ball) |
| **WGSL** | Shaders used by real sites and samples compile and run |
| **Errors** | Reasonable behavior for validation errors (sites often check `popErrorScope` / uncaptured error in dev flows) — exact CTS behavior can follow |

**May defer** unless a target site needs them: rare **optional GPU features** (expose only what Dawn/D3D12 and your bindings support), **timestamp queries**, **subgroups**, **importExternalTexture** (video) if not needed for initial demos.

---

## 2. Explicit non-goals and deferrals

| Item | Policy |
|------|--------|
| **WebXR + WebGPU** | **Out of scope.** Stub `createXRBinding` if needed; **`ENABLE_WEBXR=OFF`** in lane unless unrelated work requires it. |
| **Reviving `USE_DAWN` / deleted `WebCore/platform/graphics/gpu/dawn` sources** | **Out of scope.** Active path: `ENABLE_WEBGPU` + `Modules/WebGPU/Implementation` + `FindDawn.cmake` / vcpkg. |
| **“Dawn” as a `WGPUBackendType`** | Invalid — use **D3D12**, Vulkan, etc. |
| **Full gpuweb CTS / “conformance complete”** | **Stretch / lab goal**, not a ship gate. Add CTS runs when they **help regression detection**, not as a blocker for interactive WebGPU. |
| **Remote GPU / Dawn Wire for WebGPU** | **Deferred** until **Phase 4** (see **§3.1**): ship **in-process** first. Upstream WK2 prefers **`RemoteGPUProxy`**, but it is **not** required to hit §1.1 if the lane uses **`createGPUForWebGPU`**’s **in-process** path and CMake flags document that choice. |

---

## 3. Architecture anchors (do not lose these)

1. **GPU process vs in-process (strategic).** Upstream WebKit with **`ENABLE(GPU_PROCESS)`** uses **`RemoteGPUProxy`**; **`GPUImpl`** runs in the **GPU process**, which complicates **Win32 HWND / DXGI** ownership. **Default plan for Windows shipping:** **Dawn Native in-process** for WebGPU (**strategy “5”**) until §1.1 (**canvas + present + rAF**) is met **or** in-process is **proven unacceptable** (see §0). Document the active mode in build/release notes.
2. **WebProcess already has** `WebPage::nativeWindowHandle()` (UINT64 of view `HWND`) when `USE(GRAPHICS_LAYER_TEXTURE_MAPPER) || USE(GRAPHICS_LAYER_WC)` (true on Windows in `OptionsWin.cmake`). Wire this into presentation when implementing canvas.
3. **Canvas context gap:** `GPUCanvasContext::create` returns **`nullptr` on non-Cocoa** (`GPUCanvasContext.cpp`). **`getContext('webgpu')` requires a Windows `GPUCanvasContext`** (parallel to `GPUCanvasContextCocoa`).
4. **Presentation descriptor / IPC:** Today descriptors carry **compositor integration** identity; extend with **HWND / surface** fields when implementing Phase 3. Under **in-process** WebGPU, **minimal** IPC for presentation is expected; a **later** multi-process phase (**strategy “4”** or hand-written `Remote*`) adds full cross-process surface contracts.
5. **Dawn event pumping:** After async entry points, **`wgpuInstanceProcessEvents`** (bounded loop or periodic pump) per existing patches and `README.md`.

---

## 3.1 Dawn deployment: strategy “5” now, strategy “4” only when justified

| Strategy | What it is | When to use |
|----------|------------|-------------|
| **(5) Dawn Native in-process** | **`WGPUInstance`** and **D3D12** work run in the **same process** as the binding/canvas path you enable (typically Web process for first ship). **Dawn’s Win32 surface samples** inform HWND/swapchain wiring. | **Default until** §1.1 works (**canvas + present + rAF** / bouncing ball) **or** until a **documented** decision says in-process is unacceptable. |
| **(4) Dawn Wire + multi-process** | **Wire client** / **Wire server** split with serialized **`webgpu.h`** calls—**conceptually** like Chromium—requires **your** transport on top of WebKit IPC. | **Only after** §1.1 is done **or** in-process is ruled out **early**; requires its **own** spec (transport, validation, mapped buffers, security). Not a prerequisite for first visible WebGPU. |
| **Hand-written `Remote*Proxy`** (upstream) | Existing WebKit **StreamConnection** + object heap—**not** Dawn Wire. | Valid alternative to Wire if you **must** match upstream IPC shapes; same rule: **defer** until §1.1 or policy forces GPU process. |

**Review gate:** Before starting a multi-process/WebGPU phase, answer: *(a)* Is §1.1 green in-process? *(b)* If not, is there a **written** reason to skip in-process? If **(a) yes** or **(b) no**, keep shipping refinements in-process before opening the Wire/Remote redesign.

---

## 4. Phase overview (fewer phases, each well-specified)

| Phase | Name | Summary |
|-------|------|---------|
| **1** | Foundations & reproducible build | **Spec:** toolchain, CMake, vcpkg Dawn, DLL/Abseil pairing, green baseline, artifacts. |
| **2** | Dawn Native **in-process**: API shell + GPU core | **Spec:** `navigator.gpu` → adapter → device → queue + pumping; then buffers, WGSL, pipelines, submit, **compute readback**—all **in-process** for Windows lane unless already disallowed. *Merged former “runtime core” + “off-canvas GPU.”* |
| **3** | Canvas, surface, **present**, **rAF** | **Spec:** `GPUCanvasContext` Win, HWND/surface, compositor, swapchain, **bouncing ball**. Completes §1.1 while staying on **(5)** unless superseded by policy. |
| **4** | *(Conditional)* Multi-process WebGPU — Wire **or** Remote | **Spec-only phase:** GPU process required **and** chosen split (Dawn Wire vs `Remote*`). **Only** after Phase **3** exit **or** explicit early policy trigger (see §3.1). |
| **5** | *(Optional)* Conformance lab | CTS import, harness, baselines, trending—not a ship gate. |
| **6** | Hardening & sustainment | CI on §1.1 smoke, perf, docs; ongoing. |

**Required path to shippable interactive WebGPU:** Phases **1 → 2 → 3**. Phase **4** is **conditional**. Phases **5–6** are **quality / ongoing**.

### 4.1 Minimal gates per phase (examples—not a new toolchain)

Each phase’s **exit criteria** checklists in this document are the **contract**. Proof should be **one** primary artifact where possible, **reusing** the runbook or build outputs. Do **not** require custom DSLs or long review scripts.

| Phase | “Done” should be provable by (pick what fits; keep one bundle) |
|-------|------------------------------------------------------------------|
| **1** | Green build log + `CMakeCache` line + **DLL load** line in existing **`validation-report.json`** (or equivalent single JSON). |
| **2** | **Probe page** or **one** automated test showing adapter → device → queue + **compute readback**; optional small JSON fields if the harness already emits them. |
| **3** | **One HTML file** (checked in or pinned path) that shows **triangle** then **bouncing ball** in MiniBrowser; screenshot optional, not required on day one. |
| **4** | Short **design note** + build runs + **same §1.1 HTML** still passing in the new process model. |
| **5** | **One command** documented that runs a **CTS subset** and writes **one** machine-readable summary (reuse layout-test output if available). |
| **6** | CI or nightly runs **§1.1** smoke; changelog line when baseline moves. |

If a gate grows beyond **~15 minutes** for a new teammate to verify, **simplify** it.

### 4.2 Small dashboard / service increments (per phase—optional but encouraged)

These are **tiny** additions to **`service/`**, **build scripts**, or **validation JSON** so monitoring **scales** with WebGPU maturity. Pick **one** item per phase when capacity allows; **skip** if it blocks feature work. Goal: **no** heavy new products—**extend** existing runner + artifacts.

| Phase | Suggested increment (examples) |
|-------|-------------------------------|
| **1** | Normalize **`reason`** strings (`webgpu phase 1: …`) in **`POST /builds`**; ensure **Windows** build records always show **artifact prefix** + link to **`validation-report.json`** in docs or checkpoint template. |
| **2** | Add **one optional field** to **`validation-report.json.runtime`** (or probe output) when **compute readback** passes, e.g. `computeSmokePassed: true`, **or** document a **fixed checkpoint string** engineers paste into **`POST /checkpoint`**. |
| **3** | Extend probe / validation JSON with **canvas** flags when ready (`canvasConfigured`, `presentedFrame`, etc.—**minimal** booleans); optional **screenshot** path in manifest **later**, not a gate on day one. |
| **4** | When multi-process lands: **`reason`** / checkpoint convention **`webgpu phase 4: wire` vs `remote`**; consider **one** extra field on build record or checkpoint for **process model** (`in-process` / `gpu-process`). |
| **5** | **One documented command** in **`RUNNER.md`** or runbook that runs a **CTS subset** and writes output to a **known path**; optional: **`GET /builds`** filter or tag in **`reason`** for `cts-` runs. |
| **6** | Wire **§1.1** smoke to **nightly** `POST /builds` **or** document alert hook (**`NG_ALERT_WEBHOOK_URL`**) for **failed** validation JSON fields—reuse **`scripts/notify.sh`** patterns from **`RUNNER.md`**. |

Anything larger (full UI redesign, new databases) belongs in **`RUNNER.md` “What is missing”**—not in this lane’s critical path.

---

## 5. Phase 1 — Foundations & reproducible build

**Spec artifact:** pinned preset + `CMakeCache` expectations + runbook pointers; exit checklist below.

### 5.1 Objective

Every developer and every CI worker can produce the **same class of binary**: WebKit + WebGPU + Dawn on Windows, with **matching runtime DLLs** and **documented** green inputs (commit, preset, patch stack).

### 5.2 Prerequisites

- Access to the **Windows build service** / `run-windows-webgpu-dawn.sh` as in the runbook.
- `WebKit-ng` change **`windows-webgpu-service`** enabled plus root **`patches/windows/0004-windows-enable-webgpu-dawn.patch`** (or successor).

### 5.3 Prescription (detailed)

1. **CMake / features**
   - Use **`--webgpu`** and **`-DENABLE_EXPERIMENTAL_FEATURES=ON`** so `ENABLE_WEBGPU` is not lost to Win `PRIVATE` defaults.
   - Keep **`ENABLE_WEBXR=OFF`** for the WebGPU lane unless you have a separate initiative.
2. **vcpkg**
   - Ensure the **`webgpu`** manifest feature pulls **Dawn** consistently with `webkitdirs.pm` / `FeatureList.pm` (see `0004` patch family).
3. **FindDawn**
   - Confirm **`dawn/dawn_proc_table.h`** and library name **`webgpu_dawn`** resolution paths (vcpkg layout).
4. **Runtime DLL packaging**
   - Ship **`webgpu_dawn.dll`** beside **`MiniBrowser.exe`**.
   - Ship **`abseil_dll.dll`** from the **same** vcpkg install tree as Dawn; **ABI mismatch** between Abseil builds is a known failure mode (error 126 on load)—see runbook “Runtime DLL Packaging.”
   - Validate with **`LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)`** in harness; require acceptance JSON fields as in the runbook.
5. **Artifacts**
   - Every green build uploads: logs, manifests, **`validation-report.json`**, probe HTML, archive—**do not** treat compile-only as success (runbook rules).
6. **Baseline record**
   - Update **`config/windows-webgpu-dawn-green.json`** and/or **`GREEN_COMPAT39.md`** when a new green is promoted (build id, commit, AMI, artifact prefix).

### 5.4 Deliverables

- **Green build** record (ninja target count, zero link failures).
- **Validation JSON** proving Dawn DLL load with matching Abseil.
- **Pinned** source preset/commit for reproduction.

### 5.5 Exit criteria

- [ ] `ENABLE_WEBGPU:BOOL=ON` in `CMakeCache.txt`.
- [ ] `webgpu_dawn.dll` loads beside MiniBrowser with **win32 error 0** after Abseil pairing check.
- [ ] Build artifacts and logs stored per runbook.

### 5.6 References

- `WebKit-ng/platforms/windows/webgpu-dawn-runbook.md` — canonical commands, known-good, DLL rules.
- `WebKit-ng/config/windows-webgpu-dawn-green.json`

---

## 6. Phase 2 — Dawn Native **in-process**: API shell + GPU core

**Spec artifact:** one short design note listing: process model (**in-process** for Windows lane), D3D12 backend choice, pumping rules, and the **ordered** checklist (adapter → device → queue → buffers → WGSL → pipelines → compute readback). This phase **merges** the former “runtime core” and “off-canvas GPU” into a **single** well-bounded tranche.

### 6.1 Objective

On the **Windows WebGPU lane**, establish **Dawn Native in-process** (strategy **(5)**) for **`navigator.gpu` → adapter → device → queue** with **event pumping**, then prove **real GPU work**: buffers, textures, **WGSL**, pipelines, command encoders, **queue submit**, and **compute readback**—**before** requiring canvas. **Do not** require **Remote GPU** or **Dawn Wire** to exit this phase.

### 6.2 Prerequisites

- Phase **1** (foundations) exit criteria met.
- Patches through adapter/device/event compat (see `GREEN_COMPAT39.md` / service patches); Dawn API compat (**`0005`–`0008`**) applied or superseded.

### 6.3 Prescription

**Part A — API shell**

1. **Backend:** `WGPURequestAdapterOptions.backendType` → **`WGPUBackendType_D3D12`** where applicable (`DESIGN.md`).
2. **Instance:** Non-Cocoa **`WGPUInstanceDescriptor`** on Windows (`WebGPUCreateImpl.cpp`); no Cocoa-only instance fields required.
3. **Pumping:** Bounded **`wgpuInstanceProcessEvents`** (or equivalent) after **`requestAdapter`** / **`requestDevice`**; document at call sites.
4. **Defaults:** **`requestDevice()`** without a user descriptor succeeds (**`0014`** family).
5. **Process:** Route **`createGPUForWebGPU`** to **in-process** `WebCore::WebGPU::create` for this lane **if** using strategy **(5)**—**document CMake/feature flags** so the lane is reproducible. *(If upstream Remote GPU is still on, restrict to dev builds or follow §3.1 until Phase 4.)*

**Part B — GPU core (off-canvas)**

6. Exercise **`WebGPUDeviceImpl`** / queue / buffer / texture / shader / bind group / pipeline / command buffer paths on **D3D12**.
7. **Order:** compute pipeline → dispatch → **map/readback** before deep render-pass edge cases.
8. **Debug:** validation layers / Dawn debug in Debug builds where feasible.
9. **Canvas:** explicitly **out of scope** for Phase 2 exit—use probes/layout tests only.

### 6.4 Deliverables

- Probe: **`navigator.gpu`**, adapter, device, queue (runbook-level JSON).
- Automated test or probe: **compute readback** with expected values.
- Clustered issue list (mapping, barriers, alignment)—not one-off tickets per test.

### 6.5 Exit criteria

- [ ] Runbook **probe through queue** green; no hang (pumping verified).
- [ ] **End-to-end compute readback** on Windows D3D12.
- [ ] WGSL path stable for test shaders.

### 6.6 Risks

- DLL/Abseil mismatch—revalidate Phase **1** artifacts if runtime fails.
- **API drift** (`WebGPUExt.h` vs vcpkg Dawn)—version compat patches.
- If **in-process** is impossible for policy reasons, **stop** and trigger §3.1 **before** spending months on canvas.

---

## 7. Phase 3 — Canvas, surface, **present**, **`requestAnimationFrame`**

**Spec artifact:** HWND/surface path (Dawn struct names), compositor integration approach for TextureMapper/WC, and **resize**/**device lost** behavior—written before large code dumps.

### 7.1 Objective

Complete **§1.1** while **defaulting to strategy (5)** (same-process **`WGPUInstance`** and **HWND**/swapchain): **`getContext('webgpu')`**, **configure**, **getCurrentTexture**, **render**, **present**, and a stable **`requestAnimationFrame`** loop (**bouncing ball**). **Ship this phase** until the bar is met **or** §3.1 forces multi-process work.

### 7.2 Prerequisites

- Phase **2** exit criteria met **or** documented exception per §3.1.

### 7.3 Prescription

1. **`GPUCanvasContext` for Windows** — `create` for non-Cocoa; mirror **`GPUCanvasContextCocoa`** flow (compositor integration + presentation context).
2. **HWND / surface** — `WebPage::nativeWindowHandle()` → **`GPUPresentationContextDescriptor`** + IPC serialization if still using Remote stubs; **minimal** IPC when **in-process** WebGPU.
3. **`GPUImpl::createPresentationContext`** — **`#if PLATFORM(WIN)`**: **`WGPUSurfaceDescriptorFromWindowsHWND`** (or current Dawn chain); **not** Cocoa custom surface.
4. **`WebGPUCompositorIntegrationImpl`** — Windows path (no IOSurface/Mach); D3D12 / staging / WC as chosen in spec.
5. **Resize / unconfigure / device lost** — spec-reasonable behavior.
6. **Visual ladder:** triangle → steady frame → **bouncy ball** (rAF + submit + present).

### 7.4 Deliverables

- Visible demo (e.g. **`webkit/Websites/`** or ng sample).
- Optional layout pixel read when stable.

### 7.5 Exit criteria

- [ ] **`getContext('webgpu')`** on a normal page.
- [ ] **Triangle** or solid quad **visible**.
- [ ] **`requestAnimationFrame`** + submit + **present** (bouncing ball or equivalent).
- [ ] Resize/tab switch **best-effort** stable.

### 7.6 Risks

- **Cross-process HWND** — if strategy **(5)** is not used, DXGI ownership explodes complexity; **prefer finishing (5)** first (§0, §3.1).

---

## 8. Phase 4 — *(Conditional)* Multi-process WebGPU: **Dawn Wire** vs **hand-written `Remote*`**

**Spec artifact required before coding:** transport choice, security model, mapped-buffer story, and whether you adopt **Dawn Wire (4)** or extend **existing RemoteGPU** IPC. This phase is **large**—treat it as **one** reviewable program, not a stream of small diffs.

### 8.1 Objective

**Only when** §1.1 is met **in-process** **or** a **written** decision requires GPU work out of the Web process **early**: move or align WebGPU execution with **GPU process** policy using either **Dawn Wire** (strategy **(4)**) or **upstream-style `Remote*Proxy`**—not both at once without a migration plan.

### 8.2 Entry triggers

- Phase **3** complete **and** product wants **sandbox** parity with upstream; **or**
- Security/product **mandates** GPU process **before** Phase **3** completes (document **why**).

### 8.3 Prescription (high level)

1. **Decision record:** Wire **vs** hand-written Remote—tradeoffs (Chrome parity vs WebKit IPC fit).
2. **Transport:** How serialized Dawn / objects cross **StreamConnection** (or successor).
3. **Presentation:** Shared textures, cross-process swapchain, or compositor handoff—**must** be designed; raw HWND in GPU process is usually invalid.

### 8.4 Exit criteria

- [ ] **Documented** architecture + **security review** checklist.
- [ ] **Green** §1.1 scenarios in the **chosen** process model.

### 8.5 Risks

- **Months** of integration—**do not** start casually while Phase **3** is red on in-process.

---

## 9. Phase 5 — Conformance lab *(optional stretch)*

**Spec artifact:** CTS revision pin + how to run + baseline format—one doc, not scattered wiki notes.

Treat conformance as **one** optional program with two **sequenced** parts (still **fewer** arbitrary milestones than many tiny tasks).

### 9.1 Part A — Infrastructure

**Objective:** Repeatable **gpuweb CTS** import and **layout-test** (or harness) execution on Windows. **Skip** until §1.1 is met if it distracts from real pages.

**Prerequisites:** Phase **2** minimum; Phase **3** before canvas-heavy CTS shards matter.

**Prescription:** Pin **gpuweb/cts**; **`import-webgpu-cts`** → `LayoutTests/http/tests/webgpu`; wire **`run-webkit-tests`** (or internal runner); store **v0** failure baseline; **TestExpectations** per **cluster**; start with non-canvas subsets, then expand after Phase **3**.

**Exit criteria:** Documented import path + revision; **machine-readable** results every run.

### 9.2 Part B — Depth & trending

**Objective:** Increase CTS pass rate for **regression detection**—**not** a substitute for §1.1.

**Tier definitions:** **A** = 100% of agreed **smoke** list; **B** = high % with skips only for optional features/driver limits; **C** = **B** + canvas coverage or documented skips.

**Prescription:** Fixed shard on a cadence; **cluster** fixes; gate optional features on **`GPUAdapter`/`GPUDevice.features`**; exclude WebXR-heavy tests from scope; bump CTS revision only with **before/after** diff.

**Exit criteria:** Tier **A** protected in CI if you adopt CTS; path to **B** documented.

---

## 10. Phase 6 — Hardening & sustainment

### 10.1 Objective

Keep the lane **maintainable**: **§1.1 demos** stay green, docs current, perf acceptable.

### 10.2 Prescription

1. **CI**
   - **Minimum:** PR / nightly checks that **§1.1** scenarios (probe + **bouncing ball** or equivalent HTML) stay green.
   - **Optional:** larger CTS shards if **Phase 5** is adopted; **Phase 4** (multi-process) has its own regression bar when active.
2. **Regressions**
   - Block merge on **product-bar** failures first; CTS failures are **secondary** unless you have committed to **Phase 5**.
3. **Performance**
   - Track **cold start**, **shader compile cache**, **frame time** on reference hardware.
4. **Docs**
   - On each green baseline promotion: update **`webgpu-dawn-runbook.md`**, **`windows-webgpu-dawn-green.json`**, and **this file’s phase status** (short changelog at bottom).
5. **Security**
   - If using **GPU process** (**Phase 4**), treat the IPC boundary seriously; if **in-process** for WebGPU, still validate **untrusted shader** / resource limits as the rest of WebKit expects.

### 10.3 Exit criteria

- [ ] Owners and **on-call** triage path defined (even if informal).
- [ ] **§1.1** acceptance tests documented and run in CI.
- [ ] If CTS is in use: **no silent** CTS revision bumps.

---

## 11. Living document

- **Owner:** WebGPU Windows / ng lane (update when phases advance).
- **Changelog**
  - *2026-04-18* — Initial unified master plan created from runbook + service docs + phased conformance strategy.
  - *2026-04-18* — Reprioritized: **real-site / §1.1** over full CTS; **Remote GPU** optional; **Phases 4–5** marked optional stretch.
  - *2026-04-18* — **§0** planning principles; **strategy (5) until canvas+present+rAF** or in-process unacceptable; **strategy (4)** deferred to **Phase 4**; **fewer, well-specified phases**; merged runtime+GPU core into **Phase 2**, conformance into **Phase 5** (Parts A/B).
  - *2026-04-18* — **§0.5** gates without bureaucracy; **§4.1** minimal per-phase proof bundles.
  - *2026-04-18* — **`WEBGPU_WINDOWS_START_HERE.md`**; **§0.6** runner dashboard/API coordination; **§4.2** per-phase service increments.

---

## 12. Quick index to existing files

| File | Role |
|------|------|
| `WEBGPU_WINDOWS_START_HERE.md` | **Single entry** for engineers: read order, API curl, Phase 1 first steps |
| `webgpu-dawn-runbook.md` | Commands, DLLs, validation JSON, worker rules |
| `../config/windows-webgpu-dawn-green.json` | Green preset |
| `../../changes/windows-webgpu-service/README.md` | Lane scope, pumping, HWND notes |
| `../../changes/windows-webgpu-service/DESIGN.md` | Backend naming, optional file split sketch |
| `../../changes/windows-webgpu-service/GREEN_COMPAT39.md` | Historical green + patch list |
| `../../scripts/run-windows-webgpu-dawn.sh` | Canonical lane script |
| `../../../webkit/Tools/Scripts/import-webgpu-cts` | CTS → LayoutTests import |
