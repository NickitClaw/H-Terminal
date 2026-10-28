#include "session.h"
#include <openssl/evp.h>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <random>
#include <sys/stat.h>
#include <unistd.h>
using namespace hterminal;

int main(int argc, char **argv) {
    if (argc != 3 || !EnsureSshInitialized()) return 2;
    std::ifstream source(argv[1]);
    std::string original{std::istreambuf_iterator<char>(source), std::istreambuf_iterator<char>()};
    if (!SupportedPrivateKeyContainer(original)) return 3;
    size_t begin = original.find('\n') + 1, end = original.find("-----END");
    std::string encoded;
    for (size_t i = begin; i < end; ++i) if (original[i] != '\r' && original[i] != '\n') encoded.push_back(original[i]);
    std::vector<unsigned char> raw(encoded.size() / 4 * 3);
    int count = EVP_DecodeBlock(raw.data(), reinterpret_cast<const unsigned char *>(encoded.data()), encoded.size());
    if (count < 0) return 4;
    if (encoded.back() == '=') --count;
    if (encoded[encoded.size() - 2] == '=') --count;
    raw.resize(static_cast<size_t>(count));
    std::mt19937 random(0x48544552);
    size_t accepted = 0, inspected = 0;
    auto check = [&](const std::string &key, bool import) {
        if (SupportedPrivateKeyContainer(key)) {
            ++accepted;
            if (import) {
                ssh_key parsed = nullptr;
                ssh_pki_import_privkey_base64(key.c_str(), "", nullptr, nullptr, &parsed);
                ssh_key_free(parsed); ++inspected;
            }
        }
    };
    for (size_t length = 0; length < original.size(); ++length) check(original.substr(0, length), true);
    for (size_t iteration = 0; iteration < 10000; ++iteration) {
        if (iteration % 3 == 0) {
            std::string garbage(random() % 65537, ' ');
            for (char &c : garbage) c = static_cast<char>(random() & 255);
            check(garbage, false);
        } else {
            auto mutated = raw;
            for (size_t j = 0, n = 1 + random() % 8; j < n; ++j) mutated[random() % mutated.size()] ^= 1 + random() % 255;
            std::string base64((mutated.size() + 2) / 3 * 4, '\0');
            EVP_EncodeBlock(reinterpret_cast<unsigned char *>(&base64[0]), mutated.data(), mutated.size());
            // Only mutate the unencrypted seed. No bcrypt KDF work is executed.
            std::string key = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + base64 + "\n-----END OPENSSH PRIVATE KEY-----\n";
            check(key, true);
        }
    }
    std::string known = std::string(argv[2]) + "/known_hosts";
    std::string target = std::string(argv[2]) + "/untouched";
    { std::ofstream file(target); file << "sentinel\n"; }
    if (symlink(target.c_str(), known.c_str()) != 0) return 5;
    TrustedHostKey key;
    if (AccessTrustedHostKey(argv[2], "fixture.test", 22, "", false, key)) return 6;
    unlink(known.c_str());
    { std::ofstream file(known); file.seekp(1024 * 1024); file << 'X'; }
    if (AccessTrustedHostKey(argv[2], "fixture.test", 22, "SHA256:none", true, key)) return 7;
    std::ifstream verify(target); std::string sentinel; std::getline(verify, sentinel);
    if (sentinel != "sentinel") return 8;
    printf("PASS: 10,000 deterministic container mutations, %zu bounded envelopes, %zu real key imports, symlink and oversized known_hosts rejection\n", accepted, inspected);
    SecureClear(original); SecureClear(encoded);
    return 0;
}
