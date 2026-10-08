#!/usr/bin/env python3
"""Owned native diagnosis only; raw exports/logs leave the runner encrypted."""
import hashlib
import contextlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tarfile

from windows_test_supervisor import supervise

SOURCE = "2b15e1f43966ead4641a0838dac166191eeb4482"
SHIPPING = "2525794c390d19d54871f1a9695462425fc13051"
DIAGNOSTIC_TEST = "Tests/RightClickCoreTests/WindowsCompilerSearchRoleDiagnosticTests.swift"
SOURCES_TREE = "0133e050845ff05e8b588f42eabe7fc1da00634d"
CERT_SHA = "1f10ec5ff26b0ef1fbb91248ac954cf15757e8782101f90abe05a171af58bf9d"
BASELINE_SHA = "d6d94c83ca85381cecc7e3856a906dc18442a784ab5746e418562c2cbb529be9"
INPUTS = ["Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests",
          "Vendor", "fixtures", "packaging", "scripts"]
FILTER = r"^RightClickCoreTests\.WindowsCompilerSearchRoleDiagnosticTests/testSameOwnedCompilerIsolatedSystem32Isolated$"
EXPORTS = []
PHASE_LOGS = {"build": "build-output.log", "discovery": "discovery-output.log",
              "focused": "focused-test-output.log"}
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 24 * 1024 * 1024
SAFE = Path("focused-safe")
PRIVATE = Path("focused-private")
NAME = re.compile(r"RightClick\w+Tests\.\w+/\w+")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unsafe_path(path):
    path = path.absolute()  # Do not resolve away a symlink/junction boundary.
    return any(p.is_symlink() or (getattr(p, "is_junction", lambda: False)())
               for p in (path, *path.parents))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, timeout=30, **kwargs)


def git(*args):
    result = command(["git", *args])
    if result.returncode:
        raise ValueError("git_provenance")
    return result.stdout


def checked_names(data, count):
    if (not isinstance(data, list) or len(data) != count
            or any(not isinstance(x, str) or not NAME.fullmatch(x) for x in data)
            or len(set(data)) != count):
        raise ValueError("inventory")
    return set(data)


def inventory(text, expected, baseline):
    names = [x.strip() for x in text.splitlines() if NAME.fullmatch(x.strip())]
    current = checked_names(names, 703)
    if not expected.issubset(current) or not baseline.issubset(current):
        raise ValueError("inventory_preservation")
    return {"all703NamesUnique": True, "all702ShippingNamesPreserved": True,
            "selectedNames": sorted(expected)}


def execution(text, expected):
    # XCTest omits the target prefix; exact discovery maps each class uniquely.
    short = {x.split(".", 1)[1].replace("/", "."): x for x in expected}
    if len(short) != 1:
        raise ValueError("selected_names")
    starts = re.findall(r"Test Case '([^']+)' started", text)
    finishes = re.findall(r"Test Case '([^']+)' (passed|failed|skipped) \(([0-9.]+) seconds\)", text)
    if (len(starts) != 1 or set(starts) != set(short)
            or len(finishes) != 1 or {x[0] for x in finishes} != set(short)):
        raise ValueError("selected_completion")
    results = [{"test": short[n], "state": state, "seconds": float(seconds)}
               for n, state, seconds in finishes]
    return {"starts": 1, "finishes": 1, "results": results,
            "passes": sum(x["state"] == "passed" for x in results),
            "failures": sum(x["state"] == "failed" for x in results),
            "skips": sum(x["state"] == "skipped" for x in results),
            "swiftTestingZeroSuiteObserved": bool(re.search(
                r"Test run with 0 tests in 0 suites passed", text))}


