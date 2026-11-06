#include "windows.hpp"
#include "com_ptr.hpp"
#include <shlobj.h>
#include <shlwapi.h>
#include <shobjidl.h>
#include <servprov.h>
#include <atomic>
#include <algorithm>
#include <new>
#include <utility>
#include <sstream>

namespace {
using oit::ComPtr;
std::atomic<long> objects{0};
std::atomic<long> locks{0};
bool Chinese() { return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE; }
std::wstring Localized(const wchar_t* chinese, const wchar_t* english) { return Chinese() ? chinese : english; }
HRESULT ExceptionResult() noexcept {
    try { throw; }
    catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
    catch (...) { return E_FAIL; }
}
HRESULT ReportFailure(HRESULT hr, HWND owner, const wchar_t* stage) {
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return hr;
    wchar_t system[1024]{};
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
                   static_cast<DWORD>(hr), 0, system, 1024, nullptr);
    std::wostringstream message;
    message << stage << L"\n\n" << system << L"\n(0x" << std::hex << static_cast<unsigned long>(hr) << L")";
    MessageBoxW(owner, message.str().c_str(), L"Open In Terminal", MB_OK | MB_ICONERROR);
    return hr;
}
class Lifetime {
    std::atomic<ULONG> refs_{1};
public:
    Lifetime() { ++objects; }
    virtual ~Lifetime() { --objects; }
    ULONG AddReference() { return ++refs_; }
    ULONG ReleaseReference() { const auto count = --refs_; if (!count) delete this; return count; }
};

HRESULT Directory(IShellItem* item, std::wstring& path) {
    SFGAOF attributes{};
    HRESULT hr = item->GetAttributes(SFGAO_FILESYSTEM | SFGAO_FOLDER | SFGAO_STREAM, &attributes);
    if (FAILED(hr)) return hr;
    if ((attributes & (SFGAO_FILESYSTEM | SFGAO_FOLDER)) != (SFGAO_FILESYSTEM | SFGAO_FOLDER) || (attributes & SFGAO_STREAM)) return E_INVALIDARG;
    PWSTR raw = nullptr;
    hr = item->GetDisplayName(SIGDN_FILESYSPATH, &raw);
    if (SUCCEEDED(hr)) {
        try { path = raw; } catch (...) { CoTaskMemFree(raw); throw; }
        CoTaskMemFree(raw);
    }
    return hr;
}

HRESULT Directories(IShellItemArray* items, IUnknown* site, std::vector<std::wstring>& paths) {
    DWORD count = 0;
    if (items) {
        const auto hr = items->GetCount(&count);
        if (FAILED(hr)) return hr;
    }
    if (count) {
        for (DWORD i = 0; i < count; ++i) {
            ComPtr<IShellItem> item;
            auto hr = items->GetItemAt(i, item.put());
            if (FAILED(hr)) return hr;
            std::wstring path;
            hr = Directory(item.get(), path);
            if (FAILED(hr)) return hr;
            if (std::find(paths.begin(), paths.end(), path) == paths.end()) paths.push_back(std::move(path));
        }
        return S_OK;
    }
    if (!site) return E_FAIL;
    ComPtr<IServiceProvider> services;
    auto hr = site->QueryInterface(IID_IServiceProvider, reinterpret_cast<void**>(services.put()));
    if (FAILED(hr)) return hr;
    ComPtr<IFolderView> view;
    hr = services->QueryService(SID_SFolderView, IID_IFolderView, reinterpret_cast<void**>(view.put()));
    if (FAILED(hr)) return hr;
    ComPtr<IShellItem> folder;
    hr = view->GetFolder(IID_IShellItem, reinterpret_cast<void**>(folder.put()));
    if (FAILED(hr)) return hr;
    std::wstring path;
    hr = Directory(folder.get(), path);
    if (SUCCEEDED(hr)) paths.push_back(std::move(path));
    return hr;
}

