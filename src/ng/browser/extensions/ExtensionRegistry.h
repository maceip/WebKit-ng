#pragma once

#include "extensions/ExtensionManifest.h"

#include <map>

namespace ng {

class ExtensionRegistry {
public:
    Result<void> install(ExtensionManifest);
    Result<void> uninstall(const ExtensionId&);
    const ExtensionManifest* get(const ExtensionId&) const;
    std::vector<ExtensionManifest> installedExtensions() const;

private:
    std::map<ExtensionId, ExtensionManifest> m_extensions;
};

} // namespace ng

