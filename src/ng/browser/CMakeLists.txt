cmake_minimum_required(VERSION 3.16)
project(ng_browser_core LANGUAGES CXX)

add_library(ng_browser_core STATIC
    core/Origin.cpp
    extensions/ExtensionManifest.cpp
    extensions/ExtensionRegistry.cpp
    extensions/ExtensionRuntime.cpp
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
