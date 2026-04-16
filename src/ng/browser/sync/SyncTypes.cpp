#include "sync/SyncTypes.h"

namespace ng {

std::string syncDataTypeName(SyncDataType type)
{
    switch (type) {
    case SyncDataType::Bookmarks:
        return "bookmarks";
    case SyncDataType::Preferences:
        return "preferences";
    case SyncDataType::Passwords:
        return "passwords";
    case SyncDataType::Sessions:
        return "sessions";
    case SyncDataType::Extensions:
        return "extensions";
    case SyncDataType::WebAuthnCredentials:
        return "webauthn_credentials";
    }
    return "unknown";
}

std::string syncDataTypeProtocolRootTag(SyncDataType type)
{
    return syncDataTypeName(type) + "_root";
}

int syncDataTypeStableId(SyncDataType type)
{
    switch (type) {
    case SyncDataType::Bookmarks:
        return 1;
    case SyncDataType::Preferences:
        return 2;
    case SyncDataType::Passwords:
        return 3;
    case SyncDataType::Sessions:
        return 4;
    case SyncDataType::Extensions:
        return 5;
    case SyncDataType::WebAuthnCredentials:
        return 6;
    }
    return 0;
}

} // namespace ng

