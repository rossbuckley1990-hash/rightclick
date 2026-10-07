// Native transport controls only; this executable is never part of the product.
#include "RightClickWindowsCOM.h"
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

static std::vector<std::string> split(const std::string& line) {
    std::vector<std::string> parts; std::istringstream input(line); std::string part;
    while (std::getline(input, part, '\t')) parts.push_back(part); return parts;
}
static std::vector<unsigned char> unhex(const std::string& value) {
    if (value.size() % 2 || value.size() > 2097152) throw 2;
    std::vector<unsigned char> result;
    for (size_t i = 0; i < value.size(); i += 2) result.push_back(static_cast<unsigned char>(std::stoul(value.substr(i, 2), nullptr, 16)));
    return result;
}
int main() {
    rc_com_client *client = rc_com_open(); if (!client) return 2;
    std::map<unsigned, rc_com_call*> calls; unsigned next = 1; std::string line;
    while (std::getline(std::cin, line)) {
        auto parts = split(line); int status = 2; unsigned char *bytes = nullptr; size_t length = 0;
        std::string output;
        try {
            if (parts.size() == 1 && parts[0] == "catalog") { status = rc_com_catalog(client, &bytes, &length); if (!status) output = ",\"catalog\":" + std::string(reinterpret_cast<char*>(bytes), length); }
            else if (parts.size() == 2 && parts[0] == "validate") status = rc_com_validate(client, parts[1].c_str());
            else if (parts.size() == 4 && parts[0] == "prepare") {
                auto data = unhex(parts[3]); rc_com_call *call = nullptr;
                status = rc_com_prepare(client, parts[1].c_str(), std::stoi(parts[2]), data.data(), data.size(), &call);
                if (!status && calls.size() < 16) { calls[next] = call; output = ",\"call\":" + std::to_string(next++); }
                else if (call) { rc_com_release_call(call); status = 2; }
            } else if (parts.size() == 2 && calls.count(std::stoul(parts[1]))) {
                auto id = static_cast<unsigned>(std::stoul(parts[1]));
                if (parts[0] == "enqueue") status = rc_com_enqueue(calls[id]);
                else if (parts[0] == "wait") { status = rc_com_wait(calls[id], &bytes, &length); }
                else if (parts[0] == "release") { rc_com_release_call(calls[id]); calls.erase(id); status = 0; }
            } else if (parts.size() == 1 && parts[0] == "close") {
                for (auto& call : calls) rc_com_release_call(call.second); calls.clear(); rc_com_close(client); client = nullptr;
                std::cout << "{\"status\":0}" << std::endl; break;
            }
        } catch (...) { status = 2; }
        rc_com_free(bytes); std::cout << "{\"status\":" << status << output << '}'; std::cout << std::endl;
    }
    for (auto& call : calls) rc_com_release_call(call.second); rc_com_close(client); return 0;
}
