// Standalone native Foundation diagnostic. This is fixture setup evidence,
// not a product authority gate or substitute for HostProtectedReferenceTests.
import Foundation

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("rightclick-command-probe-" + UUID().uuidString)
try manager.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: root) }
let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
let powershell = "WindowsPowerShell\\v1.0\\powershell.exe"

// Observe native environment lookup without exporting PATH or host filenames.
let environment = ProcessInfo.processInfo.environment
let pathKeys = environment.keys.filter { $0.caseInsensitiveCompare("PATH") == .orderedSame }.sorted()
let nativePath = pathKeys.first.flatMap { environment[$0] } ?? ""
let pythonCandidates = nativePath.split(separator: ";").map {
    URL(fileURLWithPath: String($0)).appendingPathComponent("python.exe")
}
let python = pythonCandidates.first { manager.fileExists(atPath: $0.path) }
let pythonDiagnostic = try JSONSerialization.data(withJSONObject: [
    "case": "actual-native-python-lookup-before-ci-provisioning", "pathKeySpellings": pathKeys,
    "oldExactPATHLookupPresent": environment["PATH"] != nil,
    "pathComponentCount": pythonCandidates.count, "caseInsensitivePythonPresent": python != nil,
    "scope": "fixture-provisioning-only"], options: [.sortedKeys])
print(String(decoding: pythonDiagnostic, as: UTF8.self))

func invoke(_ label: String, _ executable: String, _ arguments: [String], nativeModules: Bool = false) throws -> Int32 {
    let output = root.appendingPathComponent(UUID().uuidString + ".log")
    try Data().write(to: output, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close(); try? manager.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: system + "\\System32\\" + executable)
    process.arguments = arguments
    if nativeModules {
        var environment = ProcessInfo.processInfo.environment.filter {
            $0.key.caseInsensitiveCompare("PSModulePath") != .orderedSame
        }
        environment["PSModulePath"] = system + "\\System32\\WindowsPowerShell\\v1.0\\Modules"
        process.environment = environment
    }
    process.standardOutput = handle; process.standardError = handle
    try process.run(); process.waitUntilExit(); try handle.synchronize()
    let reader = try FileHandle(forReadingFrom: output)
    defer { try? reader.close() }
    let bytes = try reader.read(upToCount: 16_384) ?? Data()
    let diagnostic = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: root.path, with: "<owned-fixture>")
        .replacingOccurrences(of: root.path.replacingOccurrences(of: "/", with: "\\"), with: "<owned-fixture>")
    let data = try JSONSerialization.data(withJSONObject: ["case": label, "exitCode": process.terminationStatus,
        "diagnostic": diagnostic, "scope": "fixture-setup-only"], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    return process.terminationStatus
}

let target = root.appendingPathComponent("target", isDirectory: true)
try manager.createDirectory(at: target, withIntermediateDirectories: false)
let marker = Data("synthetic-command-fixture".utf8)
try marker.write(to: target.appendingPathComponent("marker"), options: .withoutOverwriting)
for nativeSeparators in [false, true] {
    let alias = root.appendingPathComponent(nativeSeparators ? "native-alias" : "original-alias", isDirectory: true)
    let path: (URL) -> String = { nativeSeparators ? $0.path.replacingOccurrences(of: "/", with: "\\") : $0.path }
    let result = try invoke(nativeSeparators ? "native-separator-mklink" : "original-foundation-mklink",
        "cmd.exe", ["/d", "/c", "mklink", "/J", path(alias), path(target)])
    let readback = (try? Data(contentsOf: alias.appendingPathComponent("marker"))) == marker
    let data = try JSONSerialization.data(withJSONObject: ["case": nativeSeparators ? "native-alias-readback" : "original-alias-readback",
        "commandSucceeded": result == 0, "exactMarkerRead": readback, "foundationPathHasSlash": alias.path.contains("/"),
        "scope": "fixture-setup-only"], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if result == 0 {
        _ = try invoke("remove-owned-junction", "cmd.exe", ["/d", "/c", "rmdir", path(alias)])
    }
}

let selected = root.appendingPathComponent("null-dacl")
try Data("synthetic-private-reference".utf8).write(to: selected, options: .withoutOverwriting)
let selectedPath = selected.path.replacingOccurrences(of: "'", with: "''")
_ = try invoke("assign-readonly-fixture", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "[System.IO.File]::SetAttributes('\(selectedPath)', [System.IO.FileAttributes]::ReadOnly)"])
_ = try invoke("original-null-dacl-script", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "$acl=Get-Acl -LiteralPath '\(selectedPath)'; $acl.SetSecurityDescriptorSddlForm('D:NO_ACCESS_CONTROL', [System.Security.AccessControl.AccessControlSections]::Access); Set-Acl -LiteralPath '\(selectedPath)' -AclObject $acl -ErrorAction Stop"])
_ = try invoke("native-module-null-dacl-script", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "$ErrorActionPreference='Stop'; $acl=Get-Acl -LiteralPath '\(selectedPath)'; $acl.SetSecurityDescriptorSddlForm('D:NO_ACCESS_CONTROL', [System.Security.AccessControl.AccessControlSections]::Access); Set-Acl -LiteralPath '\(selectedPath)' -AclObject $acl -ErrorAction Stop; (Get-Acl -LiteralPath '\(selectedPath)').GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)"], nativeModules: true)

