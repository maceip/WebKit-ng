#pragma once

#include "extensions/ExtensionRuntime.h"
#include "tabs/BrowserStateModel.h"
#include "webauthn/WebAuthnController.h"

#include <string>

namespace ng {

class PlatformBrowserUI {
public:
    virtual ~PlatformBrowserUI() = default;
    virtual void renderBrowserState(const std::vector<BrowserWindow>&, const std::vector<BrowserTab>&) = 0;
    virtual Result<void> showExtensionPopup(const ExtensionId&, BrowserWindowId, BrowserTabId) = 0;
    virtual Result<void> showExtensionSidePanel(const ExtensionId&, BrowserWindowId) = 0;
};

class PlatformExtensionBridge {
public:
    virtual ~PlatformExtensionBridge() = default;
    virtual Result<void> injectContentScripts(const ExtensionManifest&, const BrowserTab&) = 0;
    virtual Result<void> sendToBackground(const ExtensionMessage&) = 0;
};

class PlatformStorage {
public:
    virtual ~PlatformStorage() = default;
    virtual Result<std::string> readText(const std::string& key) = 0;
    virtual Result<void> writeText(const std::string& key, const std::string& value) = 0;
};

} // namespace ng

