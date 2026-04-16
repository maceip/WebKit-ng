#include "sync/LoopbackSyncServer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>

namespace ng {

namespace {

std::int64_t parseToken(const std::string& token)
{
    if (token.empty())
        return 0;

    char* end = nullptr;
    const auto value = std::strtoll(token.c_str(), &end, 10);
    return end && *end == '\0' ? value : 0;
}

std::string tokenFromVersion(std::int64_t version)
{
    return std::to_string(version);
}

std::string makeStoreBirthday()
{
    static std::atomic<std::uint64_t> sequence { 0 };
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(now).count()) + "-" + std::to_string(++sequence);
}

bool hasProgressMarker(const GetUpdatesRequest& request, SyncDataType type)
{
    return std::any_of(request.progressMarkers.begin(), request.progressMarkers.end(), [type](const auto& marker) {
        return marker.type == type;
    });
}

} // namespace

LoopbackSyncServer::LoopbackSyncServer()
    : m_storeBirthday(makeStoreBirthday())
{
    initializePermanentRoots();
}

GetUpdatesResponse LoopbackSyncServer::getUpdates(const GetUpdatesRequest& request) const
{
    GetUpdatesResponse response;
    response.storeBirthday = m_storeBirthday;

    if (request.clientId.empty()) {
        response.result = SyncResult::InvalidRequest;
        return response;
    }
    if (!acceptsBirthday(request.storeBirthday)) {
        response.result = SyncResult::NotMyBirthday;
        return response;
    }

    std::vector<SyncRecord> wantedRecords;
    std::map<SyncDataType, std::int64_t> highWaterMarks;
    for (const auto& marker : request.progressMarkers)
        highWaterMarks[marker.type] = parseToken(marker.token);

    for (const auto& item : m_records) {
        const auto& record = item.second;
        if (!hasProgressMarker(request, record.type))
            continue;

        const auto token = highWaterMarks[record.type];
        if (record.deleted && token == 0)
            continue;

        if (record.version > token)
            wantedRecords.push_back(record);
    }

    std::sort(wantedRecords.begin(), wantedRecords.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.version < rhs.version;
    });

    if (wantedRecords.size() > request.maxEntries) {
        response.changesRemaining = wantedRecords.size() - request.maxEntries;
        wantedRecords.resize(request.maxEntries);
    }

    response.entries = std::move(wantedRecords);
    for (const auto& record : response.entries)
        highWaterMarks[record.type] = std::max(highWaterMarks[record.type], record.version);

    for (const auto& marker : request.progressMarkers)
        response.progressMarkers.push_back({ marker.type, tokenFromVersion(highWaterMarks[marker.type]) });

    return response;
}

CommitResponse LoopbackSyncServer::commit(const CommitRequest& request)
{
    CommitResponse response;
    response.storeBirthday = m_storeBirthday;

    if (request.clientId.empty()) {
        response.result = SyncResult::InvalidRequest;
        return response;
    }
    if (!acceptsBirthday(request.storeBirthday)) {
        response.result = SyncResult::NotMyBirthday;
        return response;
    }

    for (const auto& entry : request.entries) {
        CommitResponseEntry entryResponse;
        const auto id = assignId(entry);
        entryResponse.id = id;

        if (id.empty()) {
            entryResponse.result = SyncResult::InvalidRequest;
            response.result = SyncResult::InvalidRequest;
            response.entries.push_back(entryResponse);
            continue;
        }

        const auto existing = m_records.find(id);
        if (m_strongConsistencyEnabled && existing != m_records.end() && existing->second.version != entry.baseVersion) {
            entryResponse.result = SyncResult::Conflict;
            entryResponse.version = existing->second.version;
            response.result = SyncResult::Conflict;
            response.entries.push_back(entryResponse);
            continue;
        }

        SyncRecord record;
        record.type = entry.type;
        record.id = id;
        record.clientTagHash = entry.clientTagHash;
        record.parentId = entry.parentId;
        record.name = entry.name;
        record.payload = entry.payload;
        record.deleted = entry.deleted;
        record.folder = entry.folder;
        record.version = nextVersion();

        m_records[id] = record;
        entryResponse.version = record.version;
        response.entries.push_back(entryResponse);
    }

    return response;
}

void LoopbackSyncServer::clear()
{
    m_records.clear();
    m_lastVersion = 0;
    m_storeBirthday = makeStoreBirthday();
    initializePermanentRoots();
}

std::optional<SyncRecord> LoopbackSyncServer::record(const std::string& id) const
{
    const auto iterator = m_records.find(id);
    if (iterator == m_records.end())
        return std::nullopt;
    return iterator->second;
}

std::vector<SyncRecord> LoopbackSyncServer::recordsForType(SyncDataType type, bool includeDeleted) const
{
    std::vector<SyncRecord> records;
    for (const auto& item : m_records) {
        if (item.second.type == type && (includeDeleted || !item.second.deleted))
            records.push_back(item.second);
    }
    std::sort(records.begin(), records.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.version < rhs.version;
    });
    return records;
}

std::string LoopbackSyncServer::createId(SyncDataType type, const std::string& innerId)
{
    if (innerId.empty())
        return { };
    return std::to_string(syncDataTypeStableId(type)) + "_" + innerId;
}

std::string LoopbackSyncServer::topLevelId(SyncDataType type)
{
    return createId(type, syncDataTypeProtocolRootTag(type));
}

std::string LoopbackSyncServer::assignId(const CommitEntry& entry) const
{
    if (!entry.id.empty())
        return entry.id;
    if (entry.deleted)
        return { };
    return createId(entry.type, entry.clientTagHash.empty() ? entry.name : entry.clientTagHash);
}

bool LoopbackSyncServer::acceptsBirthday(const std::string& birthday) const
{
    return birthday.empty() || birthday == m_storeBirthday;
}

std::int64_t LoopbackSyncServer::nextVersion()
{
    return ++m_lastVersion;
}

void LoopbackSyncServer::createPermanentRoot(SyncDataType type)
{
    SyncRecord record;
    record.type = type;
    record.id = topLevelId(type);
    record.clientTagHash = syncDataTypeProtocolRootTag(type);
    record.name = syncDataTypeName(type);
    record.folder = true;
    record.version = nextVersion();
    m_records[record.id] = record;
}

void LoopbackSyncServer::initializePermanentRoots()
{
    createPermanentRoot(SyncDataType::Bookmarks);
    createPermanentRoot(SyncDataType::Preferences);
    createPermanentRoot(SyncDataType::Passwords);
    createPermanentRoot(SyncDataType::Sessions);
    createPermanentRoot(SyncDataType::Extensions);
    createPermanentRoot(SyncDataType::WebAuthnCredentials);
}

} // namespace ng

