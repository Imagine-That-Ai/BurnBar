/*
 * OpenBurnBar native Fcitx5 text-expansion addon.
 *
 * Mirrors the IBus engine's safety boundary exactly:
 *  - trigger-only: the addon observes ONLY keys typed while this engine is
 *    active, never global input (no evdev, no XRecord, no key grab);
 *  - no clipboard reads, no surrounding-text reads;
 *  - secure/password/uninspectable fields are denied before any daemon call;
 *  - the daemon owns replacements: expansion goes through
 *    `openburnbar-cli text-expansion-engine-expand` with a hard timeout and
 *    a bounded response, so a wedged daemon can never wedge the IME;
 *  - consent is enforced daemon-side (the CLI refuses when external
 *    expansion is not explicitly enabled), matching the IBus engine.
 */
#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cctype>
#include <cstring>
#include <string>
#include <vector>

extern char **environ;

namespace {

constexpr size_t kMaxPending = 68;
constexpr size_t kMaxTrigger = 64;
constexpr size_t kMinTrigger = 2;
constexpr size_t kMaxResponse = 64 * 1024;
constexpr int kDaemonTimeoutMs = 2000;

// Environment forwarded to the CLI; identical to the IBus engine's
// CLI_ENVIRONMENT_KEYS allowlist so daemon socket discovery matches.
constexpr const char *kEnvironmentAllowlist[] = {
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "XDG_RUNTIME_DIR",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "OPENBURNBAR_DAEMON_SUPPORT_DIR",
    "OPENBURNBAR_DAEMON_SOCKET_PATH",
    "BURNBAR_DAEMON_SOCKET_PATH",
    "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE",
    "BURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE",
};

constexpr const char *kCliPath = "/usr/bin/openburnbar-cli";

bool isTriggerChar(uint32_t unicode) {
    if (unicode > 0x7f) {
        return false;
    }
    const char c = static_cast<char>(unicode);
    return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '&' ||
           c == '_' || c == '-';
}

bool isDelimiterChar(uint32_t unicode) {
    return unicode == ' ' || unicode == '\n' || unicode == '\t';
}

// Canonical trigger check: the candidate must be "&&" + [a-z0-9_-]{2,64}.
// Uppercase is canonicalized to lowercase, matching the Python engine.
std::string canonicalTrigger(const std::string &candidate) {
    if (candidate.size() < 2 || candidate.compare(0, 2, "&&") != 0) {
        return {};
    }
    std::string body = candidate.substr(2);
    while (body.compare(0, 2, "&&") == 0) {
        body = body.substr(2);
    }
    if (body.size() < kMinTrigger || body.size() > kMaxTrigger) {
        return {};
    }
    for (char &c : body) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        const bool ok = (std::isalnum(static_cast<unsigned char>(c)) != 0 &&
                         std::isupper(static_cast<unsigned char>(c)) == 0) ||
                        c == '_' || c == '-';
        if (!ok) {
            return {};
        }
    }
    return body;
}

std::string jsonEscape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (const char c : value) {
        switch (c) {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                              static_cast<unsigned char>(c));
                out += buffer;
            } else {
                out += c;
            }
        }
    }
    return out;
}

// Minimal extraction of a top-level string field from the CLI's bounded JSON
// response. The response schema is daemon-owned and flat; a full JSON parser
// dependency is deliberately avoided inside the input-method process.
bool extractJsonString(const std::string &json, const std::string &key,
                       std::string *out) {
    const std::string needle = "\"" + key + "\"";
    size_t at = json.find(needle);
    if (at == std::string::npos) {
        return false;
    }
    at = json.find(':', at + needle.size());
    if (at == std::string::npos) {
        return false;
    }
    at = json.find('"', at + 1);
    if (at == std::string::npos) {
        return false;
    }
    std::string value;
    for (size_t i = at + 1; i < json.size(); ++i) {
        const char c = json[i];
        if (c == '\\' && i + 1 < json.size()) {
            const char n = json[++i];
            switch (n) {
            case 'n':
                value += '\n';
                break;
            case 'r':
                value += '\r';
                break;
            case 't':
                value += '\t';
                break;
            case 'u': {
                if (i + 4 >= json.size()) {
                    return false;
                }
                const std::string hex = json.substr(i + 1, 4);
                i += 4;
                const long code = std::strtol(hex.c_str(), nullptr, 16);
                if (code < 0x80) {
                    value += static_cast<char>(code);
                } else if (code < 0x800) {
                    value += static_cast<char>(0xc0 | (code >> 6));
                    value += static_cast<char>(0x80 | (code & 0x3f));
                } else {
                    value += static_cast<char>(0xe0 | (code >> 12));
                    value += static_cast<char>(0x80 | ((code >> 6) & 0x3f));
                    value += static_cast<char>(0x80 | (code & 0x3f));
                }
                break;
            }
            default:
                value += n;
            }
        } else if (c == '"') {
            *out = value;
            return true;
        } else {
            value += c;
        }
        if (value.size() > kMaxResponse) {
            return false;
        }
    }
    return false;
}

