#include "windows.hpp"
#include <shellapi.h>
#include <shlobj.h>
#include <bit>
#include <fstream>
#include <algorithm>
#include <chrono>
#include <mutex>
#include <stdexcept>
#include <nlohmann/json.hpp>

namespace oit {
std::wstring Utf16(std::string_view value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (!size) throw std::runtime_error("Invalid UTF-8");
    std::wstring output(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), output.data(), size);
    return output;
}
std::string Utf8(std::wstring_view value) {
    if (value.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("Invalid UTF-16");
    std::string output(size, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), output.data(), size, nullptr, nullptr);
    return output;
}
std::wstring Environment(const wchar_t* name) {
    const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
    if (!size) return {};
    std::wstring output(size, L'\0');
    const DWORD copied = GetEnvironmentVariableW(name, output.data(), size);
    if (copied >= size) return {};
    output.resize(copied);
    return output;
}
std::wstring Expand(std::wstring_view value) {
    const std::wstring input(value);
    const DWORD size = ExpandEnvironmentStringsW(input.c_str(), nullptr, 0);
    if (!size) return input;
    std::wstring output(size, L'\0');
    if (ExpandEnvironmentStringsW(input.c_str(), output.data(), size) != size) return input;
    output.resize(size - 1);
    return output;
}
std::string ReadFile(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read " + Utf8(path.native()));
    stream.seekg(0, std::ios::end);
    const auto length = stream.tellg();
    if (length < 0 || length > 4 * 1024 * 1024) throw std::runtime_error("Settings file exceeds 4 MiB");
    std::string text(static_cast<size_t>(length), '\0');
    stream.seekg(0);
    if (!text.empty() && !stream.read(text.data(), static_cast<std::streamsize>(text.size())))
        throw std::runtime_error("Cannot read settings completely");
    return text;
}

static bool Exists(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error);
}

static bool ExecutableExists(const std::filesystem::path& path) {
    // App execution aliases are APPEXECLINK reparse points. MSVC's
    // is_regular_file rejects them even though ShellExecute can launch them.
    // Inspect the entry itself rather than classifying its reparse target.
    const auto attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static std::filesystem::path PackageLocation(const std::wstring& family) {
    using ListPackages = LONG (WINAPI*)(PCWSTR, UINT32*, PWSTR*, UINT32*, PWSTR);
    using PackagePath = LONG (WINAPI*)(PCWSTR, UINT32*, PWSTR);
    const auto kernel = GetModuleHandleW(L"kernel32.dll");
    const auto GetPackagesByPackageFamily = std::bit_cast<ListPackages>(GetProcAddress(kernel, "GetPackagesByPackageFamily"));
    const auto GetPackagePathByFullName = std::bit_cast<PackagePath>(GetProcAddress(kernel, "GetPackagePathByFullName"));
    if (!GetPackagesByPackageFamily || !GetPackagePathByFullName) return {};
    UINT32 count = 0, size = 0;
    if (GetPackagesByPackageFamily(family.c_str(), &count, nullptr, &size, nullptr) != ERROR_INSUFFICIENT_BUFFER) return {};
    std::vector<PWSTR> names(count);
    std::vector<wchar_t> buffer(size);
    if (GetPackagesByPackageFamily(family.c_str(), &count, names.data(), &size, buffer.data()) != ERROR_SUCCESS) return {};
    for (auto name : names) {
        UINT32 length = 0;
        if (GetPackagePathByFullName(name, &length, nullptr) != ERROR_INSUFFICIENT_BUFFER) continue;
        std::vector<wchar_t> path(length);
        if (GetPackagePathByFullName(name, &length, path.data()) == ERROR_SUCCESS &&
            Exists(std::filesystem::path(path.data()) / L"WindowsTerminal.exe")) return path.data();
    }
    return {};
}

Terminal LoadTerminal() {
    Terminal result;
    try {
        const auto local = std::filesystem::path(Environment(L"LOCALAPPDATA"));
        auto channel = std::wstring(L"stable");
        auto settingsOverride = Environment(L"OIT_SETTINGS_PATH");
        auto executableOverride = Environment(L"OIT_TERMINAL_PATH");
        const auto configPath = local / L"OpenInTerminal" / L"config.json";
        if (Exists(configPath)) {
            const auto config = nlohmann::json::parse(NormalizeJsonc(ReadFile(configPath)));
            channel = Utf16(config.value("channel", "stable"));
            if (settingsOverride.empty()) settingsOverride = Expand(Utf16(config.value("settingsPath", "")));
            if (executableOverride.empty()) executableOverride = Expand(Utf16(config.value("terminalPath", "")));
        }
        std::wstring family = L"Microsoft.WindowsTerminal_8wekyb3d8bbwe";
        if (channel == L"preview") family = L"Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe";
        else if (channel == L"canary") family = L"Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe";
        else if (channel != L"stable") throw std::runtime_error("Unknown Terminal channel");

        result.package = PackageLocation(family);
        result.settings = local / L"Packages" / family / L"LocalState" / L"settings.json";
        if (!settingsOverride.empty()) result.settings = settingsOverride;
        else if (!Exists(result.settings) && channel == L"stable") {
            const auto unpackaged = local / L"Microsoft" / L"Windows Terminal" / L"settings.json";
            if (Exists(unpackaged)) result.settings = unpackaged;
        }
        if (!executableOverride.empty()) result.executable = executableOverride;
        else {
            // App execution aliases activate the packaged application correctly.
            // Directly executing the protected WindowsApps binary can fail with
            // ERROR_ACCESS_DENIED, even though its icons are readable.
            const auto aliases = local / L"Microsoft" / L"WindowsApps";
            result.executable = aliases / family / L"wt.exe";
            if (!ExecutableExists(result.executable)) {
                if (channel == L"stable") result.executable = aliases / L"wt.exe";
                else throw std::runtime_error("Selected Terminal channel has no wt.exe alias; set terminalPath in config.json");
            }
        }

        if (!ExecutableExists(result.executable)) throw std::runtime_error("Windows Terminal executable was not found: " + Utf8(result.executable.native()));
        result.profiles = ParseProfiles(ReadFile(result.settings));
    } catch (const std::exception& error) {
        result.error = error.what();
    }
    return result;
}

std::shared_ptr<const Terminal> CurrentTerminal() {
    static std::mutex mutex;
    static std::shared_ptr<const Terminal> cached;
    static std::chrono::steady_clock::time_point refreshed;
    const auto now = std::chrono::steady_clock::now();
    std::lock_guard lock(mutex);
    if (!cached || now - refreshed > std::chrono::seconds(2)) {
        cached = std::make_shared<Terminal>(LoadTerminal());
        refreshed = now;
    }
    return cached;
}

static std::wstring PngIcon(const std::filesystem::path& path) {
    try {
        const auto bytes = ReadFile(path);
        if (bytes.size() < 24 || bytes.substr(0, 8) != std::string("\x89PNG\r\n\x1a\n", 8)) return {};
        const auto number = [&](size_t offset) {
            unsigned value = 0;
            for (size_t i = offset; i < offset + 4; ++i) value = value * 256 + static_cast<unsigned char>(bytes[i]);
            return value;
        };
        const auto width = number(16), height = number(20);
        if (!width || width > 256 || !height || height > 256) return {};
        // ICO supports a PNG payload directly; retain the original profile art.
        std::error_code error;
        const auto stamp = std::filesystem::last_write_time(path, error).time_since_epoch().count();
        const auto key = Utf8(path.native()) + std::to_string(stamp);
        unsigned long long hash = 14695981039346656037ull;
        for (unsigned char ch : key) hash = (hash ^ ch) * 1099511628211ull;
        auto local = std::filesystem::path(Environment(L"LOCALAPPDATA"));
        using PackageFamily = LONG (WINAPI*)(UINT32*, PWSTR);
        const auto familyName = std::bit_cast<PackageFamily>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "GetCurrentPackageFamilyName"));
        UINT32 length = 0;
        if (familyName && familyName(&length, nullptr) == ERROR_INSUFFICIENT_BUFFER) {
            std::vector<wchar_t> family(length);
            if (familyName(&length, family.data()) == ERROR_SUCCESS)
                local /= std::filesystem::path(L"Packages") / family.data() / L"LocalCache" / L"Local";
        }
        // Return a physical cache path that Explorer can read outside our package.
        const auto cache = local / L"OpenInTerminal" / L"IconCache";
        std::filesystem::create_directories(cache, error);
        const auto output = cache / (std::to_wstring(hash) + L".ico");
        if (Exists(output)) return output.native();
        std::ofstream stream(output, std::ios::binary);
        const auto write = [&](unsigned value, int count) {
            for (int i = 0; i < count; ++i) stream.put(static_cast<char>((value >> (i * 8)) & 0xff));
        };
        write(0, 2); write(1, 2); write(1, 2);
        write(width % 256, 1); write(height % 256, 1); write(0, 1); write(0, 1);
        write(1, 2); write(32, 2); write(static_cast<unsigned>(bytes.size()), 4); write(22, 4);
        stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        return stream ? output.native() : L"";
    } catch (...) { return {}; }
}

