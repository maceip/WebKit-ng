#include "extensions/ExtensionRegistry.h"
#include "extensions/ExtensionRuntime.h"
#include "sync/LoopbackSyncClient.h"
#include "tabs/BrowserCommandController.h"
#include "webauthn/WebAuthnController.h"

#include <cassert>

namespace {

ng::FrameContext trustworthyFrame()
{
    ng::FrameContext frame;
    frame.origin = { "https", "example.com", 0 };
    frame.topLevelOrigin = frame.origin;
    frame.isTopLevel = true;
    frame.hasTransientUserActivation = true;
    return frame;
}

class TestWebAuthnProvider final : public ng::PlatformWebAuthnProvider {
public:
    ng::Result<ng::WebAuthnAssertion> getAssertion(const ng::WebAuthnGetRequest& request) final
    {
        ng::WebAuthnAssertion assertion;
        assertion.credentialId = request.allowCredentials.empty() ? ng::ByteVector { 1, 2, 3 } : request.allowCredentials.front().id;
        assertion.authenticatorData = { 4, 5, 6 };
        assertion.clientDataJSON = { 7, 8, 9 };
        assertion.signature = { 10, 11, 12 };
        return ng::Result<ng::WebAuthnAssertion>::ok(std::move(assertion));
    }
};

void exerciseTabs()
{
    ng::BrowserStateModel state;
    ng::BrowserCommandController commands(state);
    auto window = commands.newWindow(ng::TabStripMode::Vertical);
    auto tab = commands.newTab(window, "https://example.com", true);
    assert(tab);
    assert(state.window(window)->tabStripMode == ng::TabStripMode::Vertical);
    assert(state.tab(tab.value())->active);
    assert(commands.useHorizontalTabs(window));
    assert(state.window(window)->tabStripMode == ng::TabStripMode::Horizontal);
}

void exerciseExtensions()
{
    ng::ExtensionRegistry registry;
    ng::ExtensionManifest manifest;
    manifest.id = "test-extension";
    manifest.version = ng::ExtensionManifestVersion::ManifestV3;
    manifest.name = "Test Extension";
    manifest.versionString = "1.0.0";
    manifest.sidePanel.defaultPath = "sidepanel.html";
    assert(registry.install(manifest));

    ng::BrowserStateModel state;
    ng::BrowserCommandController commands(state);
    ng::ExtensionRuntime runtime(registry, commands);
    assert(runtime.registerHandler("test-extension", "runtime.sendMessage", [](const ng::ExtensionMessage&) {
        return ng::Result<ng::ExtensionMessageResponse>::ok({ "ok" });
    }));

    ng::ExtensionMessage message;
    message.extensionId = "test-extension";
    message.frame = trustworthyFrame();
    message.channel = "runtime.sendMessage";
    auto response = runtime.dispatch(message);
    assert(response);
    assert(response.value().payload == "ok");
}

void exerciseWebAuthn()
{
    TestWebAuthnProvider provider;
    ng::WebAuthnController controller(provider);

    ng::WebAuthnGetRequest request;
    request.frame = trustworthyFrame();
    request.relyingPartyId = "example.com";
    request.challenge = ng::ByteVector(32, 7);

    auto assertion = controller.get(request);
    assert(assertion);
    assert(!assertion.value().signature.empty());
}

void exerciseSync()
{
    ng::LoopbackSyncServer server;
    ng::LoopbackSyncClient first("first");
    ng::LoopbackSyncClient second("second");

    first.trackDataType(ng::SyncDataType::Bookmarks);
    second.trackDataType(ng::SyncDataType::Bookmarks);

    first.upsertLocal(ng::SyncDataType::Bookmarks, "bookmark-a", "Example", "https://example.test");
    assert(first.sync(server) == ng::SyncResult::Success);
    assert(second.sync(server) == ng::SyncResult::Success);

    const auto id = ng::LoopbackSyncServer::createId(ng::SyncDataType::Bookmarks, "bookmark-a");
    auto synced = second.localRecord(id);
    assert(synced);
    assert(synced->name == "Example");
    assert(synced->payload == "https://example.test");
}

} // namespace

int main()
{
    exerciseTabs();
    exerciseExtensions();
    exerciseWebAuthn();
    exerciseSync();
    return 0;
}
