#pragma once

#include "core/Result.h"

#include <string>
#include <vector>

namespace ng {

using ExtensionId = std::string;

enum class ExtensionManifestVersion {
    Unknown,
    ManifestV3,
};

struct ExtensionAction {
    std::string defaultTitle;
    std::string defaultPopupPath;
};

struct ExtensionSidePanel {
    std::string defaultPath;
};

struct ExtensionManifest {
    ExtensionId id;
    ExtensionManifestVersion version { ExtensionManifestVersion::Unknown };
    std::string name;
    std::string versionString;
    std::vector<std::string> permissions;
    std::vector<std::string> hostPermissions;
    std::vector<std::string> backgroundServiceWorkers;
    std::vector<std::string> contentScriptMatches;
    ExtensionAction action;
    ExtensionSidePanel sidePanel;

    Result<void> validate() const;
    bool declaresPermission(const std::string&) const;
};

} // namespace ng

