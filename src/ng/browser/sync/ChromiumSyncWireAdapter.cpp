#include "sync/ChromiumSyncWireAdapter.h"

#include <components/sync/protocol/entity_specifics.pb.h>
#include <components/sync/protocol/sync.pb.h>

#include <optional>

namespace ng {

namespace {

constexpr int bookmarkSpecificsFieldNumber = 32904;
constexpr int preferenceSpecificsFieldNumber = 37702;
constexpr int passwordSpecificsFieldNumber = 45873;
constexpr int extensionSpecificsFieldNumber = 48119;
constexpr int sessionSpecificsFieldNumber = 50119;
constexpr int extensionSettingSpecificsFieldNumber = 96159;
constexpr int webauthnCredentialSpecificsFieldNumber = 895275;

std::optional<SyncDataType> dataTypeFromSpecificsFieldNumber(int fieldNumber)
{
    switch (fieldNumber) {
    case bookmarkSpecificsFieldNumber:
        return SyncDataType::Bookmarks;
    case preferenceSpecificsFieldNumber:
        return SyncDataType::Preferences;
    case passwordSpecificsFieldNumber:
        return SyncDataType::Passwords;
    case extensionSpecificsFieldNumber:
    case extensionSettingSpecificsFieldNumber:
        return SyncDataType::Extensions;
    case sessionSpecificsFieldNumber:
        return SyncDataType::Sessions;
    case webauthnCredentialSpecificsFieldNumber:
        return SyncDataType::WebAuthnCredentials;
    default:
        return std::nullopt;
    }
}

int specificsFieldNumberFromDataType(SyncDataType type)
{
    switch (type) {
    case SyncDataType::Bookmarks:
        return bookmarkSpecificsFieldNumber;
    case SyncDataType::Preferences:
        return preferenceSpecificsFieldNumber;
    case SyncDataType::Passwords:
        return passwordSpecificsFieldNumber;
    case SyncDataType::Sessions:
        return sessionSpecificsFieldNumber;
    case SyncDataType::Extensions:
        return extensionSpecificsFieldNumber;
    case SyncDataType::WebAuthnCredentials:
        return webauthnCredentialSpecificsFieldNumber;
    }
    return 0;
}

std::optional<SyncDataType> dataTypeFromSpecifics(const sync_pb::EntitySpecifics& specifics)
{
    switch (specifics.specifics_variant_case()) {
    case sync_pb::EntitySpecifics::kBookmark:
        return SyncDataType::Bookmarks;
    case sync_pb::EntitySpecifics::kPreference:
        return SyncDataType::Preferences;
    case sync_pb::EntitySpecifics::kPassword:
        return SyncDataType::Passwords;
    case sync_pb::EntitySpecifics::kExtension:
    case sync_pb::EntitySpecifics::kExtensionSetting:
        return SyncDataType::Extensions;
    case sync_pb::EntitySpecifics::kSession:
        return SyncDataType::Sessions;
    case sync_pb::EntitySpecifics::kWebauthnCredential:
        return SyncDataType::WebAuthnCredentials;
    case sync_pb::EntitySpecifics::SPECIFICS_VARIANT_NOT_SET:
    default:
        return std::nullopt;
    }
}

sync_pb::CommitResponse::ResponseType entryResponseFromSyncResult(SyncResult result)
{
    switch (result) {
    case SyncResult::Success:
        return sync_pb::CommitResponse::SUCCESS;
    case SyncResult::Conflict:
        return sync_pb::CommitResponse::CONFLICT;
    case SyncResult::InvalidRequest:
    case SyncResult::NotMyBirthday:
    case SyncResult::Unsupported:
        return sync_pb::CommitResponse::INVALID_MESSAGE;
    }
    return sync_pb::CommitResponse::INVALID_MESSAGE;
}

sync_pb::SyncEnums::ErrorType errorTypeFromSyncResult(SyncResult result)
{
    switch (result) {
    case SyncResult::Success:
    case SyncResult::Conflict:
        return sync_pb::SyncEnums::SUCCESS;
    case SyncResult::NotMyBirthday:
        return sync_pb::SyncEnums::NOT_MY_BIRTHDAY;
    case SyncResult::InvalidRequest:
    case SyncResult::Unsupported:
        return sync_pb::SyncEnums::UNKNOWN;
    }
    return sync_pb::SyncEnums::UNKNOWN;
}

std::string entityName(const sync_pb::SyncEntity& entity)
{
    if (entity.has_non_unique_name())
        return entity.non_unique_name();
    if (entity.has_name())
        return entity.name();
    return { };
}

CommitEntry commitEntryFromProto(const sync_pb::SyncEntity& entity)
{
    CommitEntry entry;
    if (entity.has_specifics()) {
        if (auto type = dataTypeFromSpecifics(entity.specifics()))
            entry.type = *type;
        entry.payload = entity.specifics().SerializeAsString();
    }
    entry.id = entity.id_string();
    entry.clientTagHash = entity.client_tag_hash();
    entry.parentId = entity.parent_id_string();
    entry.name = entityName(entity);
    entry.baseVersion = entity.version();
    entry.deleted = entity.deleted();
    entry.folder = entity.folder();
    return entry;
}

void fillFallbackSpecifics(const SyncRecord& record, sync_pb::EntitySpecifics& specifics)
{
    switch (record.type) {
    case SyncDataType::Bookmarks:
        specifics.mutable_bookmark()->set_full_title(record.name);
        specifics.mutable_bookmark()->set_url(record.payload);
        specifics.mutable_bookmark()->set_type(record.folder ? sync_pb::BookmarkSpecifics::FOLDER : sync_pb::BookmarkSpecifics::URL);
        return;
    case SyncDataType::Preferences:
        specifics.mutable_preference()->set_name(record.name);
        specifics.mutable_preference()->set_value(record.payload);
        return;
    case SyncDataType::Extensions:
        specifics.mutable_extension()->set_id(record.clientTagHash);
        return;
    case SyncDataType::Sessions:
        specifics.mutable_session();
        return;
    case SyncDataType::Passwords:
        specifics.mutable_password();
        return;
    case SyncDataType::WebAuthnCredentials:
        specifics.mutable_webauthn_credential();
        return;
    }
}

void fillSyncEntity(const SyncRecord& record, sync_pb::SyncEntity& entity)
{
    entity.set_id_string(record.id);
    entity.set_parent_id_string(record.parentId);
    entity.set_version(record.version);
    entity.set_name(record.name);
    entity.set_non_unique_name(record.name);
    entity.set_deleted(record.deleted);
    entity.set_folder(record.folder);
    if (!record.clientTagHash.empty())
        entity.set_client_tag_hash(record.clientTagHash);

    auto& specifics = *entity.mutable_specifics();
    if (record.payload.empty() || !specifics.ParseFromString(record.payload))
        fillFallbackSpecifics(record, specifics);
}

} // namespace

ChromiumSyncWireAdapter::ChromiumSyncWireAdapter(LoopbackSyncRpcEndpoint& endpoint)
    : m_endpoint(endpoint)
{
}

ChromiumSyncWireResponse ChromiumSyncWireAdapter::handleWireCommand(const ChromiumSyncWireRequest& request)
{
    ChromiumSyncWireResponse response;
    response.contentType = ChromiumSyncWireResponse().contentType;

    if (request.httpMethod != LoopbackSyncRpcService::commandHttpMethod()) {
        response.httpStatus = 405;
        return response;
    }
    if (request.path != LoopbackSyncRpcService::commandPath()) {
        response.httpStatus = 404;
        return response;
    }

    sync_pb::ClientToServerMessage protoRequest;
    if (!protoRequest.ParseFromArray(request.serializedClientToServerMessage.data(), static_cast<int>(request.serializedClientToServerMessage.size()))) {
        response.httpStatus = 400;
        return response;
    }

    LoopbackSyncRpcRequest rpcRequest;
    if (!decodeRequest(protoRequest, rpcRequest)) {
        response.httpStatus = 400;
        return response;
    }

    sync_pb::ClientToServerResponse protoResponse;
    encodeResponse(m_endpoint.handleCommand(rpcRequest), protoResponse);

    const auto serialized = protoResponse.SerializeAsString();
    response.serializedClientToServerResponse.assign(serialized.begin(), serialized.end());
    return response;
}

bool ChromiumSyncWireAdapter::decodeRequest(const sync_pb::ClientToServerMessage& message, LoopbackSyncRpcRequest& request) const
{
    switch (message.message_contents()) {
    case sync_pb::ClientToServerMessage::GET_UPDATES: {
        if (!message.has_get_updates())
            return false;
        GetUpdatesRequest getUpdates;
        getUpdates.storeBirthday = message.store_birthday();
        getUpdates.clientId = message.share();
        for (const auto& marker : message.get_updates().from_progress_marker()) {
            auto type = dataTypeFromSpecificsFieldNumber(marker.data_type_id());
            if (!type)
                continue;
            getUpdates.progressMarkers.push_back({ *type, marker.token() });
        }
        request.method = LoopbackSyncRpcMethod::GetUpdates;
        request.getUpdates = std::move(getUpdates);
        return true;
    }

    case sync_pb::ClientToServerMessage::COMMIT: {
        if (!message.has_commit())
            return false;
        CommitRequest commit;
        commit.storeBirthday = message.store_birthday();
        commit.clientId = message.commit().cache_guid().empty() ? message.share() : message.commit().cache_guid();
        for (const auto& entity : message.commit().entries()) {
            if (!entity.has_specifics() || !dataTypeFromSpecifics(entity.specifics()))
                return false;
            commit.entries.push_back(commitEntryFromProto(entity));
        }
        request.method = LoopbackSyncRpcMethod::Commit;
        request.commit = std::move(commit);
        return true;
    }

    case sync_pb::ClientToServerMessage::CLEAR_SERVER_DATA:
        request.method = LoopbackSyncRpcMethod::ClearServerData;
        return true;

    case sync_pb::ClientToServerMessage::DEPRECATED_3:
    case sync_pb::ClientToServerMessage::DEPRECATED_4:
    default:
        return false;
    }
}

void ChromiumSyncWireAdapter::encodeResponse(const LoopbackSyncRpcResponse& rpcResponse, sync_pb::ClientToServerResponse& response) const
{
    response.set_store_birthday(rpcResponse.storeBirthday);

    if (rpcResponse.commit) {
        auto& commit = *response.mutable_commit();
        for (const auto& entry : rpcResponse.commit->entries) {
            auto& entryResponse = *commit.add_entryresponse();
            entryResponse.set_response_type(entryResponseFromSyncResult(entry.result));
            entryResponse.set_id_string(entry.id);
            entryResponse.set_version(entry.version);
        }
        response.set_error_code(sync_pb::SyncEnums::SUCCESS);
        return;
    }

    if (rpcResponse.getUpdates) {
        auto& getUpdates = *response.mutable_get_updates();
        getUpdates.set_changes_remaining(static_cast<int64_t>(rpcResponse.getUpdates->changesRemaining));
        for (const auto& record : rpcResponse.getUpdates->entries)
            fillSyncEntity(record, *getUpdates.add_entries());
        for (const auto& marker : rpcResponse.getUpdates->progressMarkers) {
            auto& protoMarker = *getUpdates.add_new_progress_marker();
            protoMarker.set_data_type_id(specificsFieldNumberFromDataType(marker.type));
            protoMarker.set_token(marker.token);
        }
        response.set_error_code(errorTypeFromSyncResult(rpcResponse.result));
        return;
    }

    if (rpcResponse.clearedServerData) {
        response.mutable_clear_server_data();
        response.set_error_code(sync_pb::SyncEnums::SUCCESS);
        return;
    }

    response.set_error_code(errorTypeFromSyncResult(rpcResponse.result));
}

} // namespace ng
