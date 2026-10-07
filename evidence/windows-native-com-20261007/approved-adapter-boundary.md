# Approved native Windows adapter boundary

Frozen production base: `38b27e45e9f566588b398ace20ca3ed07a529da3`.
Frozen controls: `c4f7225cdec236ed1dcb371419fdad1ebe7dbe06`; production source remains unchanged.

The chosen acquisition interface is the native Running Object Table plus `IDispatch::GetTypeInfo`/`ITypeInfo`. It enumerates already-running objects and reads their actual declarations. The product will not activate COM classes, load fixture libraries, invoke arbitrary commands or contain a member catalogue. CIM/MI offers dynamic class/method declarations but adds namespace/provider installation scope; ROT/Automation gives the smallest direct already-running software boundary for this focused gap.

The bridge will own native interfaces in a single MTA. Retained canonical `IUnknown` identifies an object within that apartment; an opaque random acquisition token enters the common declaration, never a native pointer. Equal duplicate monikers fail closed. Metadata and current ROT identity are rechecked before preparing an invocation and immediately before native Invoke. Observed absence permanently invalidates a retained token. COM has no atomic ROT-check/Invoke transaction and does not prove all unobserved same-object revoke/register cycles; this limitation remains explicit.

The closed first type subset is BSTR, BOOL, I8, finite R8 and explicit VOID results. Unsupported widths, arrays, by-reference values, user types, optional/out/default parameters and ambiguous declarations are omitted. Strings keep embedded NUL and valid Unicode; Int64 and binary64 preserve exact native bits. Narrow integer signatures abstain because the current common schema cannot express their width constraints.

The proposed Swift compiler will produce ordinary `CapabilityInterfaceOperation` values. The proposed resolver and running-object source will produce the existing `CapabilityInterfaceReflector`. Exact member invocation maps to `.execute`, as native D-Bus does; application side effects remain unknown, safety is unknown, and confirmation is mandatory. Unknown RCIR scopes still reject. Acquisition identity, ordered native member declaration, arguments and exact target/member scopes enter the existing ABI/RCIR contract.

The planned bridge will have catalog/validate/prepare, immediate one-shot enqueue, bounded result wait and release functions. All COM RPC occurs outside the common admission lock. The admitted start enqueues only the exact prepared call after checking cached token validity; the native worker performs the final identity check before Invoke. Cancellation is a request, not a guarantee of zero effects. Any error or timeout after admission remains UNKNOWN; the planned client must quarantine, never retry, and shutdown must never join an unresponsive RPC. Queue, metadata and outstanding native worker counts must be bounded.

No alternate host, authority model, policy engine, task lifecycle, journal, verifier or top-level AI tool is added. The independent infrastructure readback proves disposable native effect bytes but grants no runtime semantic success or signed receipt. This engineering gate cannot mark Windows or the eleven-world restricted-agent acceptance GREEN.

Composition changes: new RightClickWindowsCOM target; Core dependency; Windows-only Ole32/OleAut32 links; Windows source guard in CapabilityRuntimeDefaults; Windows resolver guard in CapabilityArtifactResolverDefaults. Existing HostFiles, common ABI, Host and gRPC task interfaces remain untouched.

Primary interfaces:
- https://learn.microsoft.com/en-us/windows/win32/api/objidl/nn-objidl-irunningobjecttable
- https://learn.microsoft.com/en-us/windows/win32/api/oaidl/nn-oaidl-itypeinfo
- https://learn.microsoft.com/en-us/windows/win32/api/oaidl/nf-oaidl-idispatch-invoke
- https://learn.microsoft.com/en-us/windows/win32/com/rules-for-implementing-queryinterface
- https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coenablecallcancellation
- https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-cocancelcall
