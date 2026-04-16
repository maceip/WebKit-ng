#include "sync/LoopbackSyncClient.h"

#include <algorithm>

namespace ng {

LoopbackSyncClient::LoopbackSyncClient(std::string clientId)
    : m_clientId(std::move(clientId))
{
}

void LoopbackSyncClient::trackDataType(SyncDataType type)
{
    m_progressTokens.emplace(type, std::string());
}

void LoopbackSyncClient::upsertLocal(SyncDataType type, std::string clientTagHash, std::string name, std::string payload, bool folder, std::string parentId)
{
    trackDataType(type);
    const auto id = LoopbackSyncServer::createId(type, clientTagHash);
    auto& local = m_records[id];
    local.record.type = type;
    local.record.id = id;
    local.record.clientTagHash = std::move(clientTagHash);
    local.record.parentId = std::move(parentId);
    local.record.name = std::move(name);
    local.record.payload = std::move(payload);
    local.record.deleted = false;
    local.record.folder = folder;
    local.dirty = true;
}

bool LoopbackSyncClient::deleteLocal(const std::string& id)
{
    const auto iterator = m_records.find(id);
    if (iterator == m_records.end())
        return false;

    iterator->second.record.deleted = true;
    iterator->second.dirty = true;
    return true;
}

SyncResult LoopbackSyncClient::sync(LoopbackSyncServer& server)
{
    LoopbackSyncRpcService service(server);
    return sync(service);
}

SyncResult LoopbackSyncClient::sync(LoopbackSyncRpcEndpoint& endpoint)
{
    const auto commits = dirtyEntries();
    if (!commits.empty()) {
        CommitRequest request;
        request.storeBirthday = m_storeBirthday;
        request.clientId = m_clientId;
        request.entries = commits;

        LoopbackSyncRpcRequest rpcRequest;
        rpcRequest.method = LoopbackSyncRpcMethod::Commit;
        rpcRequest.commit = request;

        auto rpcResponse = endpoint.handleCommand(rpcRequest);
        if (rpcResponse.result != SyncResult::Success || !rpcResponse.commit)
            return rpcResponse.result;

        m_storeBirthday = rpcResponse.storeBirthday;
        applyCommitResponse(request, *rpcResponse.commit);
    }

    return pullRemoteChanges(endpoint);
}

std::optional<SyncRecord> LoopbackSyncClient::localRecord(const std::string& id) const
{
    const auto iterator = m_records.find(id);
    if (iterator == m_records.end())
        return std::nullopt;
    return iterator->second.record;
}

std::vector<SyncRecord> LoopbackSyncClient::localRecords(SyncDataType type, bool includeDeleted) const
{
    std::vector<SyncRecord> records;
    for (const auto& item : m_records) {
        if (item.second.record.type == type && (includeDeleted || !item.second.record.deleted))
            records.push_back(item.second.record);
    }
    std::sort(records.begin(), records.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.version < rhs.version;
    });
    return records;
}

std::vector<CommitEntry> LoopbackSyncClient::dirtyEntries() const
{
    std::vector<CommitEntry> entries;
    for (const auto& item : m_records) {
        const auto& local = item.second;
        if (!local.dirty)
            continue;

        CommitEntry entry;
        entry.type = local.record.type;
        entry.id = local.record.id;
        entry.clientTagHash = local.record.clientTagHash;
        entry.parentId = local.record.parentId;
        entry.name = local.record.name;
        entry.payload = local.record.payload;
        entry.baseVersion = local.record.version;
        entry.deleted = local.record.deleted;
        entry.folder = local.record.folder;
        entries.push_back(entry);
    }
    return entries;
}

void LoopbackSyncClient::applyCommitResponse(const CommitRequest& request, const CommitResponse& response)
{
    for (std::size_t i = 0; i < request.entries.size() && i < response.entries.size(); ++i) {
        if (response.entries[i].result != SyncResult::Success)
            continue;

        const auto& id = response.entries[i].id;
        auto iterator = m_records.find(id);
        if (iterator == m_records.end())
            continue;

        iterator->second.record.version = response.entries[i].version;
        iterator->second.dirty = false;
    }
}

SyncResult LoopbackSyncClient::pullRemoteChanges(LoopbackSyncRpcEndpoint& endpoint)
{
    GetUpdatesRequest request;
    request.storeBirthday = m_storeBirthday;
    request.clientId = m_clientId;
    for (const auto& item : m_progressTokens)
        request.progressMarkers.push_back({ item.first, item.second });

    LoopbackSyncRpcRequest rpcRequest;
    rpcRequest.method = LoopbackSyncRpcMethod::GetUpdates;
    rpcRequest.getUpdates = request;

    auto rpcResponse = endpoint.handleCommand(rpcRequest);
    if (rpcResponse.result != SyncResult::Success || !rpcResponse.getUpdates)
        return rpcResponse.result;

    const auto& response = *rpcResponse.getUpdates;
    m_storeBirthday = rpcResponse.storeBirthday;
    for (const auto& record : response.entries)
        applyRemoteRecord(record);
    for (const auto& marker : response.progressMarkers)
        m_progressTokens[marker.type] = marker.token;

    return SyncResult::Success;
}

void LoopbackSyncClient::applyRemoteRecord(const SyncRecord& record)
{
    auto& local = m_records[record.id];
    if (local.dirty)
        return;

    local.record = record;
    local.dirty = false;
}

} // namespace ng

