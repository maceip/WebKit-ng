#pragma once

#include "sync/LoopbackSyncRpc.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace ng {

class LoopbackSyncClient {
public:
    explicit LoopbackSyncClient(std::string clientId);

    const std::string& clientId() const { return m_clientId; }
    const std::string& storeBirthday() const { return m_storeBirthday; }

    void trackDataType(SyncDataType);
    void upsertLocal(SyncDataType, std::string clientTagHash, std::string name, std::string payload, bool folder = false, std::string parentId = { });
    bool deleteLocal(const std::string& id);

    SyncResult sync(LoopbackSyncServer&);
    SyncResult sync(LoopbackSyncRpcEndpoint&);

    std::optional<SyncRecord> localRecord(const std::string& id) const;
    std::vector<SyncRecord> localRecords(SyncDataType, bool includeDeleted = false) const;

private:
    struct LocalRecord {
        SyncRecord record;
        bool dirty { false };
    };

    std::vector<CommitEntry> dirtyEntries() const;
    void applyCommitResponse(const CommitRequest&, const CommitResponse&);
    SyncResult pullRemoteChanges(LoopbackSyncRpcEndpoint&);
    void applyRemoteRecord(const SyncRecord&);

    std::string m_clientId;
    std::string m_storeBirthday;
    std::map<SyncDataType, std::string> m_progressTokens;
    std::map<std::string, LocalRecord> m_records;
};

} // namespace ng

