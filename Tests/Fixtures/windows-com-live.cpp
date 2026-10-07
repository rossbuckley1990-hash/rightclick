// Disposable native COM/Automation proof provider and independent oracle.
// It is test infrastructure; production never contains its member catalogue.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
#include <atomic>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

static std::string utf8(const wchar_t* p, size_t length) {
    if (length > 1048576) throw std::runtime_error("native string limit");
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p, (int)length, nullptr, 0, nullptr, nullptr);
    if (n == 0 && length != 0) throw std::runtime_error("invalid UTF16");
    std::string result(n, '\0');
    if (n && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p, (int)length, result.data(), n, nullptr, nullptr))
        throw std::runtime_error("UTF8 conversion failed");
    return result;
}
static std::string utf8(BSTR value) { return utf8(value, value ? SysStringLen(value) : 0); }
static std::string quote(const std::string& value) {
    std::string result = "\"";
    for (unsigned char c : value) {
        if (c == '\\' || c == '"') { result += '\\'; result += c; }
        else if (c < 32) { char b[7]; std::snprintf(b, sizeof(b), "\\u%04x", (unsigned)c); result += b; }
        else result += c;
    }
    return result + "\"";
}
static void checked(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::cerr << operation << " HRESULT=" << std::hex << (unsigned long)result << '\n';
        throw std::runtime_error(operation);
    }
}
template<class T> struct Com {
    T* p = nullptr;
    Com() = default;
    Com(const Com&) = delete;
    Com& operator=(const Com&) = delete;
    Com(Com&& other) noexcept : p(std::exchange(other.p, nullptr)) {}
    ~Com() { if (p) p->Release(); }
    T** out() { if (p) { p->Release(); p = nullptr; } return &p; }
    T* operator->() const { return p; }
};
static void file(const fs::path& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), bytes.size()); out.flush();
    if (!out) throw std::runtime_error("fixture write failed");
}
static std::string display(IMoniker* moniker) {
    Com<IBindCtx> context; checked(CreateBindCtx(0, context.out()), "CreateBindCtx");
    LPOLESTR name = nullptr;
    checked(moniker->GetDisplayName(context.p, nullptr, &name), "GetDisplayName");
    std::string result = utf8(name, wcslen(name)); CoTaskMemFree(name); return result;
}
static Com<IDispatch> lookup(const std::string& wanted) {
    Com<IRunningObjectTable> rot; checked(GetRunningObjectTable(0, rot.out()), "GetRunningObjectTable");
    Com<IEnumMoniker> enumeration; checked(rot->EnumRunning(enumeration.out()), "EnumRunning");
    Com<IDispatch> result;
    IMoniker* raw = nullptr; ULONG fetched = 0; unsigned seen = 0;
    while (enumeration->Next(1, &raw, &fetched) == S_OK) {
        Com<IMoniker> moniker; moniker.p = raw;
        if (display(moniker.p) != wanted) continue;
        if (++seen != 1) throw std::runtime_error("ambiguous moniker");
        Com<IUnknown> object; checked(rot->GetObject(moniker.p, object.out()), "ROT GetObject");
        checked(object->QueryInterface(IID_IDispatch, reinterpret_cast<void**>(result.out())), "IDispatch");
    }
    if (!result.p) throw std::runtime_error("object absent");
    return result;
}