def compiler_search_observation(text):
    # Only closed labels and bounded scalars leave the encrypted raw interval.
    pattern = (r"TrustedHostContext compilerProfile comparison=nativeSearchRole "
        r"profile=(isolatedBefore|explicitSystemSearch|isolatedAfter) index=([0-2]) "
        r"outcome=(completed|childFailed) started=(true|false) exit=(-?[0-9]{1,10}|none) "
        r"stdoutBytes=([0-9]{1,5}) elapsedMilliseconds=([0-9]+(?:\.[0-9]+)?(?:e[-+]?[0-9]+)?) "
        r"freshPE=(true|false) outputSHA256=([0-9a-f]{64}|none) stableOutput=(true|false) "
        r"unchangedInputs=(true|false) parentAndStdoutClosed=(true|false) ownedGroupClosureClaimed=(true|false)")
    profiles = []
    for m in re.finditer(pattern, text):
        row = {"profile": m[1], "index": int(m[2]), "outcome": m[3], "started": m[4] == "true",
            "exit": None if m[5] == "none" else int(m[5]), "stdoutBytes": int(m[6]),
            "elapsedMilliseconds": float(m[7]), "freshPE": m[8] == "true", "outputSHA256": m[9],
            "stableOutput": m[10] == "true", "unchangedInputs": m[11] == "true",
            "parentAndStdoutClosed": m[12] == "true", "ownedGroupClosureClaimed": m[13] == "true"}
        if (not row["started"] or row["exit"] is None or row["stdoutBytes"] > 16384
                or not 0 <= row["elapsedMilliseconds"] < 32000 or not row["stableOutput"]
                or not row["unchangedInputs"] or not row["parentAndStdoutClosed"]
                or row["ownedGroupClosureClaimed"]
                or (row["outcome"] == "completed") != (row["exit"] == 0)
                or (row["freshPE"] and row["outputSHA256"] == "none")):
            raise ValueError("compiler_projection_consistency")
        profiles.append(row)
    if text.count("TrustedHostContext compilerProfile comparison=nativeSearchRole ") != len(profiles):
        raise ValueError("compiler_projection_closed_labels")
    closure_pattern = (r"TrustedHostContext compilerSearchClosed success=((?:true|false),(?:true|false),(?:true|false)) "
        r"freshPE=((?:true|false),(?:true|false),(?:true|false)) sameArguments=true unchangedInputs=true "
        r"searchRoleCurrent=(true|false) defaultIsolationRestored=(true|false) diagnosticOnly=true")
    closure = re.findall(closure_pattern, text)
    if text.count("TrustedHostContext compilerSearchClosed ") != len(closure):
        raise ValueError("compiler_projection_closed_labels")
    ordered = ([p["profile"] for p in profiles] == ["isolatedBefore", "explicitSystemSearch", "isolatedAfter"]
               and [p["index"] for p in profiles] == [0, 1, 2])
    complete = False
    if ordered and len(closure) == 1:
        success, fresh, current, restored = closure[0]
        if ([v == "true" for v in success.split(",")] != [p["outcome"] == "completed" for p in profiles]
                or [v == "true" for v in fresh.split(",")] != [p["freshPE"] for p in profiles]):
            raise ValueError("compiler_projection_consistency")
        complete = current == restored == "true"
    return {"profiles": profiles, "closure": [{"success": [v == "true" for v in a.split(",")],
        "freshPE": [v == "true" for v in b.split(",")], "searchRoleCurrent": c == "true",
        "defaultIsolationRestored": d == "true"} for a, b, c, d in closure],
        "completeObservation": complete, "shippingCompilerAcceptanceClaimed": False}


def crypto(executable, recipient, source, output):
    args = [str(executable), "cms", "-encrypt", "-binary", "-aes-256-gcm",
            "-in", str(source), "-out", str(output), "-outform", "DER",
            "-recip", str(recipient), "-keyopt", "rsa_padding_mode:oaep",
            "-keyopt", "rsa_oaep_md:sha256", "-keyopt", "rsa_mgf1_md:sha256"]
    try:
        if command(args).returncode:
            raise ValueError("encryption_failed")
        result = command([str(executable), "cms", "-cmsout", "-inform", "DER",
                          "-in", str(output), "-print"])
        if result.returncode:
            raise ValueError("encryption_algorithms")
        checked_algorithms(result.stdout)
    except Exception:
        output.unlink(missing_ok=True)
        raise


def checked_algorithms(data):
    if (data.count(b"contentType: id-smime-ct-authEnvelopedData") != 1
            or data.count(b"algorithm: aes-256-gcm") != 1
            or data.count(b"algorithm: rsaesOaep") != 1):
        raise ValueError("encryption_algorithms")
    block = re.search(rb"keyEncryptionAlgorithm:(.*?)encryptedKey:", data, re.S)
    if (not block or re.findall(rb"OBJECT\s+:([a-z0-9]+)", block[1]) !=
            [b"sha256", b"mgf1", b"sha256"]):
        raise ValueError("encryption_algorithms")


