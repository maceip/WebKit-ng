#include "sync/LoopbackSyncClient.h"

#include <cassert>
#include <cstdlib>
#include <string>

using namespace ng;

namespace {

void testTwoClientsSyncBookmarks()
{
    LoopbackSyncServer server;
    LoopbackSyncClient laptop("laptop");
    LoopbackSyncClient phone("phone");

    laptop.trackDataType(SyncDataType::Bookmarks);
    phone.trackDataType(SyncDataType::Bookmarks);

    laptop.upsertLocal(SyncDataType::Bookmarks, "bookmark-a", "Example", "https://example.test");
    assert(laptop.sync(server) == SyncResult::Success);
    assert(phone.sync(server) == SyncResult::Success);

    const auto id = LoopbackSyncServer::createId(SyncDataType::Bookmarks, "bookmark-a");
    auto synced = phone.localRecord(id);
    assert(synced);
    assert(synced->name == "Example");
    assert(synced->payload == "https://example.test");
    assert(!synced->deleted);
}

void testTombstonesPropagateAfterInitialSync()
{
    LoopbackSyncServer server;
    LoopbackSyncClient first("first");
    LoopbackSyncClient second("second");

    first.trackDataType(SyncDataType::Bookmarks);
    second.trackDataType(SyncDataType::Bookmarks);

    first.upsertLocal(SyncDataType::Bookmarks, "bookmark-a", "Example", "https://example.test");
    assert(first.sync(server) == SyncResult::Success);
    assert(second.sync(server) == SyncResult::Success);

    const auto id = LoopbackSyncServer::createId(SyncDataType::Bookmarks, "bookmark-a");
    assert(first.deleteLocal(id));
    assert(first.sync(server) == SyncResult::Success);
    assert(second.sync(server) == SyncResult::Success);

    auto deleted = second.localRecord(id);
    assert(deleted);
    assert(deleted->deleted);
}

void testBirthdayResetIsDetected()
{
    LoopbackSyncServer server;
    LoopbackSyncClient client("client");
    client.trackDataType(SyncDataType::Preferences);

    assert(client.sync(server) == SyncResult::Success);
    assert(!client.storeBirthday().empty());

    server.clear();
    assert(client.sync(server) == SyncResult::NotMyBirthday);
}

void testConflictDetection()
{
    LoopbackSyncServer server;
    LoopbackSyncClient first("first");
    LoopbackSyncClient second("second");

    first.trackDataType(SyncDataType::Preferences);
    second.trackDataType(SyncDataType::Preferences);

    first.upsertLocal(SyncDataType::Preferences, "homepage", "Homepage", "https://first.test");
    assert(first.sync(server) == SyncResult::Success);
    assert(second.sync(server) == SyncResult::Success);

    first.upsertLocal(SyncDataType::Preferences, "homepage", "Homepage", "https://updated.test");
    second.upsertLocal(SyncDataType::Preferences, "homepage", "Homepage", "https://stale.test");

    assert(first.sync(server) == SyncResult::Success);
    assert(second.sync(server) == SyncResult::Conflict);
}

void testRpcCommandEndpoint()
{
    LoopbackSyncServer server;
    LoopbackSyncRpcService service(server);

    assert(std::string(LoopbackSyncRpcService::commandPath()) == "/command");
    assert(std::string(LoopbackSyncRpcService::commandHttpMethod()) == "POST");
    assert(std::string(LoopbackSyncRpcService::wireContentType()) == "application/octet-stream");

    CommitRequest commit;
    commit.clientId = "rpc-client";
    commit.entries.push_back({ SyncDataType::Extensions, "", "extension-a", "", "Extension A", "{\"enabled\":true}", 0, false, false });

    LoopbackSyncRpcRequest commitRpc;
    commitRpc.method = LoopbackSyncRpcMethod::Commit;
    commitRpc.commit = commit;

    auto commitResponse = service.handleCommand(commitRpc);
    assert(commitResponse.result == SyncResult::Success);
    assert(commitResponse.commit);
    assert(commitResponse.commit->entries.size() == 1);

    GetUpdatesRequest updates;
    updates.storeBirthday = commitResponse.storeBirthday;
    updates.clientId = "reader";
    updates.progressMarkers.push_back({ SyncDataType::Extensions, "" });

    LoopbackSyncRpcRequest updatesRpc;
    updatesRpc.method = LoopbackSyncRpcMethod::GetUpdates;
    updatesRpc.getUpdates = updates;

    auto updatesResponse = service.handleCommand(updatesRpc);
    assert(updatesResponse.result == SyncResult::Success);
    assert(updatesResponse.getUpdates);
    assert(!updatesResponse.getUpdates->entries.empty());

    LoopbackSyncRpcRequest clearRpc;
    clearRpc.method = LoopbackSyncRpcMethod::ClearServerData;
    auto clearResponse = service.handleCommand(clearRpc);
    assert(clearResponse.result == SyncResult::Success);
    assert(clearResponse.clearedServerData);
    assert(clearResponse.storeBirthday != commitResponse.storeBirthday);
}

} // namespace

int main()
{
    testTwoClientsSyncBookmarks();
    testTombstonesPropagateAfterInitialSync();
    testBirthdayResetIsDetected();
    testConflictDetection();
    testRpcCommandEndpoint();
    return EXIT_SUCCESS;
}

