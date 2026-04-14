# BUILD LAW

## Failure Record

The Windows build work failed the reproducibility standard.

The original Windows artifact was verified as a real build, but it was not accepted as reproducible because the recorded source provenance did not line up:

- the live Windows tree was on upstream `52dbebe20b922cab89928085f9dcfa8082a813e4`
- the handoff metadata referenced `c46301f7ed90925848f626dae58071407d077bd3`
- the user-provided `maceip/WebKit:dawn` branch resolved to `a836cab7bc76bc2c29b298854f84276842470572`
- the live tree contained dirty edits and `.rej` files

After identifying that the build was out of whack, I should have stopped and converted the known state into repo-owned patches before running more builds.

Instead, I ran exploratory build attempts directly on the Windows machine. Those attempts discovered useful blockers, but they recreated the same failure mode: remote-only source and build state that was not yet represented in this repository.

The exploratory attempts are not accepted builds. They must not be treated as release evidence.

Specific failures:

- Remote hotfixes were made before they were captured as ordered patches under `patches/windows`.
- Build attempts used temporary source directories and CMake cache state on the Windows host.
- Several fixes were discovered interactively instead of being introduced through the repo patch pipeline first.
- S3 upload and manifest handling were not enforced as a gate before the exploratory runs.
- The acceptance checks were not run: MiniBrowser launch, right-click `Show Inspector`, and WebGPU/Dawn verification.

The useful information from those failed attempts:

- The previous successful build was likely not a clean rebuild from scratch.
- A clean checkout of full WebKit on Windows can hit long-path failures in `LayoutTests`.
- A sparse checkout can avoid those long-path failures for build-focused work.
- Clean Windows builds expose CRT deprecation warnings in `bmalloc` / `libpas` when warnings are treated as errors.
- The build got past `bmalloc` once `_CRT_SECURE_NO_WARNINGS` was applied at the target level, then later failed around ANGLE/linking.

## Reproducibility Runbook

### Law

No Windows build is accepted unless it can be recreated from:

1. a pinned WebKit commit
2. ordered patches stored in this repository
3. documented dependency inputs
4. a scripted build command
5. uploaded logs, manifest, CMake cache, and artifact hashes

Remote-only edits are not allowed to become part of the build definition.

### Required Inputs

Record these before starting a build:

- WebKit remote URL
- WebKit commit SHA
- patch list and patch SHA-256 values
- Windows instance ID and region
- compiler path and version
- Visual Studio Build Tools path and version
- CMake, Ninja, Ruby, Perl, Git, LLVM, vcpkg paths
- S3 output prefix

### Patch Layout

Windows patches live under `patches/windows` and must be ordered numerically:

- `0001-windows-build-toolchain.patch`
- `0002-windows-vcpkg-overlays.patch`
- `0003-windows-dawn-webgpu.patch`
- `0004-windows-inspector-compat.patch`
- `0005-windows-bmalloc-crt.patch`
- `0006-windows-angle-link.patch`

Names can change, but the rule cannot: each hotfix must be a repo patch before it is used by an accepted build.

### Clean Build Procedure

1. Stop any exploratory build process on the Windows host.
2. Create or clean a dedicated source directory.
3. Checkout the pinned WebKit commit.
4. Enable Windows long paths.
5. Use sparse checkout only if full checkout fails, and record the sparse roots.
6. Apply `patches/common` then `patches/windows` in sorted order.
7. Fail immediately if `git apply` creates `.rej` files.
8. Fail immediately if `git status --porcelain` contains edits not caused by the patch list.
9. Delete the build directory before configure.
10. Configure/build with explicit compiler and dependency paths.
11. Write a manifest before build and after build.
12. Upload manifest, logs, CMake cache, and artifacts to S3.

### Windows Build Gate

The build script must fail unless all of these are true:

- `git rev-parse HEAD` equals the pinned commit
- all patch SHA-256 values match the manifest
- no `.rej` files exist
- `CMakeCache.txt` contains `PORT:STRING=Win`
- `CMakeCache.txt` contains `ENABLE_MINIBROWSER:BOOL=ON`
- `CMakeCache.txt` shows the intended WebGPU/Dawn state
- `MiniBrowser.exe` exists
- `WebKit2.dll`, `WebCore.dll`, and `JavaScriptCore.dll` exist
- artifact SHA-256 values are uploaded
- build logs are uploaded

### Manual Acceptance Gate

After the build completes:

1. Launch MiniBrowser on the Windows host.
2. Load a simple page.
3. Right-click and select `Show Inspector`.
4. Confirm the inspector opens without crashing.
5. Run a WebGPU/Dawn smoke check appropriate for the enabled feature state.
6. Record the result in the build manifest.

### Current Recovery Plan

1. Extract the useful diffs from the exploratory Windows source tree.
2. Split them into ordered `patches/windows/*.patch` files.
3. Update `platforms/windows/build.sh` so it creates a clean source tree from a pinned commit.
4. Make `platforms/windows/build.sh` apply only repo patches.
5. Add manifest generation before and after build.
6. Add hard failure checks for `.rej`, dirty unexpected files, missing CMake settings, and missing artifacts.
7. Rerun Windows build from scratch.
8. If a new compiler/build failure appears, stop, create a new patch in `patches/windows`, then rerun from scratch.
9. Only accept the build after MiniBrowser inspector and WebGPU/Dawn checks pass.

### Prohibited Shortcuts

- Do not patch files on the Windows host without adding the patch to this repo.
- Do not reuse a dirty source tree for acceptance.
- Do not reuse a stale CMake cache for acceptance.
- Do not call an artifact accepted because the binary exists.
- Do not infer WebGPU/Dawn acceptance from configure output alone.
- Do not infer inspector acceptance without launching MiniBrowser and testing `Show Inspector`.