def archive(files, destination):
    total = 0
    manifest = {}
    with tarfile.open(destination, "w", format=tarfile.USTAR_FORMAT) as tar:
        for name, path in files:
            if (name not in [*PHASE_LOGS.values(), *EXPORTS] or name in manifest
                    or unsafe_path(path) or not path.is_file()):
                raise ValueError("owned_file_type")
            size = path.stat().st_size
            if size > MAX_FILE:
                raise ValueError("owned_export_budget")
            with path.open("rb") as stream:
                data = stream.read(MAX_FILE + 1)
            if len(data) != size:
                raise ValueError("owned_file_changed")
            total += size
            if size > MAX_FILE or total > MAX_TOTAL:
                raise ValueError("owned_export_budget")
            manifest[name] = {"bytes": size, "sha256": digest(data)}
            info = tarfile.TarInfo(name)
            info.size = size
            info.mode = 0o600
            with io.BytesIO(data) as stream:
                tar.addfile(info, stream)
    return manifest


def private_supervise(args, phase, deadline):
    # The reviewed supervisor drains raw child bytes to stdout as well as its
    # private log. Redirect that stream locally; only its fixed progress goes to
    # runner stderr. No raw test/build output enters Actions logs or artifacts.
    with (PRIVATE / "controller-output.log").open("a", encoding="utf-8") as output:
        with contextlib.redirect_stdout(output):
            return supervise(args, str(PRIVATE / phase), deadline, 10, True)


