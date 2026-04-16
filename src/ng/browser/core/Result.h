#pragma once

#include <string>
#include <utility>

namespace ng {

enum class ErrorCode {
    None,
    InvalidArgument,
    NotFound,
    PermissionDenied,
    Unsupported,
    PlatformFailure,
    InternalError,
};

struct Error {
    ErrorCode code { ErrorCode::None };
    std::string message;

    explicit operator bool() const { return code != ErrorCode::None; }
};

template<typename T>
class Result {
public:
    static Result ok(T value) { return Result(std::move(value)); }
    static Result fail(Error error) { return Result(std::move(error)); }

    bool hasValue() const { return !m_error; }
    explicit operator bool() const { return hasValue(); }

    const T& value() const { return m_value; }
    T& value() { return m_value; }
    const Error& error() const { return m_error; }

private:
    explicit Result(T value)
        : m_value(std::move(value))
    {
    }

    explicit Result(Error error)
        : m_error(std::move(error))
    {
    }

    T m_value { };
    Error m_error { };
};

template<>
class Result<void> {
public:
    static Result ok() { return Result(); }
    static Result fail(Error error) { return Result(std::move(error)); }

    bool hasValue() const { return !m_error; }
    explicit operator bool() const { return hasValue(); }
    const Error& error() const { return m_error; }

private:
    Result() = default;
    explicit Result(Error error)
        : m_error(std::move(error))
    {
    }

    Error m_error { };
};

} // namespace ng

