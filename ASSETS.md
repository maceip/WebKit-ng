# Assets

All build artifacts live in a single S3 bucket, partitioned by platform and
build id.

## S3 bucket

- **Name**: `cory-build-artifacts-euc1-095713295645-20260407`
- **Region**: `eu-central-1`
- **Account**: `095713295645`
- **Host**: `cory-build-artifacts-euc1-095713295645-20260407.s3.eu-central-1.amazonaws.com`

> Note the bucket name says `euc1` but the region is `eu-central-1`. Always
> use `--region eu-central-1` with the AWS CLI or you will get a
> `PermanentRedirect` error.

## Prefix layout

```
s3://<bucket>/
└── ng-webkit/
    ├── android/<build-id>/
    │   ├── *.apk                    (MiniBrowser, WebDriver, media player)
    │   ├── *.aar                    (WPEView library)
    │   └── wpewebkit-android-*.tar.xz
    ├── windows/<build-id>/
    │   ├── input/
    │   │   └── windows-patches-<build-id>.tar.gz   (bundle uploaded by driver)
    │   ├── ng-webkit-windows-<build-id>.tar.gz     (bin/ directory, ~510 MB)
    │   ├── build-webkit-<build-id>.log
    │   ├── manifest-pre.json
    │   └── manifest-post.json
    └── macos/<build-id>/
        ├── input/
        │   └── macos-patches-<build-id>.tar.gz
        ├── build-webkit-<build-id>.log
        └── ng-webkit-macos-<build-id>.tar.gz       (when the build completes)
```

## Key current artifacts

### Windows — WebGPU + Dawn enabled (canonical)

- `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/ng-webkit-windows-dawn-d3d12-runtime-20260416T011849Z.tar.gz`
- 537.0 MiB, contains the `bin/` directory after WebGPU/Dawn runtime DLL
  packaging.
- `ENABLE_WEBGPU:BOOL=ON` in CMakeCache, Dawn resolved via vcpkg.
- `validation-recovered.json` records `webgpu_dawn.dll` loading successfully
  after packaging the Abseil DLL that matches Dawn's `lts_20260107` ABI.

### Windows — baseline (no WebGPU)

- `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/fix-stderr2-20260415T110839Z/ng-webkit-windows-fix-stderr2-20260415T110839Z.tar.gz`
- 510.8 MB

### Android — current debug build

- `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/android/20260414T050928-81903/`
  - `minibrowser-arm64-v8a-debug.apk` 106 MB
  - `minibrowser-x86_64-debug.apk` 22 MB
  - `wpewebkit-android-arm64-2.51.91.tar.xz` 285 MB (full runtime tree)
  - `wpewebkit-android-arm64-2.51.91-runtime.tar.xz` 56 MB (stripped runtime)
  - `wpeview-debug.aar` 85 MB (WPEView Android library)
  - `mediaplayer-debug.apk`, `webdriver-debug.apk`

### macOS

No successful artifact yet. Build failures are retained for post-mortem:

- `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/macos/macos-20260415T125117Z/build-webkit-macos-20260415T125117Z.log`
- `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/macos/macos-clean-20260415T151654Z/build-webkit-macos-clean-20260415T151654Z.log`

## Downloading

```bash
# List everything in a build
aws s3 ls s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/ \
  --region eu-central-1

# Download the tar.gz
aws s3 cp s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/ng-webkit-windows-dawn-d3d12-runtime-20260416T011849Z.tar.gz \
  . --region eu-central-1

# Generate a 7-day presigned URL for someone who does not have credentials
aws s3 presign s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/ng-webkit-windows-dawn-d3d12-runtime-20260416T011849Z.tar.gz \
  --region eu-central-1 --expires-in 604800
```

## Environment overrides

The build scripts derive S3 prefixes from these environment variables, so a
custom bucket or prefix can be used without code changes:

- `NG_ARTIFACT_BUCKET` — default
  `s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit`
- `NG_ARTIFACT_UPLOAD_REGION` — passed to `aws s3 cp` for uploads (defaults to
  `eu-central-1` for this bucket; set empty to omit `--region`). Aligns with the
  Windows bootstrap download of the patch bundle.
- `NG_WINDOWS_ARTIFACT_S3` — full prefix override for Windows
- `NG_MACOS_ARTIFACT_S3` — full prefix override for macOS

---
