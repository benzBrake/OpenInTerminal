#!/bin/sh
set -eu
cd /workspace
cmake -S . -B build/native -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DJSON_INCLUDE_DIR=/opt/openinterminal/include
cmake --build build/native --parallel
ctest --test-dir build/native --output-on-failure
cmake -S . -B build/windows-x64 -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-x64.cmake \
    -DJSON_INCLUDE_DIR=/opt/openinterminal/include
cmake --build build/windows-x64 --parallel
mkdir -p dist/x64
cp build/windows-x64/OpenInTerminal.dll build/windows-x64/OpenInTerminalCli.exe dist/x64/
cp build/windows-x64/shell_tests.exe build/windows-x64/core_tests.exe dist/x64/

