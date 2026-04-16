#include "sync/SyncLoopback.h"

#include <algorithm>

namespace ng {

Result<SyncCommitResponse> SyncLoopbackStore::commit(const SyncCommitRequest& request)
{
    if (request.clientId.empty())
        return Result<SyncCommitResponse>::fail({ ErrorCode::InvalidArgument, "client id is required" });

    for (auto entity : request.entities) {
        if (entity.id.empty())
            return Result<SyncCommitResponse>::fail({ ErrorCode::InvalidArgument, "entity id is required" });

        entity.version = ++m_serverVersion;
        auto existing = std::find_if(m_entities.begin(), m_entities.end(), [&](const auto& item) { return item.id == entity.id; });
        if (existing == m_entities.end())
            m_entities.push_back(std::move(entity));
        else
            *existing = std::move(entity);
    }

    return Result<SyncCommitResponse>::ok({ m_serverVersion });
}

Result<SyncGetUpdatesResponse> SyncLoopbackStore::getUpdates(const SyncGetUpdatesRequest& request) const
{
    if (request.clientId.empty())
        return Result<SyncGetUpdatesResponse>::fail({ ErrorCode::InvalidArgument, "client id is required" });

    SyncGetUpdatesResponse response;
    response.serverVersion = m_serverVersion;
    for (const auto& entity : m_entities) {
        if (entity.version > request.sinceVersion)
            response.entities.push_back(entity);
    }

    return Result<SyncGetUpdatesResponse>::ok(std::move(response));
}

} // namespace ng

