#pragma once
#include <string>
#include <string_view>
#include <vector>

namespace oit {
struct Profile {
    std::string name;
    std::string id;
    std::string icon;
    std::string commandline;
    bool operator==(const Profile&) const = default;
};
std::string NormalizeJsonc(std::string_view input);
std::vector<Profile> ParseProfiles(std::string_view input);
std::wstring QuoteArgument(std::wstring_view value);
std::wstring TerminalArguments(std::wstring_view profile, std::wstring_view directory);
}

