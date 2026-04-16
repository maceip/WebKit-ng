#pragma once

#include "sync/LoopbackSyncServer.h"

#include <optional>
#include <string>
#include <vector>

namespace ng {

enum class LoopbackSyncRpcMethod {
    GetUpdates,
    Commit,
    ClearServerData,
};

struct LoopbackSyncRpcRequest {
    LoopbackSyncRpcMethod method { LoopbackSyncRpcMethod::GetUpdates };
    std::optional<GetUpdatesRequest> getUpdates;
    std::optional<CommitRequest> commit;
};

struct LoopbackSyncRpcResponse {
    SyncResult result { SyncResult::Success };
    std::string storeBirthday;
    std::optional<GetUpdatesResponse> getUpdates;
    std::optional<CommitResponse> commit;
    bool clearedServerData { false };
};

struct ChromiumSyncWireRequest {
    std::string httpMethod { "POST" };
    std::string path { "/command" };
    std::string contentType { "application/octet-stream" };
    std::vector<std::uint8_t> serializedClientToServerMessage;
};

struct ChromiumSyncWireResponse {
    int httpStatus { 200 };
    std::string contentType { "application/octet-stream" };
    std::vector<std::uint8_t> serializedClientToServerResponse;
};

class LoopbackSyncRpcEndpoint {
public:
    virtual ~LoopbackSyncRpcEndpoint() = default;
    virtual LoopbackSyncRpcResponse handleCommand(const LoopbackSyncRpcRequest&) = 0;
};

class LoopbackSyncRpcService final : public LoopbackSyncRpcEndpoint {
public:
    explicit LoopbackSyncRpcService(LoopbackSyncServer&);

    LoopbackSyncRpcResponse handleCommand(const LoopbackSyncRpcRequest&) override;

    static constexpr const char* commandPath() { return "/command"; }
    static constexpr const char* commandHttpMethod() { return "POST"; }
    static constexpr const char* wireContentType() { return "application/octet-stream"; }

private:
    LoopbackSyncServer& m_server;
};

} // namespace ng

