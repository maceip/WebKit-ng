#include "extensions/ExtensionManifest.h"

#include <algorithm>

namespace ng {

Result<void> ExtensionManifest::validate() const
{
    if (id.empty())
        return Result<void>::fail({ ErrorCode::InvalidArgument, "extension id is required" });
    if (version != ExtensionManifestVersion::ManifestV3)
        return Result<void>::fail({ ErrorCode::Unsupported, "only manifest_version 3 is accepted" });
    if (name.empty())
        return Result<void>::fail({ ErrorCode::InvalidArgument, "extension name is required" });
    if (versionString.empty())
        return Result<void>::fail({ ErrorCode::InvalidArgument, "extension version is required" });
    return Result<void>::ok();
}

bool ExtensionManifest::declaresPermission(const std::string& permission) const
{
    return std::find(permissions.begin(), permissions.end(), permission) != permissions.end();
}

} // namespace ng

