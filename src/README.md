# ng Browser Source

`src/ng/browser` is the repo-owned browser product layer. It is intentionally
outside the WebKit source tree and outside MiniBrowser so the same contracts can
be used by Windows, Android/WPE, macOS, iOS, and Linux.

## Boundary

Portable C++17 lives here:

- tab/window state and browser commands
- extension registry, manifest model, runtime dispatch
- WebAuthn/passkey request controller interfaces
- sync loopback transport and state contracts

Platform adapters live here only as interfaces. Implementations may sit beside
the platform application or downstream WebKit port, but they must implement the
same narrow contracts.

WebKit patches still live under `changes/` when WebKit itself needs to be
changed. The portable code here should remain buildable without WebKit headers.

## Layout

```text
src/ng/browser/
  CMakeLists.txt
  core/             shared types and result handling
  tabs/             portable tab/window model and command controller
  extensions/       manifest model, registry, runtime dispatcher
  webauthn/         passkey/WebAuthn controller and ceremony contracts
  sync/             loopback sync protocol and transport contracts
  platform/         adapter interfaces implemented by each platform
```

## Rule

If a file in this tree needs a Win32, AppKit, UIKit, Android, WPE, GTK, or
WebKit include, it belongs behind a platform adapter instead.

---
