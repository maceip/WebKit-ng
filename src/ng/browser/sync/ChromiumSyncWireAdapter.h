#pragma once

#include "sync/LoopbackSyncRpc.h"

namespace sync_pb {
class ClientToServerMessage;
class ClientToServerResponse;
class EntitySpecifics;
class SyncEntity;
} // namespace sync_pb

namespace ng {

class ChromiumSyncWireAdapter {
public:
    explicit ChromiumSyncWireAdapter(LoopbackSyncRpcEndpoint&);

    ChromiumSyncWireResponse handleWireCommand(const ChromiumSyncWireRequest&);

private:
    bool decodeRequest(const sync_pb::ClientToServerMessage&, LoopbackSyncRpcRequest&) const;
    void encodeResponse(const LoopbackSyncRpcResponse&, sync_pb::ClientToServerResponse&) const;

    LoopbackSyncRpcEndpoint& m_endpoint;
};

} // namespace ng

