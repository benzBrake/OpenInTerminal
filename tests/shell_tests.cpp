#include "windows.hpp"
#include "com_ptr.hpp"
#include <shlobj.h>
#include <shobjidl.h>
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <bit>
#include <chrono>
#include <thread>

using oit::ComPtr;
static void Check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void Ok(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("COM operation failed: " + std::to_string(static_cast<unsigned long>(hr))); }

int wmain(int argc, wchar_t** argv) {
    const auto capture = oit::Environment(L"OIT_TEST_CAPTURE");
    if (!capture.empty()) {
        std::ofstream stream(std::filesystem::path(capture), std::ios::binary);
        for (int i = 1; i < argc; ++i) stream << oit::Utf8(argv[i]) << '\n';
        return stream ? 0 : 1;
    }
    if (argc != 2) return 2;
    const auto initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HMODULE dll = nullptr;
    std::filesystem::path temporary;
    int result = 0;
    try {
        Ok(initialized);
        wchar_t temp[MAX_PATH];
        GetTempPathW(MAX_PATH, temp);
        temporary = std::filesystem::path(temp) / (L"OpenInTerminal 测试 & ;(test)-" + std::to_wstring(GetCurrentProcessId()));
        std::filesystem::create_directories(temporary);
        const auto settings = temporary / L"settings.json";
        std::ofstream(settings) << R"({"profiles":{"list":[{"name":"测试 & PowerShell","guid":"{574e775e-4f2a-5b96-ac1e-a2962a402336}"},{"name":"hidden","hidden":true}]}})";
        SetEnvironmentVariableW(L"OIT_SETTINGS_PATH", settings.c_str());
        wchar_t executable[32768];
        GetModuleFileNameW(nullptr, executable, 32768);
        SetEnvironmentVariableW(L"OIT_TERMINAL_PATH", executable);
        dll = LoadLibraryW(argv[1]);
        Check(dll, "DLL could not be loaded (missing runtime dependency?)");
        auto getClass = std::bit_cast<HRESULT (WINAPI*)(REFCLSID, REFIID, void**)>(GetProcAddress(dll, "DllGetClassObject"));
        auto canUnload = std::bit_cast<HRESULT (WINAPI*)()>(GetProcAddress(dll, "DllCanUnloadNow"));
        Check(getClass && canUnload, "COM exports missing");
        Check(canUnload() == S_OK, "Unexpected initial references");
        {
            ComPtr<IClassFactory> factory;
            Ok(getClass(oit::CommandClsid, IID_IClassFactory, reinterpret_cast<void**>(factory.put())));
            ComPtr<IExplorerCommand> root;
            Ok(factory->CreateInstance(nullptr, IID_IExplorerCommand, reinterpret_cast<void**>(root.put())));
            EXPCMDFLAGS flags{};
            Ok(root->GetFlags(&flags));
            Check(flags == ECF_HASSUBCOMMANDS, "Root is not a submenu");
            Check(root->GetTitle(nullptr, nullptr) == E_POINTER, "Null output not validated");
            ComPtr<IEnumExplorerCommand> children;
            Ok(root->EnumSubCommands(children.put()));
            ComPtr<IExplorerCommand> child;
            ULONG count = 0;
            Ok(children->Next(1, child.put(), &count));
            Check(count == 1, "Profile enumeration failed");
            PWSTR title = nullptr;
            Ok(child->GetTitle(nullptr, &title));
            const std::wstring copied(title);
            CoTaskMemFree(title);
            Check(copied == L"测试 && PowerShell", "UTF-8 title or ampersand escaping failed");
            Ok(child->GetFlags(&flags));
            Check(flags == ECF_DEFAULT, "Nested submenu created");
            ComPtr<IExplorerCommand> end;
            Check(children->Next(1, end.put(), &count) == S_FALSE && count == 0, "Hidden profile was exposed");
            Ok(children->Reset());
            ComPtr<IEnumExplorerCommand> cloned;
            Ok(children->Clone(cloned.put()));
            Ok(cloned->Skip(1));
            Check(cloned->Skip(1) == S_FALSE, "Enumerator Skip is incorrect");
            ComPtr<IShellItem> folder;
            Ok(SHCreateItemFromParsingName(temporary.c_str(), nullptr, IID_IShellItem, reinterpret_cast<void**>(folder.put())));
            ComPtr<IShellItemArray> selection;
            Ok(SHCreateShellItemArrayFromShellItem(folder.get(), IID_IShellItemArray, reinterpret_cast<void**>(selection.put())));
            EXPCMDSTATE state{};
            Ok(root->GetState(selection.get(), TRUE, &state));
            Check(state == ECS_ENABLED, "Filesystem folder disabled");
            // Exercise the actual submenu Invoke and ShellExecute, including an
            // empty background selection. The test executable captures argv in
            // a child process instead of opening the user's configured shell.
            const auto output = temporary / L"captured.txt";
            SetEnvironmentVariableW(L"OIT_TEST_CAPTURE", output.c_str());
            const auto invoked = child->Invoke(nullptr, nullptr);
            SetEnvironmentVariableW(L"OIT_TEST_CAPTURE", nullptr);
            Ok(invoked);
            std::string captured;
            for (int attempt = 0; attempt < 250; ++attempt) {
                std::ifstream input(output, std::ios::binary);
                captured.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
                if (!captured.empty() && captured.back() == '\n') break;
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
            Check(captured.starts_with("-w\nnew\nnew-tab\n--profile\n{574e775e-4f2a-5b96-ac1e-a2962a402336}\n--startingDirectory\n"), "Submenu did not launch the selected profile");
            auto expectedPath = oit::Utf8(temporary.native());
            const auto semicolon = expectedPath.find(';');
            expectedPath.insert(semicolon, "\\");
            Check(captured.ends_with(expectedPath + "\\.\n"), "Directory lost Unicode, escaping, or quoting");
            Ok(root->GetState(nullptr, TRUE, &state));
            Check(state == ECS_HIDDEN, "Virtual location was exposed");
            Check(canUnload() == S_FALSE, "Live COM objects not tracked");
        }
        Check(canUnload() == S_OK, "COM reference leak");
        std::cout << "Windows COM tests passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
    if (dll) FreeLibrary(dll);
    SetEnvironmentVariableW(L"OIT_SETTINGS_PATH", nullptr);
    SetEnvironmentVariableW(L"OIT_TERMINAL_PATH", nullptr);
    SetEnvironmentVariableW(L"OIT_TEST_CAPTURE", nullptr);
    if (!temporary.empty()) {
        std::error_code error;
        std::filesystem::remove_all(temporary, error);
    }
    if (SUCCEEDED(initialized)) CoUninitialize();
    return result;
}
