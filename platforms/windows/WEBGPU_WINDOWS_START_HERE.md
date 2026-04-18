# WebGPU on Windows — Start here (one page)

For **engineers** joining the Windows **Dawn / D3D12** WebGPU lane. Read this first, then the linked docs.

---

## 1. Read in this order

| Order | Document | Why |
|-------|----------|-----|
| 1 | **`WEBGPU_WINDOWS_DAWN_MASTER_PLAN.md`** (same folder) | Phases, gates, **§0.6** coordination, **§4.2** dashboard increments, in-process-first strategy. |
| 2 | **`webgpu-dawn-runbook.md`** (same folder) | Canonical commands, DLL rules, known-good pointers, validation JSON. |
| 3 | **`../../changes/windows-webgpu-service/README.md`** | Lane scope, patches, pumping, HWND notes. |

Optional: **`../../RUNNER.md`** and **`../../service/RUNNER_API.md`** — how builds are started and monitored.

---

## 2. Coordinate work through the build dashboard / API

**Do not** run ad-hoc remote builds as the primary workflow. Use the **runner service** so everyone sees the same **build id**, **logs**, and **artifacts**.

**Implementation (already in-repo):** HTTP server is **`WebKit-ng/service/src/server.js`** (Node). The HTML UI is served from **`service/public/index.html`** (`GET /`); API routes (`/builds`, `/meta`, …) are defined in the same file. Port defaults to **8787** (`PORT` env override).

- **Dashboard:** `GET http://localhost:8787/` (start the service from `WebKit-ng/service/` per **`RUNNER.md`**).
- **Start Windows WebGPU/Dawn lane:**

```bash
curl -X POST http://localhost:8787/builds \
  -H 'content-type: application/json' \
  -d '{
    "platforms": ["windows"],
    "reason": "webgpu phase <N>: <short description>",
    "presets": { "windows": "webgpu-dawn" }
  }'
```

- **List / inspect:** `GET /builds`, `GET /builds/<id>`, `GET /builds/<id>/logs/windows?tail=400`.
- **Checkpoint note** (phase handoff, what was verified): `POST /builds/<id>/checkpoint` — use when a **phase gate** in the master plan is satisfied so the record is **in the service**, not only in chat.

See **`../../RUNNER.md`** for the full endpoint list and pipeline diagram.

---

## 3. First actions (Phase 1 — foundations)

1. Confirm you can start a build with the **`webgpu-dawn`** preset (command above).
2. Confirm **`ENABLE_WEBGPU`** / experimental-features story matches the **runbook** (not raw `-DENABLE_WEBGPU` alone on Windows).
3. Confirm artifacts include **`validation-report.json`** and Dawn DLL load fields per runbook.
4. When green, add a **checkpoint** on that build id noting **“Phase 1 gate met”** and point to commit / preset.

Then open **Phase 2** in the master plan (**§6**): in-process Dawn, adapter → device → compute readback.

---

## 4. Quick links

| What | Where |
|------|--------|
| Master plan | `WebKit-ng/platforms/windows/WEBGPU_WINDOWS_DAWN_MASTER_PLAN.md` |
| Runbook | `WebKit-ng/platforms/windows/webgpu-dawn-runbook.md` |
| Green preset JSON | `WebKit-ng/config/windows-webgpu-dawn-green.json` |
| Wrapper script | `WebKit-ng/scripts/run-windows-webgpu-dawn.sh` |
| Runner entry | `WebKit-ng/RUNNER.md` |
| API contract | `WebKit-ng/service/RUNNER_API.md` |
| Server implementation | `WebKit-ng/service/src/server.js` |
| Build automation (policy) | `WebKit-ng/BUILD_AUTOMATION.md` |
| Windows builder (compliance, disk, cache) | `WebKit-ng/platforms/windows/WINDOWS_BUILDER.md` |

---

## 5. Who to tell when stuck

Use the **reason** field and **checkpoints** so the next person (or an agent) can see **which phase** failed and **which log** to read—avoid “it broke” without a **build id**.
