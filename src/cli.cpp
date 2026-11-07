#include "windows.hpp"
#include "com_ptr.hpp"
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <iostream>
#include <stdexcept>

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc > 2 && std::wstring_view(argv[1]) == L"--settings") {
            SetEnvironmentVariableW(L"OIT_SETTINGS_PATH", argv[2]);
            argc -= 2; argv += 2;
        }
        if (argc >= 2 && std::wstring_view(argv[1]) == L"--command") {
            if (argc != 4) return 2;
            std::cout << oit::Utf8(oit::TerminalArguments(argv[2], argv[3])) << '\n';
            return 0;
        }
        const bool invoke = argc == 4 && std::wstring_view(argv[1]) == L"--invoke";
        if (invoke || (argc == 2 && std::wstring_view(argv[1]) == L"--diagnose")) {
            const auto initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            if (FAILED(initialized)) return 1;
            int status = 0;
            {
                oit::ComPtr<IExplorerCommand> root;
                const auto hr = CoCreateInstance(oit::CommandClsid, nullptr, CLSCTX_LOCAL_SERVER, IID_IExplorerCommand, reinterpret_cast<void**>(root.put()));
                if (FAILED(hr)) { std::cerr << "Packaged COM activation failed: " << std::hex << hr << '\n'; status = 1; }
                else {
                    if (invoke) {
                        oit::ComPtr<IEnumExplorerCommand> enumerator;
                        auto result = root->EnumSubCommands(enumerator.put());
                        const auto index = static_cast<ULONG>(std::stoul(argv[2]));
                        if (SUCCEEDED(result) && index) result = enumerator->Skip(index);
                        oit::ComPtr<IExplorerCommand> child;
                        if (result == S_OK) result = enumerator->Next(1, child.put(), nullptr);
                        oit::ComPtr<IShellItem> folder;
                        if (result == S_OK) result = SHCreateItemFromParsingName(argv[3], nullptr, IID_IShellItem, reinterpret_cast<void**>(folder.put()));
                        oit::ComPtr<IShellItemArray> selection;
                        if (result == S_OK) result = SHCreateShellItemArrayFromShellItem(folder.get(), IID_IShellItemArray, reinterpret_cast<void**>(selection.put()));
                        if (result == S_OK) result = child->Invoke(selection.get(), nullptr);
                        std::cout << "Invoke HRESULT: 0x" << std::hex << static_cast<unsigned long>(result) << '\n';
                        if (result != S_OK) status = 1;
                    } else {
                    const auto print = [](IExplorerCommand* command) {
                        PWSTR title = nullptr, icon = nullptr, tip = nullptr;
                        command->GetTitle(nullptr, &title);
                        command->GetIcon(nullptr, &icon);
                        command->GetToolTip(nullptr, &tip);
                        std::cout << (title ? oit::Utf8(title) : "(no title)") << "\n  Icon: " << (icon ? oit::Utf8(icon) : "(none)") << '\n';
                        if (tip) std::cout << "  Tooltip: " << oit::Utf8(tip) << '\n';
                        if (icon) {
                            std::wstring location(icon);
                            const auto index = PathParseIconLocationW(location.data());
                            HICON large = nullptr;
                            const auto count = ExtractIconExW(location.c_str(), index, &large, nullptr, 1);
                            std::cout << "  Icon extraction: " << (count && large ? "OK" : "FAILED") << '\n';
                            if (large) DestroyIcon(large);
                        }
                        CoTaskMemFree(title); CoTaskMemFree(icon); CoTaskMemFree(tip);
                    };
                    print(root.get());
                    oit::ComPtr<IEnumExplorerCommand> enumerator;
                    if (SUCCEEDED(root->EnumSubCommands(enumerator.put()))) {
                        oit::ComPtr<IExplorerCommand> child;
                        while (enumerator->Next(1, child.put(), nullptr) == S_OK) print(child.get());
                    }
                    }
                }
            }
            CoUninitialize();
            return status;
        }
        if (argc < 2 || std::wstring_view(argv[1]) != L"--list") {
            std::cout << "OpenInTerminalCli [--settings <settings.json>] --list\n"
                         "OpenInTerminalCli [--settings <settings.json>] --command <profile-id> <directory>\n"
                         "OpenInTerminalCli --diagnose\n"
                         "OpenInTerminalCli --invoke <profile-index> <directory>\n";
            return argc < 2 ? 0 : 2;
        }
        const auto terminal = oit::LoadTerminal();
        std::cout << "Settings: " << oit::Utf8(terminal.settings.native()) << '\n';
        std::cout << "Terminal: " << oit::Utf8(terminal.executable.native()) << '\n';
        if (!terminal.error.empty()) throw std::runtime_error(terminal.error);
        for (const auto& profile : terminal.profiles) std::cout << profile.name << "\t" << profile.id << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
