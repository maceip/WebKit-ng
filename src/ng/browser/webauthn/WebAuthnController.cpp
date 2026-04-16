#include "webauthn/WebAuthnController.h"

namespace ng {

WebAuthnController::WebAuthnController(PlatformWebAuthnProvider& provider)
    : m_provider(provider)
{
}

Result<WebAuthnAssertion> WebAuthnController::get(const WebAuthnGetRequest& request)
{
    auto validation = validateGetRequest(request);
    if (!validation)
        return Result<WebAuthnAssertion>::fail(validation.error());

    return m_provider.getAssertion(request);
}

Result<void> WebAuthnController::validateGetRequest(const WebAuthnGetRequest& request) const
{
    if (!request.frame.origin.isPotentiallyTrustworthy())
        return Result<void>::fail({ ErrorCode::PermissionDenied, "WebAuthn requires a trustworthy origin" });
    if (request.relyingPartyId.empty())
        return Result<void>::fail({ ErrorCode::InvalidArgument, "relying party id is required" });
    if (request.challenge.size() < 16)
        return Result<void>::fail({ ErrorCode::InvalidArgument, "challenge must be at least 16 bytes" });
    if (request.timeout.count() <= 0)
        return Result<void>::fail({ ErrorCode::InvalidArgument, "timeout must be positive" });
    if (!request.frame.hasTransientUserActivation)
        return Result<void>::fail({ ErrorCode::PermissionDenied, "WebAuthn request requires user activation" });

    return Result<void>::ok();
}

} // namespace ng

