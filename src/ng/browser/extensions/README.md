# Extensions

This directory owns extension policy and runtime dispatch that can be tested
without WebKit.

Current surface:

- Manifest V3 data model.
- Registry install/uninstall validation.
- Runtime message dispatch keyed by extension and channel.
- Side panel declarations are parsed into the manifest model but intentionally
  have no web-exposed API here yet.

Platform bindings will connect this runtime to WebKit script-message handlers:

- content scripts through `WKUserScript` / `WebKitUserContentManager`
- background service workers or pages through a hidden WebKit view
- `tabs.*` through `BrowserStateModel` and `BrowserCommandController`
- action/popup/side-panel presentation through `PlatformBrowserUI`

---
