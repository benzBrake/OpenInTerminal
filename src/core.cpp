#include "core.hpp"
#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <unordered_set>
#include <nlohmann/json.hpp>

namespace oit {
std::string NormalizeJsonc(std::string_view input) {
    if (input.starts_with("\xEF\xBB\xBF")) input.remove_prefix(3);
    std::string text(input);
    bool quoted = false;
    bool escaped = false;
    for (size_t i = 0; i < text.size(); ++i) {
        const char ch = text[i];
        if (quoted) {
            if (escaped) escaped = false;
            else if (ch == '\\') escaped = true;
            else if (ch == '"') quoted = false;
        } else if (ch == '"') {
            quoted = true;
        } else if (ch == '/' && i + 1 < text.size() && text[i + 1] == '/') {
            while (i < text.size() && text[i] != '\n' && text[i] != '\r') text[i++] = ' ';
            if (i == text.size()) break;
        } else if (ch == '/' && i + 1 < text.size() && text[i + 1] == '*') {
            text[i++] = ' ';
            text[i++] = ' ';
            bool closed = false;
            while (i < text.size()) {
                if (text[i] == '*' && i + 1 < text.size() && text[i + 1] == '/') {
                    text[i++] = ' ';
                    text[i] = ' ';
                    closed = true;
                    break;
                }
                if (text[i] != '\n' && text[i] != '\r') text[i] = ' ';
                ++i;
            }
            if (!closed) throw std::runtime_error("Unterminated JSONC block comment");
        }
    }
    quoted = escaped = false;
    for (size_t i = 0; i < text.size(); ++i) {
        const char ch = text[i];
        if (quoted) {
            if (escaped) escaped = false;
            else if (ch == '\\') escaped = true;
            else if (ch == '"') quoted = false;
        } else if (ch == '"') quoted = true;
        else if (ch == ',') {
            size_t next = i + 1;
            while (next < text.size() && std::isspace(static_cast<unsigned char>(text[next]))) ++next;
            size_t previous = i;
            while (previous && std::isspace(static_cast<unsigned char>(text[previous - 1]))) --previous;
            if (previous && std::string_view("[{,:").find(text[previous - 1]) == std::string_view::npos &&
                next < text.size() && (text[next] == '}' || text[next] == ']')) text[i] = ' ';
        }
    }
    return text;
}

static std::string StringValue(const nlohmann::json& object, const char* key) {
    const auto found = object.find(key);
    return found != object.end() && found->is_string() ? found->get<std::string>() : "";
}

std::vector<Profile> ParseProfiles(std::string_view input) {
    const auto settings = nlohmann::json::parse(NormalizeJsonc(input));
    if (!settings.is_object()) throw std::runtime_error("Terminal settings must be an object");
    const auto found = settings.find("profiles");
    if (found == settings.end()) return {};
    const auto& profiles = *found;
    const nlohmann::json* list = nullptr;
    nlohmann::json defaults = nlohmann::json::object();
    if (profiles.is_array()) list = &profiles;
    else if (profiles.is_object()) {
        const auto values = profiles.find("list");
        if (values != profiles.end() && values->is_array()) list = &*values;
        const auto inherited = profiles.find("defaults");
        if (inherited != profiles.end() && inherited->is_object()) defaults = *inherited;
    }
    if (!list) return {};
    std::unordered_set<std::string> disabled;
    const auto sources = settings.find("disabledProfileSources");
    if (sources != settings.end() && sources->is_array()) {
        for (const auto& source : *sources) if (source.is_string()) disabled.insert(source.get<std::string>());
    }
    std::vector<Profile> result;
    std::unordered_set<std::string> seen;
    for (const auto& value : *list) {
        if (!value.is_object()) continue;
        auto profile = defaults;
        profile.update(value);
        const auto hidden = profile.find("hidden");
        if (hidden != profile.end() && hidden->is_boolean() && hidden->get<bool>()) continue;
        if (disabled.contains(StringValue(profile, "source"))) continue;
        auto name = StringValue(profile, "name");
        if (name.empty() || name.find('\0') != std::string::npos) continue;
        auto id = StringValue(profile, "guid");
        if (id.empty()) id = name;
        if (id.find('\0') != std::string::npos) continue;
        auto key = id;
        if (!key.empty() && key.front() == '{') {
            std::transform(key.begin(), key.end(), key.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        }
        if (!seen.insert(key).second) continue;
        result.push_back({std::move(name), std::move(id), StringValue(profile, "icon"), StringValue(profile, "commandline")});
    }
    return result;
}

std::wstring QuoteArgument(std::wstring_view value) {
    std::wstring output(1, L'"');
    size_t backslashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') { ++backslashes; continue; }
        output.append(ch == L'"' ? backslashes * 2 + 1 : backslashes, L'\\');
        output.push_back(ch);
        backslashes = 0;
    }
    output.append(backslashes * 2, L'\\');
    output.push_back(L'"');
    return output;
}

std::wstring TerminalArguments(std::wstring_view profile, std::wstring_view directory) {
    // WT parses semicolons even inside quoted arguments. Escape its command
    // separator before applying Windows argument quoting.
    const auto escape = [](std::wstring_view value) {
        std::wstring result;
        for (wchar_t ch : value) { if (ch == L';') result += L'\\'; result += ch; }
        return QuoteArgument(result);
    };
    if (profile.find_first_of(L"\r\n") != std::wstring_view::npos || profile.find(L'\0') != std::wstring_view::npos)
        throw std::runtime_error("Unsupported delimiter in profile identifier");
    if (directory.empty() || directory.find_first_of(L"\r\n\"") != std::wstring_view::npos || directory.find(L'\0') != std::wstring_view::npos)
        throw std::runtime_error("Unsupported delimiter in directory path");
    std::wstring path(directory);
    if (path.back() != L'\\' && path.back() != L'/') path += L'\\';
    path += L'.';
    auto args = std::wstring(L"-w new new-tab");
    if (!profile.empty()) args += L" --profile " + escape(profile);
    return args + L" --startingDirectory " + escape(path);
}
}
