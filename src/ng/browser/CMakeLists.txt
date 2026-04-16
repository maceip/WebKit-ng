cmake_minimum_required(VERSION 3.16)
project(ng_browser_core LANGUAGES CXX)

find_package(Protobuf REQUIRED)

get_filename_component(NG_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)

file(GLOB NG_CHROMIUM_SYNC_PROTOS
    "${NG_REPO_ROOT}/third_party/chromium_sync_loopback/components/sync/protocol/*.proto"
)

set(NG_SYNC_PROTO_GENERATED_SOURCES)
set(NG_SYNC_PROTO_GENERATED_HEADERS)
foreach(proto_file IN LISTS NG_CHROMIUM_SYNC_PROTOS)
    file(RELATIVE_PATH proto_relative "${NG_REPO_ROOT}/third_party/chromium_sync_loopback" "${proto_file}")
    set(generated_source "${CMAKE_CURRENT_BINARY_DIR}/generated/${proto_relative}")
    string(REPLACE ".proto" ".pb.cc" generated_source "${generated_source}")
    set(generated_header "${CMAKE_CURRENT_BINARY_DIR}/generated/${proto_relative}")
    string(REPLACE ".proto" ".pb.h" generated_header "${generated_header}")

    add_custom_command(
        OUTPUT "${generated_source}" "${generated_header}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
        COMMAND protobuf::protoc
            -I
            "${NG_REPO_ROOT}/third_party/chromium_sync_loopback"
            --cpp_out
            "${CMAKE_CURRENT_BINARY_DIR}/generated"
            "${proto_file}"
        DEPENDS "${proto_file}"
        VERBATIM
    )

    list(APPEND NG_SYNC_PROTO_GENERATED_SOURCES "${generated_source}")
    list(APPEND NG_SYNC_PROTO_GENERATED_HEADERS "${generated_header}")
endforeach()

add_library(ng_chromium_sync_proto STATIC
    ${NG_SYNC_PROTO_GENERATED_SOURCES}
    ${NG_SYNC_PROTO_GENERATED_HEADERS}
)

target_link_libraries(ng_chromium_sync_proto PUBLIC protobuf::libprotobuf)
target_include_directories(ng_chromium_sync_proto SYSTEM PUBLIC
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)

if (MSVC)
    target_compile_options(ng_chromium_sync_proto PRIVATE /wd4996)
else()
    target_compile_options(ng_chromium_sync_proto PRIVATE -Wno-deprecated-declarations)
endif()

add_library(ng_browser_core STATIC
    core/Origin.cpp
    extensions/ExtensionManifest.cpp
    extensions/ExtensionRegistry.cpp
    extensions/ExtensionRuntime.cpp
    sync/ChromiumSyncWireAdapter.cpp
    sync/LoopbackSyncClient.cpp
    sync/LoopbackSyncRpc.cpp
    sync/LoopbackSyncServer.cpp
    sync/SyncTypes.cpp
    tabs/BrowserCommandController.cpp
    tabs/BrowserStateModel.cpp
    webauthn/WebAuthnController.cpp
)

target_compile_features(ng_browser_core PUBLIC cxx_std_17)
target_include_directories(ng_browser_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(ng_browser_core PUBLIC ng_chromium_sync_proto)

if (MSVC)
    target_compile_options(ng_browser_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(ng_browser_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()

add_executable(ng_browser_core_smoke
    tests/BrowserCoreSmoke.cpp
)

target_link_libraries(ng_browser_core_smoke PRIVATE ng_browser_core)
add_test(NAME ng_browser_core_smoke COMMAND ng_browser_core_smoke)

add_executable(ng_loopback_sync_test
    tests/LoopbackSyncTest.cpp
)

target_link_libraries(ng_loopback_sync_test PRIVATE ng_browser_core)
add_test(NAME ng_loopback_sync_test COMMAND ng_loopback_sync_test)

add_executable(ng_chromium_sync_wire_test
    tests/ChromiumSyncWireAdapterTest.cpp
)

target_link_libraries(ng_chromium_sync_wire_test PRIVATE ng_browser_core)
add_test(NAME ng_chromium_sync_wire_test COMMAND ng_chromium_sync_wire_test)
