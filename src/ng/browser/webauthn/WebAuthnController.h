#pragma once

#include "core/Origin.h"
#include "core/Result.h"

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace ng {

using ByteVector = std::vector<uint8_t>;

enum class UserVerificationRequirement {
    Required,
    Preferred,
    Discouraged,
};

enum class AuthenticatorAttachment {
    Any,
    Platform,
    CrossPlatform,
};

struct PublicKeyCredentialDescriptor {
    std::string type;
    ByteVector id;
    std::vector<std::string> transports;
};

struct WebAuthnGetRequest {
    FrameContext frame;
    std::string relyingPartyId;
    ByteVector challenge;
    std::vector<PublicKeyCredentialDescriptor> allowCredentials;
    UserVerificationRequirement userVerification { UserVerificationRequirement::Preferred };
    AuthenticatorAttachment attachment { AuthenticatorAttachment::Any };
    std::chrono::milliseconds timeout { 60000 };
};

struct WebAuthnAssertion {
    ByteVector credentialId;
    ByteVector authenticatorData;
    ByteVector clientDataJSON;
    ByteVector signature;
    ByteVector userHandle;
};

class PlatformWebAuthnProvider {
public:
    virtual ~PlatformWebAuthnProvider() = default;
    virtual Result<WebAuthnAssertion> getAssertion(const WebAuthnGetRequest&) = 0;
};

class WebAuthnController {
public:
    explicit WebAuthnController(PlatformWebAuthnProvider&);

    Result<WebAuthnAssertion> get(const WebAuthnGetRequest&);

private:
    Result<void> validateGetRequest(const WebAuthnGetRequest&) const;

    PlatformWebAuthnProvider& m_provider;
};

} // namespace ng

