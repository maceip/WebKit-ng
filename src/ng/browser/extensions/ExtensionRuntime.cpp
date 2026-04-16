#include "extensions/ExtensionRuntime.h"

namespace ng {

ExtensionRuntime::ExtensionRuntime(const ExtensionRegistry& registry, BrowserCommandController& browserCommands)
    : m_registry(registry)
    , m_browserCommands(browserCommands)
{
}

Result<void> ExtensionRuntime::registerHandler(ExtensionId extensionId, std::string channel, ExtensionMessageHandler handler)
{
    if (!m_registry.get(extensionId))
        return Result<void>::fail({ ErrorCode::NotFound, "extension not installed" });
    if (channel.empty())
        return Result<void>::fail({ ErrorCode::InvalidArgument, "channel is required" });

    m_handlers[keyFor(extensionId, channel)] = std::move(handler);
    return Result<void>::ok();
}

Result<ExtensionMessageResponse> ExtensionRuntime::dispatch(const ExtensionMessage& message) const
{
    if (!m_registry.get(message.extensionId))
        return Result<ExtensionMessageResponse>::fail({ ErrorCode::NotFound, "extension not installed" });
    if (!message.frame.origin.isPotentiallyTrustworthy())
        return Result<ExtensionMessageResponse>::fail({ ErrorCode::PermissionDenied, "untrustworthy extension message origin" });

    auto it = m_handlers.find(keyFor(message.extensionId, message.channel));
    if (it == m_handlers.end())
        return Result<ExtensionMessageResponse>::fail({ ErrorCode::Unsupported, "extension API channel is unsupported" });

    return it->second(message);
}

std::string ExtensionRuntime::keyFor(const ExtensionId& extensionId, const std::string& channel) const
{
    return extensionId + ":" + channel;
}

} // namespace ng

