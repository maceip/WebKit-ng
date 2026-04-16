#pragma once

#include <cstdint>
#include <string>

namespace ng {

struct Origin {
    std::string scheme;
    std::string host;
    uint16_t port { 0 };

    bool isPotentiallyTrustworthy() const;
    std::string serialize() const;
};

struct FrameContext {
    Origin origin;
    Origin topLevelOrigin;
    bool isTopLevel { false };
    bool hasTransientUserActivation { false };
};

} // namespace ng

