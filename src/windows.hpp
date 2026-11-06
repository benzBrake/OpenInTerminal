#pragma once
#include "core.hpp"
#include <windows.h>
#include <filesystem>
#include <memory>

namespace oit {
inline constexpr CLSID CommandClsid{0xa763e1d5, 0x05eb, 0x43a3, {0x9c, 0x82, 0x7d, 0xa5, 0xb8, 0x6f, 0x6b, 0x41}};
struct Terminal {
    std::filesystem::path settings;
    std::filesystem::path executable;
    std::filesystem::path package;
    std::vector<Profile> profiles;
    std::string error;
};
std::wstring Utf16(std::string_view value);
std::string Utf8(std::wstring_view value);
std::wstring Environment(const wchar_t* name);
std::wstring Expand(std::wstring_view value);
std::string ReadFile(const std::filesystem::path& path);
Terminal LoadTerminal();
std::shared_ptr<const Terminal> CurrentTerminal();
std::wstring ProfileIcon(const Terminal& terminal, const Profile* profile);
HRESULT LaunchTerminal(const Terminal& terminal, const Profile* profile,
                       const std::wstring& directory, bool elevated, HWND owner);
}