std::string randomRequestId() {
    char buffer[33];
    int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    unsigned char raw[16];
    if (fd >= 0) {
        ssize_t got = ::read(fd, raw, sizeof(raw));
        ::close(fd);
        if (got != static_cast<ssize_t>(sizeof(raw))) {
            std::memset(raw, 0, sizeof(raw));
        }
    } else {
        std::memset(raw, 0, sizeof(raw));
    }
    for (size_t i = 0; i < sizeof(raw); ++i) {
        std::snprintf(buffer + i * 2, 3, "%02x", raw[i]);
    }
    return std::string("ime-fcitx5-") + buffer;
}

/**
 * Ask the daemon (through the CLI) for a replacement. Bounded: hard timeout,
 * bounded stdout, kill-on-timeout. Returns false when no expansion should
 * happen — the user's literal text is then left untouched.
 */
bool daemonExpand(const std::string &trigger, std::string *replacement) {
    int inPipe[2];
    int outPipe[2];
    if (::pipe(inPipe) != 0) {
        return false;
    }
    if (::pipe(outPipe) != 0) {
        ::close(inPipe[0]);
        ::close(inPipe[1]);
        return false;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                     O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&actions, inPipe[1]);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);

    std::vector<std::string> environmentStorage;
    for (const char *key : kEnvironmentAllowlist) {
        const char *value = ::getenv(key);
        if (value != nullptr) {
            environmentStorage.emplace_back(std::string(key) + "=" + value);
        }
    }
    std::vector<char *> environment;
    environment.reserve(environmentStorage.size() + 1);
    for (auto &entry : environmentStorage) {
        environment.push_back(entry.data());
    }
    environment.push_back(nullptr);

    const char *argv[] = {kCliPath, "text-expansion-engine-expand", nullptr};
    pid_t pid = -1;
    const int spawned =
        posix_spawn(&pid, kCliPath, &actions, nullptr,
                    const_cast<char *const *>(argv), environment.data());
    posix_spawn_file_actions_destroy(&actions);
    ::close(inPipe[0]);
    ::close(outPipe[1]);
    if (spawned != 0) {
        ::close(inPipe[1]);
        ::close(outPipe[0]);
        return false;
    }

    const std::string request =
        std::string("{\"trigger\":\"") + jsonEscape(trigger) +
        "\",\"context\":{\"inspectable\":true,\"isSecureField\":false,"
        "\"applicationID\":\"fcitx5-input-context\",\"role\":\"text\","
        "\"inputPurpose\":\"free_form\"},\"timeoutMillis\":1000,"
        "\"requestID\":\"" +
        jsonEscape(randomRequestId()) + "\"}";
    // Best-effort write; the CLI reads a single JSON document from stdin.
    ssize_t ignored = ::write(inPipe[1], request.data(), request.size());
    (void)ignored;
    ::close(inPipe[1]);

    std::string output;
    struct pollfd watched = {outPipe[0], POLLIN, 0};
    int remainingMs = kDaemonTimeoutMs;
    bool timedOut = false;
    while (remainingMs > 0) {
        const int ready = ::poll(&watched, 1, remainingMs);
        if (ready <= 0) {
            timedOut = ready == 0;
            break;
        }
        char buffer[4096];
        const ssize_t got = ::read(outPipe[0], buffer, sizeof(buffer));
        if (got <= 0) {
            break;
        }
        output.append(buffer, static_cast<size_t>(got));
        if (output.size() > kMaxResponse) {
            timedOut = true; // treat an over-bound response as hostile
            break;
        }
        // poll() again with a coarse remaining budget; exact accounting is
        // unnecessary because the CLI enforces its own 1s daemon timeout.
        remainingMs -= 10;
    }
    ::close(outPipe[0]);

    int status = 0;
    if (timedOut) {
        ::kill(pid, SIGKILL);
    }
    (void)::waitpid(pid, &status, 0);
    if (timedOut || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return false;
    }
    std::string value;
    if (!extractJsonString(output, "replacement", &value) || value.empty() ||
        value.size() > kMaxResponse) {
        return false;
    }
    *replacement = value;
    return true;
}