class Enumerator final : public IEnumExplorerCommand, public Lifetime {
    std::vector<ComPtr<IExplorerCommand>> commands_;
    size_t index_ = 0;
public:
    explicit Enumerator(std::vector<ComPtr<IExplorerCommand>> commands, size_t index = 0)
        : commands_(std::move(commands)), index_(index) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id != IID_IUnknown && id != IID_IEnumExplorerCommand) return E_NOINTERFACE;
        *out = static_cast<IEnumExplorerCommand*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return AddReference(); }
    ULONG STDMETHODCALLTYPE Release() override { return ReleaseReference(); }
    HRESULT STDMETHODCALLTYPE Next(ULONG count, IExplorerCommand** out, ULONG* fetched) override {
        if (fetched) *fetched = 0;
        if (!out || (!fetched && count != 1)) return E_POINTER;
        ULONG copied = 0;
        while (copied < count && index_ < commands_.size()) {
            out[copied] = commands_[index_++].get();
            out[copied++]->AddRef();
        }
        if (fetched) *fetched = copied;
        return copied == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Skip(ULONG count) override {
        const auto skipped = std::min(static_cast<size_t>(count), commands_.size() - index_);
        index_ += skipped;
        return skipped == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Reset() override { index_ = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE Clone(IEnumExplorerCommand** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        try { *out = new Enumerator(commands_, index_); return S_OK; } catch (...) { return ExceptionResult(); }
    }
};

struct InvocationContext {
    ComPtr<IUnknown> site;
    std::vector<std::wstring> paths;
};
class Command final : public IExplorerCommand, public IObjectWithSite, public Lifetime {
    bool root_ = true;
    std::shared_ptr<const oit::Terminal> terminal_;
    size_t profile_ = 0;
    ComPtr<IUnknown> site_;
    std::shared_ptr<InvocationContext> context_ = std::make_shared<InvocationContext>();
    bool Available() const { return terminal_ && terminal_->error.empty() && profile_ < terminal_->profiles.size(); }
public:
    Command() = default;
    Command(std::shared_ptr<const oit::Terminal> terminal, size_t profile, std::shared_ptr<InvocationContext> context)
        : root_(false), terminal_(std::move(terminal)), profile_(profile), context_(std::move(context)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == IID_IUnknown || id == IID_IExplorerCommand) *out = static_cast<IExplorerCommand*>(this);
        else if (id == IID_IObjectWithSite) *out = static_cast<IObjectWithSite*>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return AddReference(); }
    ULONG STDMETHODCALLTYPE Release() override { return ReleaseReference(); }
    HRESULT STDMETHODCALLTYPE SetSite(IUnknown* site) override {
        site_ = ComPtr<IUnknown>(site);
        if (root_) context_->site = site_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSite(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return site_ ? site_->QueryInterface(id, out) : E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, PWSTR* out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        try {
            auto title = root_ ? Localized(L"在终端中打开", L"Open In Terminal") :
                Available() ? oit::Utf16(terminal_->profiles[profile_].name) :
                Localized(L"没有可用的终端配置", L"No available Terminal profiles");
            for (size_t i = 0; (i = title.find(L'&', i)) != std::wstring::npos; i += 2) title.insert(i, 1, L'&');
            return SHStrDupW(title.c_str(), out);
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, PWSTR* out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        try {
            if (Available() && terminal_->profiles[profile_].icon == "none") return E_NOTIMPL;
            const auto terminal = terminal_ ? terminal_ : oit::CurrentTerminal();
            return SHStrDupW(oit::ProfileIcon(*terminal, Available() ? &terminal_->profiles[profile_] : nullptr).c_str(), out);
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, PWSTR* out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        try {
            const auto tip = terminal_ && !terminal_->error.empty() ? oit::Utf16(terminal_->error) :
                Localized(L"按住 Ctrl 点击，以管理员身份打开", L"Hold Ctrl while clicking to run as administrator");
            return SHStrDupW(tip.c_str(), out);
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* out) override {
        if (!out) return E_POINTER;
        *out = oit::CommandClsid;
        if (!root_) {
            // Stable per-profile identity without exposing user names in registry.
            unsigned long hash = 2166136261u;
            if (Available()) for (unsigned char ch : terminal_->profiles[profile_].id) hash = (hash ^ ch) * 16777619u;
            out->Data1 ^= hash;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetState(IShellItemArray* items, BOOL slow, EXPCMDSTATE* state) override {
        if (!state) return E_POINTER;
        *state = ECS_HIDDEN;
        if (!root_) { *state = Available() ? ECS_ENABLED : ECS_DISABLED; return S_OK; }
        if (!slow) return E_PENDING;
        try {
            context_->paths.clear();
            std::vector<std::wstring> paths;
            if (SUCCEEDED(Directories(items, site_.get(), paths)) && !paths.empty()) {
                context_->paths = std::move(paths);
                *state = ECS_ENABLED;
            }
            return S_OK;
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* flags) override {
        if (!flags) return E_POINTER;
        *flags = root_ ? ECF_HASSUBCOMMANDS : ECF_DEFAULT;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!root_) return E_NOTIMPL;
        try {
            const auto terminal = oit::CurrentTerminal();
            std::vector<ComPtr<IExplorerCommand>> commands;
            const size_t count = std::max<size_t>(1, terminal->profiles.size());
            for (size_t i = 0; i < count; ++i) {
                ComPtr<IExplorerCommand> command;
                *command.put() = new Command(terminal, i, context_);
                commands.push_back(std::move(command));
            }
            *out = new Enumerator(std::move(commands));
            return S_OK;
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray* items, IBindCtx*) override {
        // Sample before resolving the selection or displaying a UAC dialog.
        const bool elevated = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
        if (root_) return E_NOTIMPL;
        if (!Available()) return HRESULT_FROM_WIN32(ERROR_NOT_READY);
        try {
            const auto site = site_ ? site_.get() : context_->site.get();
            std::vector<std::wstring> paths;
            auto hr = Directories(items, site, paths);
            if (FAILED(hr) && !context_->paths.empty()) { paths = context_->paths; hr = S_OK; }
            if (FAILED(hr)) return ReportFailure(hr, nullptr, Localized(L"无法获取当前文件夹", L"Cannot resolve the current folder").c_str());
            HWND owner = nullptr;
            ComPtr<IOleWindow> window;
            if (site && SUCCEEDED(site->QueryInterface(IID_IOleWindow, reinterpret_cast<void**>(window.put())))) window->GetWindow(&owner);
            // Preflight every argument before opening the first window.
            for (const auto& path : paths) oit::TerminalArguments(oit::Utf16(terminal_->profiles[profile_].id), path);
            for (const auto& path : paths) {
                hr = oit::LaunchTerminal(*terminal_, &terminal_->profiles[profile_], path, elevated, owner);
                if (FAILED(hr)) return ReportFailure(hr, owner, Localized(L"无法启动 Windows Terminal", L"Cannot start Windows Terminal").c_str());
            }
            return paths.empty() ? E_FAIL : S_OK;
        } catch (...) { return ReportFailure(ExceptionResult(), nullptr, Localized(L"无法在此文件夹打开终端", L"Cannot open a terminal in this folder").c_str()); }
    }
};

class Factory final : public IClassFactory, public Lifetime {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id != IID_IUnknown && id != IID_IClassFactory) return E_NOINTERFACE;
        *out = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return AddReference(); }
    ULONG STDMETHODCALLTYPE Release() override { return ReleaseReference(); }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        try {
            auto* command = new Command;
            const auto hr = command->QueryInterface(id, out);
            command->Release();
            return hr;
        } catch (...) { return ExceptionResult(); }
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override { if (lock) ++locks; else --locks; return S_OK; }
};
}

extern "C" HRESULT STDMETHODCALLTYPE DllCanUnloadNow() { return objects == 0 && locks == 0 ? S_OK : S_FALSE; }
extern "C" HRESULT STDMETHODCALLTYPE DllGetClassObject(REFCLSID clsid, REFIID id, void** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (clsid != oit::CommandClsid) return CLASS_E_CLASSNOTAVAILABLE;
    try {
        auto* factory = new Factory;
        const auto hr = factory->QueryInterface(id, out);
        factory->Release();
        return hr;
    } catch (...) { return ExceptionResult(); }
}
