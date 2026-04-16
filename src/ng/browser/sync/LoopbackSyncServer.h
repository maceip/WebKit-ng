#pragma once

#include "sync/SyncTypes.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace ng {

class LoopbackSyncServer {
public:
    LoopbackSyncServer();

    void setStrongConsistencyEnabled(bool enabled) { m_strongConsistencyEnabled = enabled; }
    bool strongConsistencyEnabled() const { return m_strongConsistencyEnabled; }

    const std::string& storeBirthday() const { return m_storeBirthday; }
    std::int64_t currentVersion() const { return m_lastVersion; }
    std::size_t recordCount() const { return m_records.size(); }

    GetUpdatesResponse getUpdates(const GetUpdatesRequest&) const;
    CommitResponse commit(const CommitRequest&);
    void clear();

    std::optional<SyncRecord> record(const std::string& id) const;
    std::vector<SyncRecord> recordsForType(SyncDataType, bool includeDeleted = false) const;

    static std::string createId(SyncDataType, const std::string& innerId);
    static std::string topLevelId(SyncDataType);

private:
    std::string assignId(const CommitEntry&) const;
    bool acceptsBirthday(const std::string&) const;
    std::int64_t nextVersion();
    void createPermanentRoot(SyncDataType);
    void initializePermanentRoots();

    bool m_strongConsistencyEnabled { true };
    std::int64_t m_lastVersion { 0 };
    std::string m_storeBirthday;
    std::map<std::string, SyncRecord> m_records;
};

} // namespace ng

