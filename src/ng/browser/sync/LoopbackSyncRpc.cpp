#include "sync/LoopbackSyncRpc.h"

namespace ng {

LoopbackSyncRpcService::LoopbackSyncRpcService(LoopbackSyncServer& server)
    : m_server(server)
{
}

LoopbackSyncRpcResponse LoopbackSyncRpcService::handleCommand(const LoopbackSyncRpcRequest& request)
{
    LoopbackSyncRpcResponse response;

    switch (request.method) {
    case LoopbackSyncRpcMethod::GetUpdates:
        if (!request.getUpdates) {
            response.result = SyncResult::InvalidRequest;
            response.storeBirthday = m_server.storeBirthday();
            return response;
        }
        response.getUpdates = m_server.getUpdates(*request.getUpdates);
        response.result = response.getUpdates->result;
        response.storeBirthday = response.getUpdates->storeBirthday;
        return response;

    case LoopbackSyncRpcMethod::Commit:
        if (!request.commit) {
            response.result = SyncResult::InvalidRequest;
            response.storeBirthday = m_server.storeBirthday();
            return response;
        }
        response.commit = m_server.commit(*request.commit);
        response.result = response.commit->result;
        response.storeBirthday = response.commit->storeBirthday;
        return response;

    case LoopbackSyncRpcMethod::ClearServerData:
        m_server.clear();
        response.storeBirthday = m_server.storeBirthday();
        response.clearedServerData = true;
        return response;
    }

    response.result = SyncResult::InvalidRequest;
    response.storeBirthday = m_server.storeBirthday();
    return response;
}

} // namespace ng

