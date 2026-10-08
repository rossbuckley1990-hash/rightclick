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

SOURCE = "f73633a32364c1626f0c47794b6758a8e99b9c63"
SOURCES_TREE = "9716cb182db859368f47b603137189d3b257ca43"
CERT_SHA = "1f10ec5ff26b0ef1fbb91248ac954cf15757e8782101f90abe05a171af58bf9d"
BASELINE_SHA = "f576ed56efeeb2f1fe2b4a03384a8f9d11162faf3d0dae1eee80aae7a439e04a"
INPUTS = ["Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests",
          "Vendor", "fixtures", "packaging", "scripts"]
FILTER = r"^RightClickCoreTests\.(?:InvocationBindingTests|CapabilityExecutableSnapshotPoolTests|RCIRReceiptTrustGapTests|TrustedHostProcessContextTests)/"
EXPORTS = ["runtime-records.json", "requested-policy-matrix.json", "trust-results.json",
           "key-0-public.raw", "key-1-public.raw", "requests.jsonl", "effects.jsonl",
           "observations.jsonl", "polls.jsonl"]
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
    current = checked_names(names, 693)
    if not expected.issubset(current) or not baseline.issubset(current):
        raise ValueError("inventory_preservation")
    return {"all693NamesUnique": True, "all686BaselineNamesPreserved": True,
            "selectedNames": sorted(expected)}


def execution(text, expected):
    # XCTest omits the target prefix; exact discovery maps each class uniquely.
    short = {x.split(".", 1)[1].replace("/", "."): x for x in expected}
    if len(short) != 17:
        raise ValueError("selected_names")
    starts = re.findall(r"Test Case '([^']+)' started", text)
    finishes = re.findall(r"Test Case '([^']+)' (passed|failed|skipped) \(([0-9.]+) seconds\)", text)
    if (len(starts) != 17 or set(starts) != set(short)
            or len(finishes) != 17 or {x[0] for x in finishes} != set(short)):
        raise ValueError("selected_completion")
    results = [{"test": short[n], "state": state, "seconds": float(seconds)}
               for n, state, seconds in finishes]
    return {"starts": 17, "finishes": 17, "results": results,
            "passes": sum(x["state"] == "passed" for x in results),
            "failures": sum(x["state"] == "failed" for x in results),
            "skips": sum(x["state"] == "skipped" for x in results),
            "swiftTestingZeroSuiteObserved": bool(re.search(
                r"Test run with 0 tests in 0 suites passed", text))}


def stages(text):
    # Reconstruct only fully matched closed labels/scalars; never copy a line.
    kinds = ("invalidContract invalidIdentity invalidLimit invalidTime unavailable staleBinding "
             "unknownEffects unsupportedTaskShape authorityDenied policyDenied leaseExpired leaseUsed "
             "leaseMismatch invalidTransition invalidSequence bufferFull unverified observerMismatch "
             "invalidWire invalidLimits limitExceeded nonfiniteNumber invalidSchema schemaMismatch "
             "unknownSchema nonStringLegacyArgument other").split()
    token = "(?:" + "|".join(sorted(set(kinds))) + r"|cocoa_[0-9]{1,10})"
    outcomes = ("invalidConfiguration|admissionOrLaunchFailure|deadlineExceeded|outputLimitExceeded|"
                "outputDrainFailure|childFailed|completed|none")
    bootstrap_stage = ("installationQuery|installationValidation|interpreterSelection|"
                       "ownedInputPreparation|nativeCompilation|outputValidation")
    kafka_stage = ("credentialAcquisition|clientSnapshotAcquisition|metadataAcquisition|"
                   "referenceRevalidation|declarationRevalidation|metadataProcess|produceProcess|"
                   "observerProcess|controlMetadataProcess|none")
    number = r"(?:-?[0-9]{1,10}|none)"
    boolean = r"(?:true|false|none)"
    bootstrap = (r"NativePythonClient stage=(" + bootstrap_stage + r") kind=(" + token
                 + r") processOutcome=(" + outcomes + r") started=(" + boolean
                 + r") exit=(" + number + r") stdoutBytes=(" + number
                 + r") validation=\[(?:none|empty=(true|false) isAbsolute=(true|false)"
                 r" containsQuote=(true|false) containsEmbeddedLF=(true|false)"
                 r" startsUTF8BOM=(true|false))\]")
    result = {"bootstrap": [], "invocation": [], "trust": []}
    for m in re.finditer(bootstrap, text):
        result["bootstrap"].append(dict(zip(
            ["stage", "kind", "processOutcome", "started", "exit", "stdoutBytes",
             "empty", "isAbsolute", "containsQuote", "containsEmbeddedLF", "startsUTF8BOM"], m.groups())))
    invocation = (r"InvocationBindingFixture stage=(fixtureProvisioning|resolverAcquisition|contextualDiscovery|invocation)"
                  r" substrate=(kafka|kubernetes) kind=(" + token + r") kafkaStage=(" + kafka_stage
                  + r") processOutcome=(" + outcomes + r") started=(" + boolean + r") exit=(" + number + r")(?= bootstrap=\[)")
    for m in re.finditer(invocation, text):
        result["invocation"].append(dict(zip(
            ["stage", "substrate", "kind", "kafkaStage", "processOutcome", "started", "exit"], m.groups())))
    for m in re.finditer(r"ReceiptTrustFixture boundary=(directoryProvisioning|agents|providerConfiguration|firstSigner|firstEffect|firstSignature|rotatedSigner|rotatedEffect|rotatedSignature) cocoa=(" + number + r")(?![A-Za-z0-9_-])", text):
        result["trust"].append({"boundary": m[1], "cocoa": m[2]})
    return result