std::wstring ProfileIcon(const Terminal& terminal, const Profile* profile) {
    if (profile && !profile->icon.empty() && profile->icon != "none") {
        auto value = Expand(Utf16(profile->icon));
        auto replacePrefix = [&](std::wstring_view prefix, const std::filesystem::path& base) {
            if (value.starts_with(prefix)) {
                value = (base / value.substr(prefix.size())).native();
                std::replace(value.begin(), value.end(), L'/', L'\\');
            }
        };
        if (!terminal.package.empty()) replacePrefix(L"ms-appx:///", terminal.package);
        replacePrefix(L"ms-appdata:///Local/", terminal.settings.parent_path());
        replacePrefix(L"ms-appdata:///Roaming/", terminal.settings.parent_path().parent_path() / L"RoamingState");
        const auto extension = std::filesystem::path(value).extension().native();
        if ((extension == L".ico" || extension == L".exe" || extension == L".dll") && Exists(value)) return value;
        if (extension == L".png" && Exists(value)) {
            const auto converted = PngIcon(value);
            if (!converted.empty()) return converted;
        }
    }
    if (profile && profile->icon != "none" && !terminal.package.empty()) {
        const auto png = terminal.package / L"ProfileIcons" / (Utf16(profile->id) + L".scale-200.png");
        if (Exists(png)) {
            const auto converted = PngIcon(png);
            if (!converted.empty()) return converted;
        }
    }
    auto iconExe = terminal.package / L"WindowsTerminal.exe";
    if (Exists(iconExe)) return iconExe.native() + L",-101";
    return Expand(L"%SystemRoot%\\System32\\cmd.exe") + L",0";
}

HRESULT LaunchTerminal(const Terminal& terminal, const Profile* profile, const std::wstring& directory, bool elevated, HWND owner) {
    const auto arguments = TerminalArguments(profile ? Utf16(profile->id) : L"", directory);
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    info.hwnd = owner;
    info.lpVerb = elevated ? L"runas" : L"open";
    info.lpFile = terminal.executable.c_str();
    info.lpParameters = arguments.c_str();
    info.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&info) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}
}
