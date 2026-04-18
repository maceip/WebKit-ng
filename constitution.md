# ng-webkit Constitution

This repository exists to carry browser product work across WebKit ports without
turning platform source trees or MiniBrowser experiments into the source of
truth.

## Security-Critical Work

Passkeys, WebAuthn, credential storage, sync, extension privileges, and browser
identity state are security-critical. Code in these areas must be reviewable as
small, explicit contracts with testable behavior and narrow platform authority.

## Quality Bar

- Portable policy lives in portable C++17 code.
- Platform code only performs platform operations: OS authenticator calls,
  native UI presentation, WebKit message bridging, storage backends, networking,
  and process boundaries.
- No platform implementation may silently invent browser policy.
- No security decision may depend on UI text, stringly typed command names, or a
  WebKit port-specific side effect.
- Every privileged request must preserve origin, top-level origin, frame
  context, user activation state, and caller identity where the platform can
  provide them.
- Every permission decision must have a deterministic owner and an auditable
  input record.
- Secrets and credential material must be represented as bounded byte buffers,
  not logs, strings, or generic JSON blobs.
- Error handling must be explicit. Security-sensitive APIs return typed failure
  states; they do not collapse failures into `false`, `null`, or empty strings
  unless the web contract requires that exact observable result.
- Platform adapters are replaceable. Windows, Android, macOS, iOS, and Linux can
  all implement the same contract without changing portable policy.
- A partial implementation must fail closed. Unsupported APIs expose an explicit
  unsupported result instead of pretending to succeed.
- Tests for portable policy run without WebKit, Win32, AppKit, UIKit, Android,
  WPE, or browser UI.
- Build artifacts are not proof. Accepted work is represented in this repo as
  source, patches, scripts, manifests, docs, and reproducible build records.

## WebAuthn And Passkeys

- The portable WebAuthn controller owns request validation, request identity,
  ceremony state, timeout policy, and result mapping.
- Platform authenticator providers own only native authenticator operations:
  Windows Hello/WebAuthn API, Android Credential Manager/FIDO2, Apple
  AuthenticationServices/LocalAuthentication, Linux/libfido2 or future provider.
- The UI layer may collect user consent and display account choices, but it must
  not mutate relying party ID, challenge, allow/exclude credentials, resident key
  policy, user verification policy, or authenticator attachment policy.
- Credential sync must not bypass platform authenticator security. Sync moves
  encrypted browser state according to explicit policy; it does not grant an
  origin credential access path by itself.

## Extensions

- Extension manifest parsing and permission modeling live in portable code.
- WebKit script-message handlers are transport adapters, not policy engines.
- Unsupported extension APIs are tracked as parsed manifest declarations and
  explicit runtime unsupported responses.
- Side panel, popup, action, and options UI are browser surfaces. The extension
  runtime may route requests to them, but platform UI owns presentation.

## Tabs And Browser State

- The browser state model is portable and UI-neutral.
- Horizontal tabs, vertical tabs, tab groups, selection, movement, discard state,
  and window membership are state operations, not platform UI code.
- Platform UI renders browser state and sends commands back through the command
  controller.

## Sync

- Sync server and client code must be portable and isolated from Chromium.
- Protocol and type compatibility may be copied where legally and technically
  appropriate, but Chromium process, profile, and service dependencies are not
  allowed in the portable core.
- A browser instance may act as a local loopback sync server, a client, or both.
  Those modes must share the same typed transport contract.

---