/** Per-input-context state: the bounded pending buffer plus field metadata. */
class OpenBurnBarState : public fcitx::InputContextProperty {
public:
    std::string pending;
    // Deny-by-default: a field is only expandable after the client has
    // published capability metadata (the Fcitx5 equivalent of IBus
    // do_set_content_type) and that metadata is explicitly non-secure.
    bool sawCapabilityMetadata = false;

    void reset() { pending.clear(); }
};

class OpenBurnBarEngine final : public fcitx::InputMethodEngineV2 {
public:
    explicit OpenBurnBarEngine(fcitx::Instance *instance)
        : instance_(instance),
          factory_([](fcitx::InputContext &) { return new OpenBurnBarState; }) {
        instance_->inputContextManager().registerProperty(
            "openburnbarState", &factory_);
        eventWatchers_.emplace_back(instance_->watchEvent(
            fcitx::EventType::InputContextCapabilityAboutToChange,
            fcitx::EventWatcherPhase::Default, [this](fcitx::Event &event) {
                auto &capabilityEvent =
                    static_cast<fcitx::CapabilityEvent &>(event);
                auto *state = capabilityEvent.inputContext()->propertyFor(
                    &factory_);
                state->sawCapabilityMetadata = true;
            }));
    }

    void keyEvent(const fcitx::InputMethodEntry & /*entry*/,
                  fcitx::KeyEvent &event) override {
        if (event.isRelease()) {
            return;
        }
        auto *ic = event.inputContext();
        auto *state = ic->propertyFor(&factory_);

        // Modifier chords never contribute to a trigger and clear the buffer,
        // matching the IBus engine.
        if (event.rawKey().states().testAny(fcitx::KeyStates{
                fcitx::KeyState::Ctrl, fcitx::KeyState::Alt,
                fcitx::KeyState::Super})) {
            state->reset();
            return;
        }

        const uint32_t unicode =
            fcitx::Key::keySymToUnicode(event.key().sym());
        if (unicode != 0 && isTriggerChar(unicode)) {
            state->pending.push_back(static_cast<char>(unicode));
            if (state->pending.size() > kMaxPending) {
                state->pending.erase(0,
                                     state->pending.size() - kMaxPending);
            }
            return;
        }
        if (unicode == 0 || !isDelimiterChar(unicode)) {
            state->reset();
            return;
        }

        const std::string candidate = state->pending;
        state->reset();
        const std::string trigger = canonicalTrigger(candidate);
        if (trigger.empty()) {
            return;
        }
        // Secure-field policy: deny-unless-inspectable-and-explicitly-nonsecure.
        if (!state->sawCapabilityMetadata) {
            return;
        }
        const auto capabilities = ic->capabilityFlags();
        if (capabilities.test(fcitx::CapabilityFlag::Password) ||
            capabilities.test(fcitx::CapabilityFlag::Sensitive)) {
            return;
        }

        std::string replacement;
        if (!daemonExpand(trigger, &replacement)) {
            return;
        }

        // Replace the literal trigger the app already received: backspaces
        // for each typed char, then the replacement plus the delimiter the
        // user pressed. The delimiter key itself is consumed.
        for (size_t i = 0; i < candidate.size(); ++i) {
            ic->forwardKey(fcitx::Key(FcitxKey_BackSpace));
        }
        std::string committed = replacement;
        committed.push_back(static_cast<char>(unicode));
        ic->commitString(committed);
        event.filterAndAccept();
    }

    void reset(const fcitx::InputMethodEntry & /*entry*/,
               fcitx::InputContextEvent &event) override {
        auto *state = event.inputContext()->propertyFor(&factory_);
        state->reset();
    }

    void deactivate(const fcitx::InputMethodEntry & /*entry*/,
                    fcitx::InputContextEvent &event) override {
        auto *state = event.inputContext()->propertyFor(&factory_);
        state->reset();
        // Focus changes also invalidate field metadata, exactly like the
        // IBus engine's do_focus_out.
        state->sawCapabilityMetadata = false;
    }

private:
    fcitx::Instance *instance_;
    fcitx::FactoryFor<OpenBurnBarState> factory_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>>
        eventWatchers_;
};

class OpenBurnBarEngineFactory final : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new OpenBurnBarEngine(manager->instance());
    }
};

} // namespace

FCITX_ADDON_FACTORY(OpenBurnBarEngineFactory)
