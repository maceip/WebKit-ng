# ng Browser Shell Plan

This document is the source note for the browser product layer so the tab,
extension, WebAuthn/passkey, and sync work does not get lost in MiniBrowser or
temporary WebKit build work.

## Decision

MiniBrowser is a bring-up and demo host. It is useful for proving WebKit builds,
WebGPU runtime probes, and small Windows/macOS UI experiments, but it is not the
long-term browser shell and it must not own product semantics.

The long-term shell is split into:

- portable C++17 browser core under `src/ng/browser`
- platform UI shells for Windows, Android/WPE, macOS, iOS, and Linux
- WebKit patches under `changes/` only when WebKit itself must change

## Portable Core

The portable core owns state, policy, and typed contracts:

- `tabs/`: `BrowserStateModel` and `BrowserCommandController`
- `extensions/`: Manifest V3 model, registry, and runtime message dispatch
- `webauthn/`: ceremony validation, request identity, timeout, and result mapping
- `sync/`: Chromium-shaped loopback sync server/client and wire adapter
- `platform/`: narrow interfaces implemented by each platform

Files in this tree must remain buildable without WebKit, Win32, AppKit, UIKit,
Android, WPE, GTK, or Linux desktop toolkit headers.

## Platform Shells

Platform shells render state and perform platform operations. They do not invent
browser policy.

- Windows: product shell, Win32/WinUI/Windows App SDK decisions, WebKit Windows
  hosting, Windows WebAuthn API or Windows Hello, Dawn/WebGPU service hooks.
- Android: WPE Android shell, Android lifecycle, Credential Manager/FIDO2,
  WebKitUserContentManager bridge.
- macOS/iOS: AppKit/UIKit shell, WKWebView handlers,
  AuthenticationServices/LocalAuthentication, Keychain-backed storage.
- Linux: GTK/WPE shell, libfido2 or future passkey provider, WPE/GTK handlers.

Each shell talks to the portable core through explicit adapters.

## MiniBrowser Role

MiniBrowser may temporarily host:

- Windows Fluent/Mica tab demos
- WebGPU Dawn smoke probes
- early tab model integration
- platform-specific experiments that are too small to justify a product shell

Any MiniBrowser code that becomes product policy must move back into
`src/ng/browser`. MiniBrowser-specific patches stay in `changes/` and should be
treated as disposable scaffolding.

## Tabs

Tab/window state is portable. Horizontal tabs, vertical tabs, selected tab,
window membership, tab movement, pinned ordering, attention state, discard
state, and future tab groups belong in `BrowserStateModel`.

Platform UI renders horizontal or vertical tabs from the same state and sends
user actions through `BrowserCommandController`.

## Extensions

The extension shim is split into policy and transport:

- portable policy: manifest parsing, permission model, registry, runtime
  dispatch, unsupported API responses
- WebKit transport: content script injection, script-message bridge, background
  page or worker host, storage backend, tabs/window adapter
- platform UI: action buttons, popups, options pages, side panel surfaces,
  permission prompts, extension manager

Side panel declarations are parsed, but the web-exposed side panel API is not a
first adapter target. UI support can be added after tabs and extension action
surfaces are stable.

## WebAuthn And Passkeys

WebAuthn/passkeys are security-critical. The portable controller owns request
validation, relying party identity, challenge and timeout policy, user activation
checks, ceremony state, and result mapping.

Platform providers own only native authenticator operations:

- Windows WebAuthn API / Windows Hello
- Android Credential Manager or FIDO2
- Apple AuthenticationServices / LocalAuthentication
- Linux libfido2 or future provider

UI may collect consent and present account choices. It must not mutate relying
party ID, challenge, allow/exclude credential lists, resident-key policy, user
verification policy, or authenticator attachment policy.

## Sync

Sync is portable and isolated from Chromium process/profile/service code. The
repo keeps Chromium loopback sync source and `.proto` files under
`third_party/chromium_sync_loopback` as protocol reference material.

The ng implementation owns:

- `LoopbackSyncServer`: in-process server behavior
- `LoopbackSyncClient`: local client state and commit/get-updates flow
- `LoopbackSyncRpcService`: Chromium-shaped `/command` boundary
- `ChromiumSyncWireAdapter`: generated-protobuf wire adapter

A browser instance may be a local loopback sync server, a client, or both. Those
modes share the same typed transport contract.

## Current Rule Of Thumb

If a change answers "what should the browser do?", it belongs in
`src/ng/browser`. If it answers "how does this platform display or perform that
operation?", it belongs in a platform shell or adapter. If WebKit itself cannot
provide the needed hook, the patch belongs under `changes/`.

---
