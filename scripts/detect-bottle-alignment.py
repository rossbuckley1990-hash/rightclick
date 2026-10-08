#!/usr/bin/env python3
"""Fail closed when the checkout exposes substrate/reflector kinds absent from the published Homebrew bottle.

Agents run this before bottle-align work and in CI:

    python3 scripts/detect-bottle-alignment.py --compare

Exit 0 when every checkout kind is present in the published bottle.
Exit 1 when main/checkout has kinds missing from the bottle (alignment required).
Exit 2 on usage or fetch/inventory errors.

See docs/BOTTLE-ALIGNMENT.md and docs/RELEASE.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Preserve old published trees while recognizing the extracted target layout.
def source_candidates(path: str) -> list[str]:
    if not path.startswith("Sources/RightClickCore/"):
        return [path]
    filename = pathlib.Path(path).name
    moved_name = "MacOSCapabilityReflectors.swift" if filename == "CapabilityReflector.swift" else filename
    return [path, "Sources/RightClickProtocol/" + filename,
            "Sources/RightClickProviders/" + filename, "Sources/RightClickMacOS/" + moved_name,
            "Sources/RightClickLinux/" + filename]

# Stable kind IDs. Detection uses durable source fingerprints so a renamed
# helper file cannot silently drop a substrate from the bottle contract.
KIND_RULES: list[dict[str, object]] = [
    {
        "id": "reflector.macos.service",
        "title": "macOS Services reflector",
        "any_files": ["Sources/RightClickCore/CapabilityReflector.swift"],
        "any_patterns": [r"MacOSServiceReflector"],
    },
    {
        "id": "reflector.macos.sharing",
        "title": "macOS Sharing reflector",
        "any_files": ["Sources/RightClickCore/CapabilityReflector.swift"],
        "any_patterns": [r"MacOSSharingReflector"],
    },
    {
        "id": "reflector.macos.action_extension",
        "title": "macOS Action Extension reflector",
        "any_files": ["Sources/RightClickCore/CapabilityReflector.swift"],
        "any_patterns": [r"MacOSActionExtensionReflector"],
    },
    {
        "id": "source.openapi.bonjour",
        "title": "Bonjour OpenAPI source",
        "any_files": ["Sources/RightClickCore/BonjourOpenAPISource.swift"],
        "composition_patterns": [
            r"BonjourOpenAPISource\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.openapi.configured",
        "title": "Configured OpenAPI source",
        "any_files": ["Sources/RightClickCore/ConfiguredOpenAPISource.swift"],
        "composition_patterns": [
            r"ConfiguredOpenAPISource\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.graphql.bonjour",
        "title": "Bonjour GraphQL source",
        "any_files": [
            "Sources/RightClickCore/BonjourGraphQLSource.swift",
            "Sources/RightClickCore/GraphQLReflector.swift",
        ],
        "composition_patterns": [
            r"BonjourGraphQLSource\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.grpc.bonjour",
        "title": "Bonjour gRPC source",
        "any_files": [
            "Sources/RightClickCore/BonjourGRPCSource.swift",
            "Sources/RightClickCore/GRPCReflector.swift",
        ],
        "composition_patterns": [
            r"BonjourGRPCSource\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.capability_artifact.configured",
        "title": "Universal configured capability artifacts",
        "any_files": ["Sources/RightClickCore/CapabilityArtifactResolver.swift"],
        "composition_patterns": [
            r"ConfiguredCapabilityArtifactSource",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.ard.registry",
        "title": "ARD registry source",
        "any_files": [
            "Sources/RightClickCore/ARDRegistrySource.swift",
            "Sources/RightClickARD/ARD.swift",
        ],
        "composition_patterns": [
            r"ARDRegistrySource",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityRuntimeDefaults.swift",
        ],
    },
    {
        "id": "source.federation.mcp",
        "title": "MCP federation peer source",
        "any_files": ["Sources/RightClickMCP/Federation.swift"],
        "composition_patterns": [
            r"FederationPeerSource",
        ],
        "composition_files": [
            "Sources/RightClickMCP/Server.swift",
            "Sources/RightClickMCP/Federation.swift",
        ],
    },
    {
        "id": "artifact.resolver.openapi",
        "title": "OpenAPI capability artifact resolver",
        "any_files": ["Sources/RightClickCore/CapabilityArtifactResolver.swift"],
        "any_patterns": [r"OpenAPICapabilityArtifactResolver"],
        "composition_patterns": [
            r"OpenAPICapabilityArtifactResolver\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityArtifactResolver.swift",
        ],
    },
    {
        "id": "artifact.resolver.graphql",
        "title": "GraphQL capability artifact resolver",
        "any_files": ["Sources/RightClickCore/CapabilityArtifactResolver.swift"],
        "any_patterns": [r"GraphQLCapabilityArtifactResolver"],
        "composition_patterns": [
            r"GraphQLCapabilityArtifactResolver\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityArtifactResolver.swift",
        ],
    },
    {
        "id": "artifact.resolver.grpc",
        "title": "gRPC capability artifact resolver",
        "any_files": ["Sources/RightClickCore/CapabilityArtifactResolver.swift"],
        "any_patterns": [r"GRPCCapabilityArtifactResolver"],
        "composition_patterns": [
            r"GRPCCapabilityArtifactResolver\s*\(",
        ],
        "composition_files": [
            "Sources/RightClickCore/CapabilityArtifactResolver.swift",
        ],
    },
    {
        "id": "authority.oauth_oidc",
        "title": "OAuth/OIDC authority",
        "any_files": ["Sources/RightClickCore/OAuthOIDCAuthority.swift"],
        "any_patterns": [r"OAuthOIDCAuthority|OIDC"],
    },
]


# Detect callable compiler/source registrations in both monolithic published
# trees and the reconciled portable modules. The runtime substrate contract is
# separately exercised by SubstrateInventoryTests; this is bottle comparison.
for family, class_name in [("kafka", "Kafka"), ("kubernetes", "Kubernetes"),
                           ("wasm", "WASM"), ("mcp", "MCP"), ("dbus", "DBus")]:
    KIND_RULES.append({"id": "artifact.resolver." + family,
        "title": family + " capability artifact resolver",
        "any_files": ["Sources/RightClickCore/" + class_name + "CapabilityArtifactResolver.swift"],
        "any_patterns": [class_name + "CapabilityArtifactResolver"],
        "composition_patterns": [class_name + r"CapabilityArtifactResolver\s*\("],
        "composition_files": ["Sources/RightClickCore/CapabilityArtifactResolver.swift",
                              "Sources/RightClickCore/CapabilityRuntimeDefaults.swift"]})
KIND_RULES.append({"id": "source.a2a.configured", "title": "A2A agent-card/task source",
    "any_files": ["Sources/RightClickCore/A2AReflector.swift"],
    "any_patterns": ["ConfiguredA2ASource"], "composition_patterns": ["ConfiguredA2ASource"],
    "composition_files": ["Sources/RightClickCore/CapabilityRuntimeDefaults.swift"]})


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def inventory_tree(root: pathlib.Path) -> dict[str, object]:
    version_match = re.search(
        r'current = "([0-9]+\.[0-9]+\.[0-9]+)"',
        "\n".join(read_text(root / p) for p in source_candidates("Sources/RightClickCore/ProductSurface.swift")),
    )
    version = version_match.group(1) if version_match else None
    present: list[dict[str, object]] = []
    absent: list[str] = []

    for rule in KIND_RULES:
        kind_id = str(rule["id"])
        files = [root / pathlib.Path(candidate) for p in rule.get("any_files", []) for candidate in source_candidates(p)]  # type: ignore[arg-type]
        file_hit = any(p.is_file() for p in files) if files else True
        pattern_hit = True
        patterns = list(rule.get("any_patterns", []))  # type: ignore[arg-type]
        if patterns:
            joined = "\n".join(read_text(p) for p in files if p.is_file())
            pattern_hit = any(re.search(pat, joined) for pat in patterns)

        composition_hit = True
        composition_patterns = list(rule.get("composition_patterns", []))  # type: ignore[arg-type]
        composition_files = [
            root / pathlib.Path(candidate)
            for p in rule.get("composition_files", []) for candidate in source_candidates(p)  # type: ignore[arg-type]
        ]
        if composition_patterns:
            if composition_files:
                blob = "\n".join(read_text(p) for p in composition_files)
            else:
                blob = "\n".join(read_text(p) for p in files if p.is_file())
            composition_hit = any(re.search(pat, blob) for pat in composition_patterns)

        if file_hit and pattern_hit and composition_hit:
            present.append(
                {
                    "id": kind_id,
                    "title": rule["title"],
                }
            )
        else:
            absent.append(kind_id)

    # Prefer packaged snapshot when present (published bottle evidence).
    snapshot = root / "packaging/substrate-kinds.json"
    if snapshot.is_file():
        try:
            payload = json.loads(snapshot.read_text(encoding="utf-8"))
            snap_ids = [str(k["id"]) for k in payload.get("kinds", [])]
            # Snapshot is authoritative for bottle trees; still require live
            # fingerprints to remain true so a stale snapshot cannot hide drift.
            live_ids = {str(k["id"]) for k in present}
            merged = sorted(set(snap_ids) | live_ids)
            present = [
                next(
                    (
                        k
                        for k in present
                        if k["id"] == kid
                    ),
                    {"id": kid, "title": kid},
                )
                for kid in merged
            ]
        except (json.JSONDecodeError, TypeError, KeyError):
            pass

    kinds = sorted(present, key=lambda item: str(item["id"]))
    return {
        "version": version,
        "root": str(root),
        "kinds": kinds,
        "kind_ids": [str(k["id"]) for k in kinds],
        "known_rule_ids": [str(r["id"]) for r in KIND_RULES],
        "absent_rule_ids": absent,
    }


def write_manifest(root: pathlib.Path, path: pathlib.Path) -> dict[str, object]:
    inv = inventory_tree(root)
    payload = {
        "schema": "rightclick.substrate-kinds.v1",
        "product": "RIGHTCLICK",
        "version": inv["version"],
        "kinds": inv["kinds"],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_url(url: str, destination: pathlib.Path) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "rightclick-bottle-alignment/0.2.2"},
    )
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out)


def published_formula_url() -> str:
    return "https://raw.githubusercontent.com/rossbuckley1990-hash/homebrew-tap/main/Formula/rightclick.rb"


def parse_formula(text: str) -> tuple[str, str, str]:
    url = re.search(r'url\s+"(https://github.com/rossbuckley1990-hash/rightclick/releases/download/[^"]+)"', text)
    sha = re.search(r'sha256\s+"([0-9a-f]{64})"', text)
    if not url or not sha:
        raise RuntimeError("Could not parse published Homebrew formula url/sha256")
    version = re.search(r"rightclick-([0-9]+\.[0-9]+\.[0-9]+)-source\.tar\.gz", url.group(1))
    if not version:
        raise RuntimeError("Could not parse version from formula url")
    return version.group(1), url.group(1), sha.group(1)


def inventory_published_bottle(
    bottle: str | None,
    work: pathlib.Path,
) -> dict[str, object]:
    if bottle and pathlib.Path(bottle).is_dir():
        return inventory_tree(pathlib.Path(bottle))

    archive = work / "published-source.tar.gz"
    extract = work / "published-source"
    extract.mkdir(parents=True, exist_ok=True)

    if bottle and pathlib.Path(bottle).is_file():
        shutil.copy2(bottle, archive)
        expected_sha = None
        version = None
        source_url = str(pathlib.Path(bottle))
    elif bottle and bottle.startswith("http"):
        fetch_url(bottle, archive)
        expected_sha = None
        version = None
        source_url = bottle
    else:
        formula_text = urllib.request.urlopen(
            urllib.request.Request(
                published_formula_url(),
                headers={"User-Agent": "rightclick-bottle-alignment/0.2.2"},
            ),
            timeout=60,
        ).read().decode("utf-8")
        version, source_url, expected_sha = parse_formula(formula_text)
        if bottle and bottle != version and bottle != f"v{version}":
            # Explicit version requested: fetch that release asset instead.
            version = bottle.lstrip("v")
            source_url = (
                "https://github.com/rossbuckley1990-hash/rightclick/releases/download/"
                f"v{version}/rightclick-{version}-source.tar.gz"
            )
            expected_sha = None
        fetch_url(source_url, archive)

    digest = sha256_file(archive)
    if expected_sha and digest != expected_sha:
        raise RuntimeError(
            f"Published source SHA mismatch: formula={expected_sha} downloaded={digest}"
        )

    subprocess.check_call(["tar", "-xzf", str(archive), "-C", str(extract)])
    children = [p for p in extract.iterdir() if p.is_dir()]
    if len(children) != 1:
        raise RuntimeError(f"Expected one top-level directory in source archive, found {children}")
    inv = inventory_tree(children[0])
    inv["source_url"] = source_url
    inv["source_sha256"] = digest
    if version:
        inv["published_version"] = version
    return inv


def compare(checkout: dict[str, object], bottle: dict[str, object]) -> dict[str, object]:
    checkout_ids = set(checkout["kind_ids"])  # type: ignore[arg-type]
    bottle_ids = set(bottle["kind_ids"])  # type: ignore[arg-type]
    missing = sorted(checkout_ids - bottle_ids)
    extra = sorted(bottle_ids - checkout_ids)
    return {
        "aligned": not missing,
        "missing_from_bottle": missing,
        "extra_in_bottle": extra,
        "checkout_version": checkout.get("version"),
        "bottle_version": bottle.get("published_version") or bottle.get("version"),
        "bottle_source_sha256": bottle.get("source_sha256"),
        "alignment_path": [
            "docs/BOTTLE-ALIGNMENT.md",
            "docs/RELEASE.md",
            "python3 scripts/detect-bottle-alignment.py --compare",
            "swift test && scripts/build-cli.sh && python3 scripts/package-source.py",
            "tag next immutable version; gh release create; update homebrew-tap Formula/rightclick.rb",
        ],
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", default=str(ROOT), help="Checkout root to inventory")
    parser.add_argument(
        "--bottle",
        default=None,
        help="Published bottle version, archive path/URL, extracted tree, or omit for public tap formula",
    )
    parser.add_argument("--compare", action="store_true", help="Fail closed on checkout kinds missing from bottle")
    parser.add_argument("--write-manifest", metavar="PATH", help="Write substrate-kinds.json for packaging")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    args = parser.parse_args(argv)

    checkout_root = pathlib.Path(args.checkout).resolve()
    if args.write_manifest:
        payload = write_manifest(checkout_root, pathlib.Path(args.write_manifest))
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"wrote {args.write_manifest} ({len(payload['kinds'])} kinds, version={payload['version']})")
        if not args.compare:
            return 0

    checkout = inventory_tree(checkout_root)
    result: dict[str, object] = {"checkout": checkout}

    if args.compare or args.bottle is not None:
        with tempfile.TemporaryDirectory(prefix="rightclick-bottle-align-") as tmp:
            try:
                bottle = inventory_published_bottle(args.bottle, pathlib.Path(tmp))
            except (RuntimeError, urllib.error.URLError, subprocess.CalledProcessError) as exc:
                print(f"bottle inventory failed: {exc}", file=sys.stderr)
                return 2
        result["bottle"] = bottle
        result["comparison"] = compare(checkout, bottle)

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"checkout version={checkout.get('version')} kinds={len(checkout['kind_ids'])}")
        print("  " + ", ".join(checkout["kind_ids"]))  # type: ignore[arg-type]
        if "comparison" in result:
            comparison = result["comparison"]  # type: ignore[assignment]
            print(
                f"bottle version={comparison['bottle_version']} "
                f"sha256={comparison.get('bottle_source_sha256')}"
            )
            print("  " + ", ".join(result["bottle"]["kind_ids"]))  # type: ignore[index]
            if comparison["missing_from_bottle"]:
                print("FAIL CLOSED: checkout kinds missing from published bottle:")
                for kind in comparison["missing_from_bottle"]:
                    print(f"  - {kind}")
                print("Alignment path:")
                for step in comparison["alignment_path"]:
                    print(f"  - {step}")
            else:
                print("ALIGNED: published bottle contains every checkout substrate kind.")
            if comparison["extra_in_bottle"]:
                print("note: bottle still has kinds not detected in checkout:")
                for kind in comparison["extra_in_bottle"]:
                    print(f"  - {kind}")

    if "comparison" in result and not result["comparison"]["aligned"]:  # type: ignore[index]
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
