#include "core/Origin.h"

#include <sstream>

namespace ng {

bool Origin::isPotentiallyTrustworthy() const
{
    return scheme == "https" || host == "localhost" || host == "127.0.0.1" || host == "::1";
}

std::string Origin::serialize() const
{
    std::ostringstream out;
    out << scheme << "://" << host;
    if (port)
        out << ':' << port;
    return out.str();
}

} // namespace ng