def bound_stages(text, expected):
    short = {x.split(".", 1)[1].replace("/", "."): x for x in expected}
    pattern = r"Test Case '([^']+)' started[^\n]*\n(.*?)Test Case '\1' (?:passed|failed|skipped) \([0-9.]+ seconds\)"
    return [{"test": short[m[1]], "stages": stages(m[2])}
            for m in re.finditer(pattern, text, re.S) if m[1] in short]


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
    report = {"status": "STARTED", "diagnosticOnly": True, "full693GreenClaimed": False,
              "reviewedSource": SOURCE, "runtimeSourcesTree": SOURCES_TREE,
              "rawValuesArgumentsEnvironmentUploaded": False}
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
        report["packagedInputsEqualReviewedSource"] = True
        version = command(["swift", "--version"]).stdout.decode("utf-8", "strict")
        if not re.search(r"Swift version 6\.2\b", version):
            raise ValueError("swift_version")
        report["swiftVersion"] = version.strip()
        names = json.loads(git("show", "HEAD:.github/windows-current-context-focused-17-names.json"))
        expected = checked_names(names, 17)
        blob = git("show", "HEAD:.github/windows-current-native-baseline-tests.json")
        if digest(blob) != BASELINE_SHA:
            raise ValueError("baseline_pin")
        baseline = checked_names(json.loads(blob)["names"], 686)
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
        export = PRIVATE / "trust-export"
        export.mkdir(exist_ok=False)
        os.environ["RCIR_TRUST_EVIDENCE"] = str(export.resolve())
        exit_code = private_supervise(["swift", "test", "--skip-build", "--force-resolved-versions",
                                       "--filter", FILTER], "focused", 600)
        report["focusedExit"] = exit_code
        text = (PRIVATE / "focused-output.log").read_text(encoding="utf-8-sig")
        report["safeStagesByObservedTestInterval"] = bound_stages(text, expected)
        report["execution"] = execution(text, expected)
        if digest(binary.read_bytes()) != report["nativeXCTestPE_SHA256"]:
            raise ValueError("native_pe_changed")
        if (exit_code == 0 and report["execution"]["passes"] == 17
                and report["execution"]["skips"] == 0
                and report["execution"]["swiftTestingZeroSuiteObserved"]):
            report["status"] = "PASS_SCOPED_FOCUSED_17"
        else:
            report["status"] = "RED_SCOPED_FOCUSED_17"
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
            export = PRIVATE / "trust-export"
            if export.exists():
                if unsafe_path(export) or not export.is_dir():
                    raise ValueError("owned_file_type")
                unknown = {p.name for p in export.iterdir()} - set(EXPORTS)
                if unknown:
                    raise ValueError("unlisted_fixture_export")
                files.extend((name, export / name) for name in EXPORTS if (export / name).exists())
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
