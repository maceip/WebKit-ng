#pragma once

#include "core/Origin.h"
#include "core/Result.h"
#include "extensions/ExtensionRegistry.h"
#include "tabs/BrowserCommandController.h"

#include <functional>
#include <map>

namespace ng {

enum class ExtensionMessageTarget {
    Background,
    ContentScript,
    Browser,
};

struct ExtensionMessage {
    ExtensionId extensionId;
    ExtensionMessageTarget target { ExtensionMessageTarget::Background };
    FrameContext frame;
    std::string channel;
    std::string payload;
};

struct ExtensionMessageResponse {
    std::string payload;
};

using ExtensionMessageHandler = std::function<Result<ExtensionMessageResponse>(const ExtensionMessage&)>;

class ExtensionRuntime {
public:
    ExtensionRuntime(const ExtensionRegistry&, BrowserCommandController&);

    Result<void> registerHandler(ExtensionId, std::string channel, ExtensionMessageHandler);
    Result<ExtensionMessageResponse> dispatch(const ExtensionMessage&) const;

private:
    std::string keyFor(const ExtensionId&, const std::string&) const;

    const ExtensionRegistry& m_registry;
    BrowserCommandController& m_browserCommands;
    std::map<std::string, ExtensionMessageHandler> m_handlers;
};

} // namespace ng

