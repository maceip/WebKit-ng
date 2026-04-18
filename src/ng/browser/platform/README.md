# Platform Adapters

Platform code implements these interfaces:

- Windows: Win32/WebView host, Windows WebAuthn API or Windows Hello, WebKit
  Windows script-message bridge, Dawn/WebGPU process integration.
- Android: WPE Android UI, Android Credential Manager/FIDO2 provider,
  WebKitUserContentManager bridge, Android storage and lifecycle.
- macOS/iOS: AppKit/UIKit UI, AuthenticationServices/LocalAuthentication,
  WKWebView message handlers, Keychain-backed storage.
- Linux: GTK/WPE UI, libfido2 or future platform passkey provider, WPE/GTK
  message handlers.

The portable core must not include platform headers. If a feature cannot be
implemented without a platform include, add a method here and implement it in the
platform layer.

---