// Independently inspect the native descriptor. An empty DACL is a different
// state from present+NULL; neither a zero shell exit nor blank SDDL proves it.
let descriptorProbe = #"""
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class RightClickNativeDACLProbe {
  [StructLayout(LayoutKind.Sequential)] public struct ACL_SIZE_INFORMATION { public uint AceCount, AclBytesInUse, AclBytesFree; }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] public static extern uint GetNamedSecurityInfo(string path, uint type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
  [DllImport("advapi32.dll")] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, [MarshalAs(UnmanagedType.Bool)] out bool present, out IntPtr dacl, [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
  [DllImport("advapi32.dll")] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool GetAclInformation(IntPtr acl, out ACL_SIZE_INFORMATION information, uint size, uint kind);
  [DllImport("advapi32.dll")] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool InitializeAcl(IntPtr acl, uint size, uint revision);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] public static extern uint SetNamedSecurityInfo(string path, uint type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr pointer);
  public static string Inspect(string path, string label) {
    IntPtr owner,group,dacl,sacl,descriptor; uint error=GetNamedSecurityInfo(path,1,4,out owner,out group,out dacl,out sacl,out descriptor);
    if(error!=0) return "{\"case\":\""+label+"\",\"descriptorError\":"+error+"}";
    try {
      bool present,defaulted; IntPtr actual; bool ok=GetSecurityDescriptorDacl(descriptor,out present,out actual,out defaulted);
      ACL_SIZE_INFORMATION size=new ACL_SIZE_INFORMATION(); bool measured=ok && actual!=IntPtr.Zero && GetAclInformation(actual,out size,(uint)Marshal.SizeOf(typeof(ACL_SIZE_INFORMATION)),2);
      return "{\"case\":\""+label+"\",\"descriptorRead\":"+ok.ToString().ToLowerInvariant()+",\"daclPresent\":"+present.ToString().ToLowerInvariant()+",\"daclIsNull\":"+(actual==IntPtr.Zero).ToString().ToLowerInvariant()+",\"daclDefaulted\":"+defaulted.ToString().ToLowerInvariant()+",\"aceCountMeasured\":"+measured.ToString().ToLowerInvariant()+",\"aceCount\":"+size.AceCount+"}";
    } finally { LocalFree(descriptor); }
  }
  public static uint SetNull(string path) { return SetNamedSecurityInfo(path,1,4,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero); }
  public static uint SetEmpty(string path) {
    IntPtr acl=Marshal.AllocHGlobal(8); try { if(!InitializeAcl(acl,8,2)) return 87; return SetNamedSecurityInfo(path,1,4,IntPtr.Zero,IntPtr.Zero,acl,IntPtr.Zero); } finally { Marshal.FreeHGlobal(acl); }
  }
}
'@
"""#
let classify = descriptorProbe + "\n$ErrorActionPreference='Stop'; " +
    "[RightClickNativeDACLProbe]::Inspect('\(selectedPath)','exact-powershell-sddl-recipe'); " +
    "$nullResult=[RightClickNativeDACLProbe]::SetNull('\(selectedPath)'); if($nullResult -ne 0){throw \"Native NULL DACL assignment failed: $nullResult\"}; " +
    "[RightClickNativeDACLProbe]::Inspect('\(selectedPath)','native-present-null-control'); " +
    "$emptyResult=[RightClickNativeDACLProbe]::SetEmpty('\(selectedPath)'); if($emptyResult -ne 0){throw \"Native empty DACL assignment failed: $emptyResult\"}; " +
    "[RightClickNativeDACLProbe]::Inspect('\(selectedPath)','native-empty-dacl-contrast'); " +
    "$nullResult=[RightClickNativeDACLProbe]::SetNull('\(selectedPath)'); if($nullResult -ne 0){throw \"Native NULL restoration failed: $nullResult\"}"
_ = try invoke("native-actual-dacl-classification", powershell,
    ["-NoProfile", "-NonInteractive", "-Command", classify], nativeModules: true)
_ = try invoke("release-owned-fixture", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "[System.IO.File]::SetAttributes('\(selectedPath)', [System.IO.FileAttributes]::Normal)"])
