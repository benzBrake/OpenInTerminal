cmake_minimum_required(VERSION 3.24)
project(OpenInTerminal VERSION 0.1.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(CTest)

set(JSON_INCLUDE_DIR "" CACHE PATH "Directory containing nlohmann/json.hpp")
if(NOT JSON_INCLUDE_DIR)
    set(JSON_INCLUDE_DIR "${CMAKE_BINARY_DIR}/dependencies")
    file(MAKE_DIRECTORY "${JSON_INCLUDE_DIR}/nlohmann")
    file(DOWNLOAD
        "https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp"
        "${JSON_INCLUDE_DIR}/nlohmann/json.hpp"
        EXPECTED_HASH SHA256=9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6
        TLS_VERIFY ON)
endif()

add_library(terminal_core STATIC src/core.cpp)
target_include_directories(terminal_core PUBLIC src)
target_include_directories(terminal_core SYSTEM PRIVATE "${JSON_INCLUDE_DIR}")
if(MSVC)
    target_compile_options(terminal_core PUBLIC /utf-8 /W4 /permissive- /EHsc)
else()
    target_compile_options(terminal_core PUBLIC -Wall -Wextra -Wpedantic)
endif()

if(WIN32)
    add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
    add_library(terminal_windows STATIC src/windows.cpp)
    target_include_directories(terminal_windows SYSTEM PRIVATE "${JSON_INCLUDE_DIR}")
    target_link_libraries(terminal_windows PUBLIC terminal_core ole32 shell32 shlwapi uuid)

    add_library(OpenInTerminal SHARED src/shell_extension.cpp src/OpenInTerminal.def)
    target_link_libraries(OpenInTerminal PRIVATE terminal_windows)
    set_target_properties(OpenInTerminal PROPERTIES PREFIX "")

    add_executable(OpenInTerminalCli src/cli.cpp)
    target_link_libraries(OpenInTerminalCli PRIVATE terminal_windows)

    if(MINGW)
        # No MinGW DLLs are installed into Explorer or required by the user.
        target_link_options(OpenInTerminal PRIVATE -static -static-libgcc -static-libstdc++)
        target_link_options(OpenInTerminalCli PRIVATE -municode -static -static-libgcc -static-libstdc++)
    endif()

    if(BUILD_TESTING)
        add_executable(shell_tests tests/shell_tests.cpp)
        target_link_libraries(shell_tests PRIVATE terminal_windows)
        if(MINGW)
            target_link_options(shell_tests PRIVATE -municode -static -static-libgcc -static-libstdc++)
        endif()
        add_test(NAME shell COMMAND shell_tests $<TARGET_FILE:OpenInTerminal>)
    endif()
endif()

if(BUILD_TESTING)
    add_executable(core_tests tests/core_tests.cpp)
    target_link_libraries(core_tests PRIVATE terminal_core)
    if(MINGW)
        target_link_options(core_tests PRIVATE -static -static-libgcc -static-libstdc++)
    endif()
    add_test(NAME core COMMAND core_tests)
endif()