class Fixture final : public IDispatch {
    std::atomic<ULONG> references{1};
    ITypeInfo* information;
    fs::path directory;
    unsigned effects = 0;
public:
    Fixture(ITypeInfo* type, fs::path dir) : information(type), directory(std::move(dir)) { information->AddRef(); }
    ~Fixture() { information->Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid == IID_IUnknown || iid == IID_IDispatch) { *out = static_cast<IDispatch*>(this); AddRef(); return S_OK; }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --references; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE GetTypeInfoCount(UINT* count) override { if (!count) return E_POINTER; *count = 1; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetTypeInfo(UINT index, LCID, ITypeInfo** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (index != 0) return DISP_E_BADINDEX;
        *out = information; information->AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetIDsOfNames(REFIID iid, LPOLESTR* names, UINT count, LCID, DISPID* ids) override {
        if (iid != IID_NULL) return DISP_E_UNKNOWNINTERFACE;
        return information->GetIDsOfNames(names, count, ids);
    }
    HRESULT STDMETHODCALLTYPE Invoke(DISPID member, REFIID iid, LCID, WORD flags, DISPPARAMS* arguments,
                                     VARIANT* result, EXCEPINFO*, UINT* badArgument) override {
        if (iid != IID_NULL) return DISP_E_UNKNOWNINTERFACE;
        if (!arguments || !result) return E_POINTER;
        VariantInit(result);
        TYPEATTR* attributes = nullptr;
        if (FAILED(information->GetTypeAttr(&attributes))) return E_FAIL;
        bool supported = false;
        for (UINT i = 0; i < attributes->cFuncs; ++i) {
            FUNCDESC* description = nullptr;
            if (SUCCEEDED(information->GetFuncDesc(i, &description))) {
                supported |= description->memid == member && description->invkind == INVOKE_FUNC &&
                    description->cParams == 3 && description->elemdescFunc.tdesc.vt == VT_BSTR &&
                    description->lprgelemdescParam[0].tdesc.vt == VT_BSTR &&
                    description->lprgelemdescParam[1].tdesc.vt == VT_I8 &&
                    description->lprgelemdescParam[2].tdesc.vt == VT_BOOL;
                information->ReleaseFuncDesc(description);
            }
        }
        information->ReleaseTypeAttr(attributes);
        if (!supported || flags != DISPATCH_METHOD) return DISP_E_MEMBERNOTFOUND;
        if (arguments->cArgs != 3 || arguments->cNamedArgs != 0) return DISP_E_BADPARAMCOUNT;
        const VARTYPE types[3] = {VT_BOOL, VT_I8, VT_BSTR};
        for (UINT i = 0; i < 3; ++i) {
            if (arguments->rgvarg[i].vt != types[i]) { if (badArgument) *badArgument = i; return DISP_E_TYPEMISMATCH; }
        }
        try {
            const VARIANT& flag = arguments->rgvarg[0];
            const VARIANT& number = arguments->rgvarg[1];
            const VARIANT& message = arguments->rgvarg[2];
            if (flag.boolVal != VARIANT_TRUE && flag.boolVal != VARIANT_FALSE) return DISP_E_TYPEMISMATCH;
            std::string text = utf8(message.bstrVal), bytes;
            uint32_t length = static_cast<uint32_t>(text.size());
            for (unsigned i = 0; i < 4; ++i) bytes += char(length >> (i * 8));
            bytes += text;
            uint64_t integer = static_cast<uint64_t>(number.llVal);
            for (unsigned i = 0; i < 8; ++i) bytes += char(integer >> (i * 8));
            bytes += flag.boolVal == VARIANT_TRUE ? '\1' : '\0';
            file(directory / ("effect-" + std::to_string(++effects) + ".bin"), bytes);
            file(directory / "effect-count", std::to_string(effects));
            result->vt = VT_BSTR;
            result->bstrVal = SysAllocStringLen(message.bstrVal, SysStringLen(message.bstrVal));
            if (!result->bstrVal && SysStringLen(message.bstrVal)) return E_OUTOFMEMORY;
            return S_OK;
        } catch (...) { return E_FAIL; }
    }
};

static int serve(const fs::path& directory, const fs::path& libraryPath, const wchar_t* guidText, const wchar_t* monikerName) {
    GUID interfaceID; checked(CLSIDFromString(guidText, &interfaceID), "type GUID");
    Com<ITypeLib> library; checked(LoadTypeLibEx(libraryPath.c_str(), REGKIND_NONE, library.out()), "LoadTypeLibEx");
    checked(RegisterTypeLibForUser(library.p, const_cast<wchar_t*>(libraryPath.c_str()), nullptr), "RegisterTypeLibForUser");
    TLIBATTR* libraryAttributes = nullptr; checked(library->GetLibAttr(&libraryAttributes), "GetLibAttr");
    TLIBATTR saved = *libraryAttributes; library->ReleaseTLibAttr(libraryAttributes);
    Com<ITypeInfo> information; checked(library->GetTypeInfoOfGuid(interfaceID, information.out()), "GetTypeInfoOfGuid");
    Com<IDispatch> object; object.p = new Fixture(information.p, directory);
    Com<IMoniker> moniker; checked(CreateItemMoniker(L"!", monikerName, moniker.out()), "CreateItemMoniker");
    Com<IRunningObjectTable> rot; checked(GetRunningObjectTable(0, rot.out()), "GetRunningObjectTable");
    DWORD cookie = 0; checked(rot->Register(ROTFLAGS_REGISTRATIONKEEPSALIVE, object.p, moniker.p, &cookie), "ROT Register");
    file(directory / "ready.json", "{\"moniker\":" + quote(display(moniker.p)) + "}");
    bool revoked = false;
    for (;;) {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        if (!revoked && fs::exists(directory / "withdraw")) {
            checked(rot->Revoke(cookie), "ROT Revoke"); revoked = true;
            file(directory / "withdrawn", "native Revoke completed");
        }
        if (fs::exists(directory / "stop")) break;
        Sleep(10);
    }
    if (!revoked) checked(rot->Revoke(cookie), "ROT Revoke");
    checked(UnRegisterTypeLibForUser(saved.guid, saved.wMajorVerNum, saved.wMinorVerNum, saved.lcid, saved.syskind), "UnRegisterTypeLibForUser");
    return 0;
}

static int inspect(const std::string& monikerName) {
    Com<IDispatch> object = lookup(monikerName);
    Com<ITypeInfo> information; checked(object->GetTypeInfo(0, LOCALE_USER_DEFAULT, information.out()), "GetTypeInfo");
    TYPEATTR* attributes = nullptr; checked(information->GetTypeAttr(&attributes), "GetTypeAttr");
    std::cout << "{\"nativeInterface\":\"ITypeInfo\",\"members\":[";
    for (UINT i = 0; i < attributes->cFuncs; ++i) {
        FUNCDESC* description = nullptr; checked(information->GetFuncDesc(i, &description), "GetFuncDesc");
        if (description->cParams > 64 || description->cParams < 0) throw std::runtime_error("parameter limit");
        std::vector<BSTR> names(description->cParams + 1, nullptr); UINT count = 0;
        checked(information->GetNames(description->memid, names.data(), static_cast<UINT>(names.size()), &count), "GetNames");
        if (i) std::cout << ',';
        std::cout << "{\"dispid\":" << description->memid << ",\"kind\":" << description->invkind
            << ",\"returnType\":" << description->elemdescFunc.tdesc.vt << ",\"names\":[";
        for (UINT j = 0; j < count; ++j) { if (j) std::cout << ','; std::cout << quote(utf8(names[j])); SysFreeString(names[j]); }
        std::cout << "],\"parameterTypes\":[";
        for (int j = 0; j < description->cParams; ++j) { if (j) std::cout << ','; std::cout << description->lprgelemdescParam[j].tdesc.vt; }
        std::cout << "]}"; information->ReleaseFuncDesc(description);
    }
    information->ReleaseTypeAttr(attributes);
    std::cout << "]}" << std::endl;
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    HRESULT initialization = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(initialization)) return 2;
    int code = 0;
    try {
        if (argc == 6 && std::wstring(argv[1]) == L"serve") code = serve(argv[2], argv[3], argv[4], argv[5]);
        else if (argc == 3 && std::wstring(argv[1]) == L"inspect") code = inspect(utf8(argv[2], wcslen(argv[2])));
        else throw std::runtime_error("fixture arguments");
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; code = 1; }
    CoUninitialize(); return code;
}
