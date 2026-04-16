#include "sync/ChromiumSyncWireAdapter.h"

#include <components/sync/protocol/sync.pb.h>

#include <cassert>
#include <cstdlib>
#include <string>

using namespace ng;

namespace {

std::vector<std::uint8_t> bytesFromProto(const google::protobuf::MessageLite& message)
{
    const auto serialized = message.SerializeAsString();
    return { serialized.begin(), serialized.end() };
}

sync_pb::ClientToServerResponse parseResponse(const ChromiumSyncWireResponse& wireResponse)
{
    assert(wireResponse.httpStatus == 200);
    sync_pb::ClientToServerResponse response;
    assert(response.ParseFromArray(wireResponse.serializedClientToServerResponse.data(), static_cast<int>(wireResponse.serializedClientToServerResponse.size())));
    return response;
}

void testCommitAndGetUpdatesRoundTrip()
{
    LoopbackSyncServer server;
    LoopbackSyncRpcService service(server);
    ChromiumSyncWireAdapter adapter(service);

    sync_pb::ClientToServerMessage commitMessage;
    commitMessage.set_share("ng-user");
    commitMessage.set_message_contents(sync_pb::ClientToServerMessage::COMMIT);
    commitMessage.mutable_commit()->set_cache_guid("client-a");

    auto& entity = *commitMessage.mutable_commit()->add_entries();
    entity.set_id_string(LoopbackSyncServer::createId(SyncDataType::Preferences, "homepage"));
    entity.set_version(0);
    entity.set_name("Homepage");
    entity.set_non_unique_name("Homepage");
    entity.set_client_tag_hash("homepage");
    entity.mutable_specifics()->mutable_preference()->set_name("homepage");
    entity.mutable_specifics()->mutable_preference()->set_value("https://example.test");

    ChromiumSyncWireRequest commitWire;
    commitWire.serializedClientToServerMessage = bytesFromProto(commitMessage);

    const auto commitResponse = parseResponse(adapter.handleWireCommand(commitWire));
    assert(commitResponse.error_code() == sync_pb::SyncEnums::SUCCESS);
    assert(commitResponse.has_commit());
    assert(commitResponse.commit().entryresponse_size() == 1);
    assert(commitResponse.commit().entryresponse(0).response_type() == sync_pb::CommitResponse::SUCCESS);
    assert(!commitResponse.store_birthday().empty());

    sync_pb::ClientToServerMessage updatesMessage;
    updatesMessage.set_share("ng-user");
    updatesMessage.set_store_birthday(commitResponse.store_birthday());
    updatesMessage.set_message_contents(sync_pb::ClientToServerMessage::GET_UPDATES);
    auto& marker = *updatesMessage.mutable_get_updates()->add_from_progress_marker();
    marker.set_data_type_id(37702);
    marker.set_token("");

    ChromiumSyncWireRequest updatesWire;
    updatesWire.serializedClientToServerMessage = bytesFromProto(updatesMessage);

    const auto updatesResponse = parseResponse(adapter.handleWireCommand(updatesWire));
    assert(updatesResponse.error_code() == sync_pb::SyncEnums::SUCCESS);
    assert(updatesResponse.has_get_updates());
    assert(updatesResponse.get_updates().entries_size() >= 1);
    assert(updatesResponse.get_updates().new_progress_marker_size() == 1);

    bool foundHomepage = false;
    for (const auto& synced : updatesResponse.get_updates().entries()) {
        if (!synced.specifics().has_preference())
            continue;
        if (synced.specifics().preference().name() == "homepage" && synced.specifics().preference().value() == "https://example.test")
            foundHomepage = true;
    }
    assert(foundHomepage);
}

void testBirthdayMismatchUsesChromiumErrorCode()
{
    LoopbackSyncServer server;
    LoopbackSyncRpcService service(server);
    ChromiumSyncWireAdapter adapter(service);

    sync_pb::ClientToServerMessage updatesMessage;
    updatesMessage.set_share("ng-user");
    updatesMessage.set_store_birthday("stale-birthday");
    updatesMessage.set_message_contents(sync_pb::ClientToServerMessage::GET_UPDATES);
    updatesMessage.mutable_get_updates()->add_from_progress_marker()->set_data_type_id(37702);

    ChromiumSyncWireRequest wire;
    wire.serializedClientToServerMessage = bytesFromProto(updatesMessage);

    const auto response = parseResponse(adapter.handleWireCommand(wire));
    assert(response.error_code() == sync_pb::SyncEnums::NOT_MY_BIRTHDAY);
    assert(response.store_birthday() == server.storeBirthday());
}

void testClearServerDataRoundTrip()
{
    LoopbackSyncServer server;
    const auto oldBirthday = server.storeBirthday();
    LoopbackSyncRpcService service(server);
    ChromiumSyncWireAdapter adapter(service);

    sync_pb::ClientToServerMessage clearMessage;
    clearMessage.set_share("ng-user");
    clearMessage.set_message_contents(sync_pb::ClientToServerMessage::CLEAR_SERVER_DATA);
    clearMessage.mutable_clear_server_data();

    ChromiumSyncWireRequest wire;
    wire.serializedClientToServerMessage = bytesFromProto(clearMessage);

    const auto response = parseResponse(adapter.handleWireCommand(wire));
    assert(response.error_code() == sync_pb::SyncEnums::SUCCESS);
    assert(response.has_clear_server_data());
    assert(response.store_birthday() != oldBirthday);
}

} // namespace

int main()
{
    testCommitAndGetUpdatesRoundTrip();
    testBirthdayMismatchUsesChromiumErrorCode();
    testClearServerDataRoundTrip();
    return EXIT_SUCCESS;
}
