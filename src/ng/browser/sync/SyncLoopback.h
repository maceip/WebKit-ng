#pragma once

#include "core/Result.h"

#include <cstdint>
#include <string>
#include <vector>

namespace ng {

enum class SyncEntityType {
    Bookmark,
    Preference,
    PasswordMetadata,
    ExtensionSetting,
    TabSession,
};

struct SyncEntity {
    std::string id;
    SyncEntityType type { SyncEntityType::Preference };
    uint64_t version { 0 };
    std::vector<uint8_t> payload;
};

struct SyncCommitRequest {
    std::string clientId;
    std::vector<SyncEntity> entities;
};

struct SyncCommitResponse {
    uint64_t serverVersion { 0 };
};

struct SyncGetUpdatesRequest {
    std::string clientId;
    uint64_t sinceVersion { 0 };
};

struct SyncGetUpdatesResponse {
    uint64_t serverVersion { 0 };
    std::vector<SyncEntity> entities;
};

class SyncLoopbackStore {
public:
    Result<SyncCommitResponse> commit(const SyncCommitRequest&);
    Result<SyncGetUpdatesResponse> getUpdates(const SyncGetUpdatesRequest&) const;

private:
    uint64_t m_serverVersion { 0 };
    std::vector<SyncEntity> m_entities;
};

class SyncTransport {
public:
    virtual ~SyncTransport() = default;
    virtual Result<SyncCommitResponse> commit(const SyncCommitRequest&) = 0;
    virtual Result<SyncGetUpdatesResponse> getUpdates(const SyncGetUpdatesRequest&) = 0;
};

} // namespace ng

