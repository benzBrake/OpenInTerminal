#include "core.hpp"
#include <iostream>
#include <stdexcept>

static void Check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template<class F> static void Reject(F action) {
    bool rejected = false;
    try { action(); } catch (const std::exception&) { rejected = true; }
    Check(rejected, "Invalid input was accepted");
}
int main() {
    try {
        const auto profiles = oit::ParseProfiles(R"json(
        { // Terminal accepts comments and trailing commas.
          "disabledProfileSources": ["disabled",],
          "profiles": {
            "defaults": { "icon": "https://example.test/icon.png", },
            "list": [
              {"name":"PowerShell 7", "guid":"{ABC}",},
              {"name":"重复", "guid":"{abc}"},
              {"name":"Hidden", "hidden":true},
              {"name":"Disabled", "source":"disabled"},
              {"name":"Ubuntu 中文", "guid":"{DEF}", "icon":"C:\\icons\\ubuntu.ico"},
              /* preserve // and commas in strings */
              {"name":"A,] // B", "commandline":"cmd.exe"},
              null, 42, {"name":false},
            ],
          },
        })json");
        Check(profiles.size() == 3, "Filtering/deduplication failed");
        Check(profiles[0].icon == "https://example.test/icon.png", "String or defaults damaged");
        Check(profiles[1].name == "Ubuntu 中文", "UTF-8 damaged");
        Check(profiles[2].id == "A,] // B", "Name fallback failed");
        Check(oit::ParseProfiles("\xEF\xBB\xBF{\"profiles\":[{\"name\":\"cmd\"}]}").size() == 1, "BOM/old format failed");
        Check(oit::ParseProfiles(R"({"profiles":{"defaults":{"hidden":true},"list":[{"name":"a"},{"name":"b","hidden":false}]}})").size() == 1, "hidden inheritance failed");
        Reject([] { oit::ParseProfiles("{/* unfinished"); });
        Reject([] { oit::ParseProfiles("{\"profiles\": [,]}"); });
        Reject([] { oit::ParseProfiles("[]"); });
        Check(oit::QuoteArgument(L"C:\\") == L"\"C:\\\\\"", "Trailing slash quoting failed");
        Check(oit::QuoteArgument(L"a\"b") == L"\"a\\\"b\"", "Quote escaping failed");
        const auto command = oit::TerminalArguments(L"{GUID}", L"C:\\中文 & (test)\\");
        Check(command == L"-w new new-tab --profile \"{GUID}\" --startingDirectory \"C:\\中文 & (test)\\.\"", "Launch arguments incorrect");
        Check(oit::TerminalArguments(L"x;new-tab", L"C:\\a;new-tab").find(L"x\\;new-tab") != std::wstring::npos, "WT separator was not escaped");
        Reject([] { oit::TerminalArguments(L"x", L"C:\\a\"b"); });
        std::cout << "Core tests passed\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