def main():
    SAFE.mkdir(exist_ok=False)
    PRIVATE.mkdir(exist_ok=False)
    if unsafe_path(SAFE) or unsafe_path(PRIVATE):
        raise ValueError("owned_directory_type")
    report = {"status": "STARTED", "diagnosticOnly": True, "full703GreenClaimed": False,
              "reviewedSource": SOURCE, "runtimeSourcesTree": SOURCES_TREE,
              "rawValuesArgumentsEnvironmentUploaded": False, "shipping702GreenClaimed": False,
              "shippingSource": SHIPPING, "diagnosticTestTreeDiffersFromShipping": True}
    exit_code = 125
    openssl = recipient = None
    try:
        if os.name != "nt" or sys.version_info[:2] != (3, 12):
            raise ValueError("native_toolchain")
        report["physicalHead"] = git("rev-parse", "HEAD").decode().strip()
        if (git("rev-parse", SOURCE + ":Sources").decode().strip() != SOURCES_TREE
                or command(["git", "diff", "--quiet", SOURCE, "--", *INPUTS]).returncode
                or git("ls-files", "--others", "--exclude-standard", "--", *INPUTS)
                or "_SWIFTPM_SKIP_TESTS_LIST" in os.environ):
            raise ValueError("source_inputs")
        if (git("rev-parse", SHIPPING + ":Sources").decode().strip() != SOURCES_TREE
                or git("diff", "--name-only", SHIPPING, SOURCE, "--", "Tests").decode().splitlines() != [DIAGNOSTIC_TEST]):
            raise ValueError("shipping_source_preservation")
        report["packagedInputsEqualReviewedSource"] = True
        report["productionSourcesEqualShipping"] = True
        report["allShippingTestBytesPreserved"] = True
        version = command(["swift", "--version"]).stdout.decode("utf-8", "strict")
        if not re.search(r"Swift version 6\.2\b", version):
            raise ValueError("swift_version")
        report["swiftVersion"] = version.strip()
        names = json.loads(git("show", "HEAD:.github/windows-compiler-search-one-name.json"))
        expected = checked_names(names, 1)
        blob = git("show", "HEAD:.github/windows-compiler-search-shipping702-baseline.json")
        if digest(blob) != BASELINE_SHA:
            raise ValueError("baseline_pin")
        baseline = checked_names(json.loads(blob)["names"], 702)
        cert = git("show", "HEAD:.github/windows-focused-recipient-public.pem")
        if digest(cert) != CERT_SHA:
            raise ValueError("recipient_pin")
        recipient = PRIVATE / "recipient-public.pem"
        recipient.write_bytes(cert)
        candidates = [Path(r"C:\Program Files\Git\usr\bin\openssl.exe"),
                      Path(r"C:\Program Files\OpenSSL-Win64\bin\openssl.exe")]
        openssl = next((p for p in candidates if p.is_file()), None)
        if not openssl:
            raise ValueError("openssl_unavailable")
        report["opensslSHA256"] = digest(openssl.read_bytes())
        control = PRIVATE / "encryption-control"
        control.write_bytes(os.urandom(32))
        crypto(openssl, recipient, control, PRIVATE / "control.cms")
        control.unlink()
        report["encryptionSelfControl"] = "AUTH_ENVELOPED_AES256GCM_RSA_OAEP_SHA256"
        build = private_supervise(["swift", "build", "--build-tests", "--force-resolved-versions"], "build", 1200)
        report["buildExit"] = build
        if build:
            raise ValueError("build_failed")
        binary = Path(".build/x86_64-unknown-windows-msvc/debug/rightclick-mcpPackageTests.xctest")
        if unsafe_path(binary) or not binary.is_file():
            raise ValueError("native_pe")
        with binary.open("rb") as stream:
            header = stream.read(64)
            if len(header) != 64 or header[:2] != b"MZ":
                raise ValueError("native_pe")
            stream.seek(struct.unpack_from("<I", header, 60)[0])
            if stream.read(6) != b"PE\x00\x00\x64\x86":
                raise ValueError("native_pe")
        report["nativeXCTestPE_SHA256"] = digest(binary.read_bytes())
        # The same discovery command in the real 78ea Windows job completed in
        # 94 seconds. Match its existing five-minute CI ceiling; the old
        # diagnostic's 60-second cut did not establish a runtime failure.
        discovery = private_supervise(["swift", "test", "list", "--skip-build"], "discovery", 300)
        if discovery:
            raise ValueError("discovery_failed")
        report["inventory"] = inventory((PRIVATE / "discovery-output.log").read_text(
            encoding="utf-8-sig"), expected, baseline)
        exit_code = private_supervise(["swift", "test", "--skip-build", "--force-resolved-versions",
                                       "--filter", FILTER], "focused", 600)
        report["focusedExit"] = exit_code
        text = (PRIVATE / "focused-output.log").read_text(encoding="utf-8-sig")
        report["execution"] = execution(text, expected)
        short = next(iter(expected)).split(".", 1)[1].replace("/", ".")
        interval = re.search(r"Test Case '" + re.escape(short) + r"' started[^\n]*\n(.*?)Test Case '" + re.escape(short) + r"' (?:passed|failed|skipped) \([0-9.]+ seconds\)", text, re.S)
        report["nativeCompilerSearchObservation"] = compiler_search_observation(interval[1] if interval else "")
        if digest(binary.read_bytes()) != report["nativeXCTestPE_SHA256"]:
            raise ValueError("native_pe_changed")
        if (exit_code == 0 and report["execution"]["passes"] == 1
                and report["execution"]["skips"] == 0
                and report["nativeCompilerSearchObservation"]["completeObservation"]
                and report["execution"]["swiftTestingZeroSuiteObserved"]):
            report["status"] = "PASS_SCOPED_NATIVE_COMPILER_SEARCH_OBSERVATION"
        else:
            report["status"] = "RED_SCOPED_NATIVE_COMPILER_SEARCH_OBSERVATION"
            exit_code = exit_code or 1
    except Exception as error:
        report["status"] = "FAILED"
        report["errorType"] = type(error).__name__
        # Our errors are closed labels; subprocess/OS exception messages stay private.
        if type(error) is ValueError and re.fullmatch(r"[a-z_]{1,64}", str(error)):
            report["errorLabel"] = str(error)
        exit_code = 125
    finally:
        try:
            files = []
            for phase, name in PHASE_LOGS.items():
                log = PRIVATE / (phase + "-output.log")
                if log.exists():
                    files.append((name, log))
            if files:
                if not openssl or not recipient:
                    raise ValueError("encryption_not_ready")
                plain = PRIVATE / "owned.tar"
                manifest = archive(files, plain)
                encrypted = SAFE / "owned-fixture-and-focused-log.cms"
                crypto(openssl, recipient, plain, encrypted)
                report["privateEvidence"] = {"recipientPublicCertificateSHA256": CERT_SHA,
                    "plaintextArchiveSHA256": digest(plain.read_bytes()),
                    "encryptedSHA256": digest(encrypted.read_bytes()),
                    "encryptedBytes": encrypted.stat().st_size, "whitelistFiles": manifest}
                plain.unlink()
            for phase in ["build", "discovery", "focused"]:
                path = PRIVATE / (phase + "-phase.json")
                if path.exists():
                    write(SAFE / (phase + "-phase.json"), json.loads(path.read_text()))
            write(SAFE / "summary.json", report)
        except Exception as error:
            # Never leave an unverified ciphertext among uploadable outputs.
            (SAFE / "owned-fixture-and-focused-log.cms").unlink(missing_ok=True)
            report["status"] = "PRIVATE_EVIDENCE_FAILED_CLOSED"
            report["evidenceErrorType"] = type(error).__name__
            write(SAFE / "summary.json", report)
            exit_code = 125
        finally:
            (PRIVATE / "owned.tar").unlink(missing_ok=True)
            (PRIVATE / "encryption-control").unlink(missing_ok=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
