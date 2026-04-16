#include "extensions/ExtensionRegistry.h"

namespace ng {

Result<void> ExtensionRegistry::install(ExtensionManifest manifest)
{
    auto validation = manifest.validate();
    if (!validation)
        return validation;

    auto id = manifest.id;
    m_extensions[id] = std::move(manifest);
    return Result<void>::ok();
}

Result<void> ExtensionRegistry::uninstall(const ExtensionId& id)
{
    if (!m_extensions.erase(id))
        return Result<void>::fail({ ErrorCode::NotFound, "extension not installed" });
    return Result<void>::ok();
}

const ExtensionManifest* ExtensionRegistry::get(const ExtensionId& id) const
{
    auto it = m_extensions.find(id);
    return it == m_extensions.end() ? nullptr : &it->second;
}

std::vector<ExtensionManifest> ExtensionRegistry::installedExtensions() const
{
    std::vector<ExtensionManifest> result;
    result.reserve(m_extensions.size());
    for (const auto& entry : m_extensions)
        result.push_back(entry.second);
    return result;
}

} // namespace ng

