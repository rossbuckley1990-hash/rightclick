#include "RightClickWindowsCOM.h"
#include <cstdlib>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
constexpr size_t maximumBytes = 1048576, maximumObjects = 64, maximumMembers = 256, maximumParameters = 32;
constexpr unsigned timeoutMilliseconds = 3000;
std::atomic<unsigned> workers{0};
struct Failure { int status; };
void require(bool value, int status = 2) { if (!value) throw Failure{status}; }
void checked(HRESULT value) { if (FAILED(value)) throw Failure{1}; }
template<class T> struct Com {
    T *p = nullptr;
    Com() = default;
    Com(const Com&) = delete;
    Com& operator=(const Com&) = delete;
    Com(Com&& other) noexcept : p(std::exchange(other.p, nullptr)) {}
    Com& operator=(Com&& other) noexcept { if (this != &other) { if (p) p->Release(); p = std::exchange(other.p, nullptr); } return *this; }
    ~Com() { if (p) p->Release(); }
    T **out() { if (p) p->Release(); p = nullptr; return &p; }
    T *operator->() const { return p; }
};
std::string utf8(const wchar_t *p, size_t length) {
    require(length <= maximumBytes && (p || !length));
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    require(n > 0 || !length);
    require(static_cast<size_t>(n) <= maximumBytes);
    std::string result(n, '\0');
    if (n) require(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p, static_cast<int>(length), &result[0], n, nullptr, nullptr) == n);
    return result;
}
std::string utf8(BSTR value) { return utf8(value, value ? SysStringLen(value) : 0); }
std::wstring utf16(const std::string& value) {
    require(value.size() <= maximumBytes);
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    require(n > 0 || value.empty());
    std::wstring result(n, L'\0');
    if (n) require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), &result[0], n) == n);
    return result;
}
std::string quote(const std::string& text) {
    require(text.size() <= maximumBytes);
    const char digits[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char c : text) {
        if (c == '\\' || c == '"') { result += '\\'; result += c; }
        else if (c < 32) { result += "\\u00"; result += digits[c >> 4]; result += digits[c & 15]; }
        else result += c;
    }
    return result + '"';
}
std::string guid(REFGUID value) {
    wchar_t text[40]; require(StringFromGUID2(value, text, 40) > 0);
    return utf8(text + 1, 36);
}
std::string token() { GUID value; checked(CoCreateGuid(&value)); return guid(value); }
std::string display(IMoniker *moniker) {
    Com<IBindCtx> context; checked(CreateBindCtx(0, context.out()));
    LPOLESTR text = nullptr; checked(moniker->GetDisplayName(context.p, nullptr, &text));
    struct Free { LPOLESTR p; ~Free() { CoTaskMemFree(p); } } owner{text};
    require(text != nullptr);
    size_t length = 0; while (length <= 4096 && text[length]) ++length;
    require(length > 0 && length <= 4096);
    std::string name = utf8(text, length);
    for (unsigned char c : name) require(c >= 32 && c != 127);
    return name;
}
struct Parameter { std::string name; unsigned type, flags; };
struct Member {
    int32_t id; std::string name; unsigned kind, functionKind, flags, optional, result, resultFlags, scodes;
    std::vector<Parameter> parameters;
    bool supported() const {
        auto type = [](unsigned value) { return value == VT_BSTR || value == VT_BOOL || value == VT_I8 || value == VT_R8; };
        if (kind != INVOKE_FUNC || functionKind != FUNC_DISPATCH || flags || optional || resultFlags || scodes ||
            !(type(result) || result == VT_VOID)) return false;
        for (const auto& p : parameters) if (p.flags != PARAMFLAG_FIN || !type(p.type)) return false;
        return true;
    }
};
struct Metadata { std::string json; std::vector<Member> members; LCID locale; };
Metadata metadata(IDispatch *object) {
    UINT count = 0; checked(object->GetTypeInfoCount(&count)); require(count == 1);
    Metadata result; result.locale = GetUserDefaultLCID();
    Com<ITypeInfo> info; checked(object->GetTypeInfo(0, result.locale, info.out()));
    TYPEATTR *raw = nullptr; checked(info->GetTypeAttr(&raw)); require(raw != nullptr);
    struct Attr { ITypeInfo *i; TYPEATTR *p; ~Attr() { i->ReleaseTypeAttr(p); } } attr{info.p, raw};
    require(raw->typekind == TKIND_DISPATCH && raw->cFuncs <= maximumMembers);
    Com<ITypeLib> library; UINT index = 0; checked(info->GetContainingTypeLib(library.out(), &index));
    TLIBATTR *lr = nullptr; checked(library->GetLibAttr(&lr)); require(lr != nullptr);
    struct LibraryAttr { ITypeLib *i; TLIBATTR *p; ~LibraryAttr() { i->ReleaseTLibAttr(p); } } la{library.p, lr};
    result.json = "{\"format\":1,\"interfaceGUID\":" + quote(guid(raw->guid)) + ",\"typeKind\":" + std::to_string(raw->typekind) +
        ",\"typeFlags\":" + std::to_string(raw->wTypeFlags) + ",\"major\":" + std::to_string(raw->wMajorVerNum) +
        ",\"minor\":" + std::to_string(raw->wMinorVerNum) + ",\"locale\":" + std::to_string(result.locale) +
        ",\"libraryGUID\":" + quote(guid(lr->guid)) + ",\"libraryMajor\":" + std::to_string(lr->wMajorVerNum) +
        ",\"libraryMinor\":" + std::to_string(lr->wMinorVerNum) + ",\"libraryLocale\":" + std::to_string(lr->lcid) +
        ",\"librarySystem\":" + std::to_string(lr->syskind) + ",\"libraryIndex\":" + std::to_string(index) + ",\"members\":[";
    for (UINT n = 0; n < raw->cFuncs; ++n) {
        FUNCDESC *fd = nullptr; checked(info->GetFuncDesc(n, &fd)); require(fd != nullptr);
        struct Func { ITypeInfo *i; FUNCDESC *p; ~Func() { i->ReleaseFuncDesc(p); } } func{info.p, fd};
        require(fd->cParams >= 0 && static_cast<size_t>(fd->cParams) <= maximumParameters);
        require(fd->cParams == 0 || fd->lprgelemdescParam != nullptr);
        std::vector<BSTR> names(fd->cParams + 1, nullptr); UINT found = 0;
        struct Names { std::vector<BSTR>& p; ~Names() { for (auto s : p) SysFreeString(s); } } namesOwner{names};
        checked(info->GetNames(fd->memid, names.data(), static_cast<UINT>(names.size()), &found));
        require(found == names.size());
        Member member{fd->memid, utf8(names[0]), static_cast<unsigned>(fd->invkind), static_cast<unsigned>(fd->funckind),
            fd->wFuncFlags, static_cast<unsigned>(fd->cParamsOpt), fd->elemdescFunc.tdesc.vt,
            fd->elemdescFunc.paramdesc.wParamFlags, static_cast<unsigned>(fd->cScodes), {}};
        if (n) result.json += ',';
        result.json += "{\"id\":" + std::to_string(member.id) + ",\"name\":" + quote(member.name) +
            ",\"kind\":" + std::to_string(member.kind) + ",\"functionKind\":" + std::to_string(member.functionKind) +
            ",\"flags\":" + std::to_string(member.flags) + ",\"optional\":" + std::to_string(member.optional) +
            ",\"result\":" + std::to_string(member.result) + ",\"resultFlags\":" + std::to_string(member.resultFlags) +
            ",\"scodes\":" + std::to_string(member.scodes) + ",\"parameters\":[";
        for (int p = 0; p < fd->cParams; ++p) {
            Parameter parameter{utf8(names[p + 1]), fd->lprgelemdescParam[p].tdesc.vt, fd->lprgelemdescParam[p].paramdesc.wParamFlags};
            if (p) result.json += ',';
            result.json += "{\"name\":" + quote(parameter.name) + ",\"type\":" + std::to_string(parameter.type) +
                ",\"flags\":" + std::to_string(parameter.flags) + '}';
            member.parameters.push_back(std::move(parameter));
        }
        result.json += "]}";
        result.members.push_back(std::move(member));
        require(result.json.size() <= maximumBytes);
    }
    result.json += "]}"; require(result.json.size() <= maximumBytes);
    return result;
}
std::vector<Com<IMoniker>> monikers(IRunningObjectTable *rot) {
    Com<IEnumMoniker> cursor; checked(rot->EnumRunning(cursor.out()));
    std::vector<Com<IMoniker>> values;
    for (;;) {
        IMoniker *raw = nullptr; ULONG count = 0; HRESULT h = cursor->Next(1, &raw, &count);
        if (h == S_FALSE) { if (raw) raw->Release(); break; }
        checked(h); require(h == S_OK && count == 1 && raw != nullptr);
        Com<IMoniker> item; item.p = raw; values.push_back(std::move(item)); require(values.size() <= maximumObjects);
    }
    return values;
}
bool equal(IMoniker *a, IMoniker *b) { HRESULT h = a->IsEqual(b); require(h == S_OK || h == S_FALSE, 1); return h == S_OK; }
struct Entry {
    std::string token, name; Com<IMoniker> moniker; Com<IUnknown> identity; Com<IDispatch> dispatch; Metadata descriptor;
    std::shared_ptr<std::atomic<bool>> valid = std::make_shared<std::atomic<bool>>(true);
};
struct State;
struct Job {
    std::function<void(State&, Job&)> run;
    std::mutex mutex; std::condition_variable changed; bool done = false; int status = 1; std::string bytes;
};
void finish(const std::shared_ptr<Job>& job, int status) {
    std::lock_guard<std::mutex> lock(job->mutex); if (job->done) return;
    job->status = status; job->done = true; job->changed.notify_all();
}
struct State {
    std::mutex mutex; std::condition_variable changed; std::deque<std::shared_ptr<Job>> pending;
    std::mutex cancellation;
    std::atomic<bool> quarantined{false}, cancellationRequested{false}; std::atomic<DWORD> threadID{0}; bool stopping = false;
    std::map<std::string, std::unique_ptr<Entry>> entries;
    bool enqueue(const std::shared_ptr<Job>& job) {
        std::lock_guard<std::mutex> lock(mutex);
        if (quarantined || stopping || pending.size() >= 16) return false;
        pending.push_back(job); changed.notify_one(); return true;
    }
    void stop() {
        quarantined = true;
        std::deque<std::shared_ptr<Job>> abandoned;
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; abandoned.swap(pending); changed.notify_all(); }
        for (auto& job : abandoned) finish(job, 3);
    }
};
void quarantine(const std::shared_ptr<State>& state) {
    state->stop();
    // Never wait for a server, cancellation or proxy release on the caller.
    // At most one cancellation thread accompanies each of eight bounded MTAs.
    if (!state->cancellationRequested.exchange(true)) {
        try { std::thread([state] {
            HRESULT h = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            // Retirement and cancellation share this lock. The owning worker
            // cannot exit and allow its thread ID to be reused during Cancel.
            { std::lock_guard<std::mutex> lock(state->cancellation);
              DWORD threadID = state->threadID; if (threadID) CoCancelCall(threadID, 0); }
            if (SUCCEEDED(h)) CoUninitialize();
        }).detach(); } catch (...) { /* quarantine already prevents all new calls */ }
    }
}
void worker(const std::shared_ptr<State>& state) {
    state->threadID = GetCurrentThreadId();
    auto retire = [&] { std::lock_guard<std::mutex> lock(state->cancellation); state->threadID = 0; };
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialized)) { state->stop(); retire(); --workers; return; }
    HRESULT cancellable = CoEnableCallCancellation(nullptr);
    if (FAILED(cancellable)) { state->stop(); retire(); CoUninitialize(); --workers; return; }
    for (;;) {
        std::shared_ptr<Job> job;
        { std::unique_lock<std::mutex> lock(state->mutex); state->changed.wait(lock, [&] { return state->stopping || !state->pending.empty(); });
          if (state->stopping) break; job = state->pending.front(); state->pending.pop_front(); }
        int status = 0;
        try { require(!state->quarantined, 3); job->run(*state, *job); }
        catch (const Failure& f) { status = f.status; }
        catch (...) { status = 2; }
        finish(job, status);
    }
    for (auto& entry : state->entries) *entry.second->valid = false;
    state->entries.clear(); // COM release remains on its owning apartment.
    retire(); CoDisableCallCancellation(nullptr); CoUninitialize(); --workers;
}
int await(const std::shared_ptr<State>& state, const std::shared_ptr<Job>& job) {
    std::unique_lock<std::mutex> lock(job->mutex);
    if (!job->changed.wait_for(lock, std::chrono::milliseconds(timeoutMilliseconds), [&] { return job->done; })) {
        lock.unlock(); quarantine(state); return 3;
    }
    return job->status;
}
int submit(const std::shared_ptr<State>& state, const std::shared_ptr<Job>& job) {
    return state->enqueue(job) ? await(state, job) : 3;
}
int copy(const std::string& value, unsigned char **bytes, size_t *length) {
    require(bytes && length && value.size() <= maximumBytes);
    *bytes = nullptr; *length = 0;
    void *p = std::malloc(value.size() ? value.size() : 1); require(p != nullptr);
    if (!value.empty()) std::memcpy(p, value.data(), value.size());
    *bytes = static_cast<unsigned char*>(p); *length = value.size(); return 0;
}
Entry& current(State& state, const std::string& id) {
    auto found = state.entries.find(id); require(found != state.entries.end(), 1);
    Entry& entry = *found->second; require(*entry.valid, 1);
    try {
        Com<IRunningObjectTable> rot; checked(GetRunningObjectTable(0, rot.out()));
        auto names = monikers(rot.p); unsigned matches = 0;
        for (auto& name : names) if (equal(entry.moniker.p, name.p)) ++matches;
        require(matches == 1, 1);
        Com<IUnknown> object, identity; Com<IDispatch> dispatch;
        checked(rot->GetObject(entry.moniker.p, object.out()));
        checked(object->QueryInterface(__uuidof(IUnknown), reinterpret_cast<void**>(identity.out())));
        require(identity.p == entry.identity.p, 1);
        checked(object->QueryInterface(__uuidof(IDispatch), reinterpret_cast<void**>(dispatch.out())));
        require(metadata(dispatch.p).json == entry.descriptor.json, 1);
        require(!state.quarantined, 3);
        return entry;
    } catch (...) { *entry.valid = false; throw; }
}
struct Reader {
    const std::string& bytes; size_t cursor = 0;
    uint64_t integer(unsigned width) { require(width <= 8 && cursor + width <= bytes.size()); uint64_t result = 0;
        for (unsigned n = 0; n < width; ++n) result |= uint64_t(static_cast<unsigned char>(bytes[cursor++])) << (n * 8); return result; }
    std::string string() { size_t length = static_cast<size_t>(integer(4)); require(length <= maximumBytes && cursor + length <= bytes.size());
        std::string result = bytes.substr(cursor, length); cursor += length; (void)utf16(result); return result; }
};
void append(std::string& bytes, uint64_t value, unsigned width) { for (unsigned n = 0; n < width; ++n) bytes += char(value >> (n * 8)); }
struct Value { unsigned type; uint64_t bits = 0; std::string text; };
std::vector<Value> arguments(const Member& member, const std::string& bytes) {
    require(member.supported()); Reader read{bytes}; require(read.integer(4) == member.parameters.size());
    std::vector<Value> values;
    for (const auto& parameter : member.parameters) {
        Value value; value.type = static_cast<unsigned>(read.integer(2)); require(value.type == parameter.type);
        if (value.type == VT_BSTR) value.text = read.string();
        else if (value.type == VT_BOOL) { value.bits = read.integer(1); require(value.bits <= 1); }
        else { value.bits = read.integer(8); if (value.type == VT_R8) { double d; std::memcpy(&d, &value.bits, 8); require(std::isfinite(d)); } }
        values.push_back(std::move(value));
    }
    require(read.cursor == bytes.size()); return values;
}
std::string invoke(Entry& entry, const Member& member, const std::string& bytes) {
    auto supplied = arguments(member, bytes);
    std::vector<VARIANT> values(supplied.size()); for (auto& v : values) VariantInit(&v);
    struct Clear { std::vector<VARIANT>& values; ~Clear() { for (auto& v : values) VariantClear(&v); } } clear{values};
    for (size_t n = 0; n < supplied.size(); ++n) {
        const auto& input = supplied[n]; VARIANT& value = values[supplied.size() - 1 - n]; value.vt = static_cast<VARTYPE>(input.type);
        if (input.type == VT_BSTR) { auto wide = utf16(input.text); value.bstrVal = SysAllocStringLen(wide.data(), static_cast<UINT>(wide.size())); require(value.bstrVal || wide.empty()); }
        else if (input.type == VT_BOOL) value.boolVal = input.bits ? VARIANT_TRUE : VARIANT_FALSE;
        else if (input.type == VT_I8) std::memcpy(&value.llVal, &input.bits, 8);
        else std::memcpy(&value.dblVal, &input.bits, 8);
    }
    DISPPARAMS parameters{}; parameters.rgvarg = values.data(); parameters.cArgs = static_cast<UINT>(values.size());
    VARIANT result; VariantInit(&result); EXCEPINFO exception{}; UINT argumentError = 0;
    struct Result { VARIANT& value; EXCEPINFO& exception; ~Result() { VariantClear(&value); SysFreeString(exception.bstrSource); SysFreeString(exception.bstrDescription); SysFreeString(exception.bstrHelpFile); } } resultOwner{result, exception};
    const GUID nullID{};
    checked(entry.dispatch->Invoke(member.id, nullID, entry.descriptor.locale, DISPATCH_METHOD, &parameters, &result, &exception, &argumentError));
    unsigned expected = member.result == VT_VOID ? VT_EMPTY : member.result;
    require(result.vt == expected);
    std::string reply; append(reply, expected, 2);
    if (expected == VT_BSTR) { auto text = utf8(result.bstrVal); append(reply, text.size(), 4); reply += text; }
    else if (expected == VT_BOOL) { require(result.boolVal == VARIANT_TRUE || result.boolVal == VARIANT_FALSE); append(reply, result.boolVal == VARIANT_TRUE, 1); }
    else if (expected == VT_I8) { uint64_t bits; std::memcpy(&bits, &result.llVal, 8); append(reply, bits, 8); }
    else if (expected == VT_R8) { require(std::isfinite(result.dblVal)); uint64_t bits; std::memcpy(&bits, &result.dblVal, 8); append(reply, bits, 8); }
    require(reply.size() <= maximumBytes); return reply;
}
const Member& member(Entry& entry, int32_t id) {
    const Member *result = nullptr;
    for (const auto& value : entry.descriptor.members) if (value.id == id) { require(!result); result = &value; }
    require(result != nullptr && result->supported()); return *result;
}
std::string catalogue(State& state) {
    Com<IRunningObjectTable> rot; checked(GetRunningObjectTable(0, rot.out())); auto names = monikers(rot.p);
    std::vector<bool> duplicate(names.size(), false);
    for (size_t a = 0; a < names.size(); ++a) for (size_t b = a + 1; b < names.size(); ++b)
        if (equal(names[a].p, names[b].p)) duplicate[a] = duplicate[b] = true;
    // Invalidate absence/ambiguity before attempting metadata on any provider.
    for (auto& stored : state.entries) {
        bool present = false;
        for (size_t n = 0; n < names.size(); ++n) if (!duplicate[n] && equal(stored.second->moniker.p, names[n].p)) present = true;
        if (!present) *stored.second->valid = false;
    }
    std::string result = "["; bool first = true;
    for (size_t n = 0; n < names.size(); ++n) {
        require(!state.quarantined, 3);
        if (duplicate[n]) continue;
        IMoniker *observed = names[n].p;
        try {
            std::string name = display(names[n].p);
            Com<IUnknown> object, identity; Com<IDispatch> dispatch;
            checked(rot->GetObject(names[n].p, object.out()));
            checked(object->QueryInterface(__uuidof(IUnknown), reinterpret_cast<void**>(identity.out())));
            checked(object->QueryInterface(__uuidof(IDispatch), reinterpret_cast<void**>(dispatch.out())));
            auto descriptor = metadata(dispatch.p); Entry *held = nullptr;
            for (auto& stored : state.entries) if (*stored.second->valid && equal(stored.second->moniker.p, names[n].p)) {
                if (stored.second->identity.p == identity.p && stored.second->descriptor.json == descriptor.json) held = stored.second.get();
                else *stored.second->valid = false;
            }
            if (!held) {
                std::unique_ptr<Entry> entry(new Entry); entry->token = token(); entry->name = std::move(name);
                entry->moniker = std::move(names[n]); entry->identity = std::move(identity); entry->dispatch = std::move(dispatch); entry->descriptor = std::move(descriptor);
                held = entry.get(); std::string id = entry->token; state.entries.emplace(id, std::move(entry));
            }
            if (!first) result += ','; first = false;
            result += "{\"acquisitionID\":" + quote(held->token) + ",\"moniker\":" + quote(held->name) + ",\"declaration\":" + held->descriptor.json + '}';
            require(result.size() <= maximumBytes);
        } catch (const Failure&) {
            // An observed unavailable declaration cannot revive an old token.
            for (auto& stored : state.entries) {
                try { if (equal(stored.second->moniker.p, observed)) *stored.second->valid = false; }
                catch (...) { *stored.second->valid = false; }
            }
        }
    }
    for (auto it = state.entries.begin(); it != state.entries.end();) {
        if (!*it->second->valid) it = state.entries.erase(it); else ++it;
    }
    require(state.entries.size() <= maximumObjects); result += ']'; require(result.size() <= maximumBytes); return result;
}
} // namespace
struct rc_com_client { std::shared_ptr<State> state; };
struct rc_com_call {
    std::shared_ptr<State> state; std::shared_ptr<Job> job; std::shared_ptr<std::atomic<bool>> valid; std::atomic<bool> queued{false};
};
extern "C" rc_com_client *rc_com_open(void) {
    unsigned count = workers.fetch_add(1);
    if (count >= 8) { --workers; return nullptr; }
    try {
        std::unique_ptr<rc_com_client> client(new rc_com_client{std::make_shared<State>()});
        std::thread(worker, client->state).detach(); return client.release();
    } catch (...) { --workers; return nullptr; }
}
extern "C" void rc_com_close(rc_com_client *client) {
    if (!client) return;
    quarantine(client->state); delete client;
}
extern "C" int rc_com_catalog(rc_com_client *client, unsigned char **bytes, size_t *length) {
    try { require(client && bytes && length); *bytes = nullptr; *length = 0;
        auto job = std::make_shared<Job>(); job->run = [](State& state, Job& job) { job.bytes = catalogue(state); };
        int status = submit(client->state, job); return status ? status : copy(job->bytes, bytes, length);
    } catch (const Failure& f) { return f.status; } catch (...) { return 2; }
}
extern "C" int rc_com_validate(rc_com_client *client, const char *acquisition) {
    try { require(client && acquisition); std::string id(acquisition); require(id.size() == 36);
        auto job = std::make_shared<Job>(); job->run = [id](State& state, Job&) { (void)current(state, id); };
        return submit(client->state, job);
    } catch (const Failure& f) { return f.status; } catch (...) { return 2; }
}
extern "C" int rc_com_prepare(rc_com_client *client, const char *acquisition, int32_t id, const unsigned char *bytes, size_t length, rc_com_call **out) {
    try { require(client && acquisition && out && length <= maximumBytes && (bytes || !length)); *out = nullptr;
        std::string token(acquisition), input(reinterpret_cast<const char*>(bytes), length); require(token.size() == 36);
        std::unique_ptr<rc_com_call> call(new rc_com_call); call->state = client->state; call->job = std::make_shared<Job>();
        auto prepare = std::make_shared<Job>();
        auto validity = std::make_shared<std::shared_ptr<std::atomic<bool>>>();
        // Job-owned preparation state survives a timeout; no caller stack or
        // call object is borrowed by an RPC which can return after its deadline.
        prepare->run = [token, id, input, validity](State& state, Job&) { Entry& entry = current(state, token); (void)arguments(member(entry, id), input); *validity = entry.valid; };
        int status = submit(client->state, prepare); if (status) return status;
        call->valid = *validity;
        call->job->run = [token, id, input](State& state, Job& job) { Entry& entry = current(state, token); require(!state.quarantined, 3); job.bytes = invoke(entry, member(entry, id), input); };
        *out = call.release(); return 0;
    } catch (const Failure& f) { return f.status; } catch (...) { return 2; }
}
extern "C" int rc_com_enqueue(rc_com_call *call) {
    try { require(call && call->valid && *call->valid && !call->state->quarantined, 1);
        require(!call->queued.exchange(true), 1); return call->state->enqueue(call->job) ? 0 : 3;
    } catch (const Failure& f) { return f.status; } catch (...) { return 2; }
}
extern "C" int rc_com_wait(rc_com_call *call, unsigned char **bytes, size_t *length) {
    try { require(call && call->queued && bytes && length); *bytes = nullptr; *length = 0;
        int status = await(call->state, call->job); return status ? status : copy(call->job->bytes, bytes, length);
    } catch (const Failure& f) { return f.status; } catch (...) { return 2; }
}
extern "C" void rc_com_release_call(rc_com_call *call) { delete call; }
#else
extern "C" rc_com_client *rc_com_open(void) { return nullptr; }
extern "C" void rc_com_close(rc_com_client *) {}
extern "C" int rc_com_catalog(rc_com_client *, unsigned char **, size_t *) { return 1; }
extern "C" int rc_com_validate(rc_com_client *, const char *) { return 1; }
extern "C" int rc_com_prepare(rc_com_client *, const char *, int32_t, const unsigned char *, size_t, rc_com_call **) { return 1; }
extern "C" int rc_com_enqueue(rc_com_call *) { return 1; }
extern "C" int rc_com_wait(rc_com_call *, unsigned char **, size_t *) { return 1; }
extern "C" void rc_com_release_call(rc_com_call *) {}
#endif
extern "C" void rc_com_free(void *bytes) { std::free(bytes); }
