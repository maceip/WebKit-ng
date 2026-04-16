#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ng {

enum class SyncDataType {
    Bookmarks,
    Preferences,
    Passwords,
    Sessions,
    Extensions,
    WebAuthnCredentials,
};

struct SyncRecord {
    SyncDataType type { SyncDataType::Bookmarks };
    std::string id;
    std::string clientTagHash;
    std::string parentId;
    std::string name;
    std::string payload;
    std::int64_t version { 0 };
    bool deleted { false };
    bool folder { false };
};

struct ProgressMarker {
    SyncDataType type { SyncDataType::Bookmarks };
    std::string token;
};

enum class SyncResult {
    Success,
    NotMyBirthday,
    Conflict,
    InvalidRequest,
    Unsupported,
};

struct GetUpdatesRequest {
    std::string storeBirthday;
    std::string clientId;
    std::vector<ProgressMarker> progressMarkers;
    std::size_t maxEntries { 1000000 };
};

struct GetUpdatesResponse {
    SyncResult result { SyncResult::Success };
    std::string storeBirthday;
    std::vector<SyncRecord> entries;
    std::vector<ProgressMarker> progressMarkers;
    std::size_t changesRemaining { 0 };
};

struct CommitEntry {
    SyncDataType type { SyncDataType::Bookmarks };
    std::string id;
    std::string clientTagHash;
    std::string parentId;
    std::string name;
    std::string payload;
    std::int64_t baseVersion { 0 };
    bool deleted { false };
    bool folder { false };
};

struct CommitRequest {
    std::string storeBirthday;
    std::string clientId;
    std::vector<CommitEntry> entries;
};

struct CommitResponseEntry {
    SyncResult result { SyncResult::Success };
    std::string id;
    std::int64_t version { 0 };
};

struct CommitResponse {
    SyncResult result { SyncResult::Success };
    std::string storeBirthday;
    std::vector<CommitResponseEntry> entries;
};

std::string syncDataTypeName(SyncDataType);
std::string syncDataTypeProtocolRootTag(SyncDataType);
int syncDataTypeStableId(SyncDataType);

} // namespace ng

