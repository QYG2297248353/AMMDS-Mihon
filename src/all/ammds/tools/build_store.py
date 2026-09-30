"""Package the built AMMDS Mihon extension into a Mihon extension repository.

Produces, in the output directory:

* ``ammds-keiyoushi-extensions.apk``  - the signed extension APK users install
* ``ammds-keiyoushi-extensions.jar``  - the same extension as a JAR (desktop/other loaders)
* ``ammds-icon.png``                  - the icon the repository index points at
* ``ammds-store.pb``                  - the Mihon repository index (gzipped protobuf)
* ``ammds-store.json``                - the same index in readable JSON, for inspection

The index format mirrors keiyoushi/extensions-source exactly (see
``.github/scripts/index.proto``): gzipped deterministic protobuf, with ``apkUrl`` / ``iconUrl``
/ ``jarUrl`` pointing at wherever the artifacts are hosted.

Usage (from the checkout root, after ``:src:all:ammds:assembleRelease``):

    python src/all/ammds/tools/build_store.py

Default hosting is the GitHub release named after the extension version. To commit the
artifacts into the repository instead and serve them from raw.githubusercontent.com:

    python src/all/ammds/tools/build_store.py --out-dir dist \\
        --release-base-url https://raw.githubusercontent.com/<owner>/<repo>/main/dist
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

def find_extension_root() -> Path:
    """Locate the Keiyoushi-style checkout that contains this extension.

    The same script is used from two places: the AMMDS repository, where the checkout lives
    under ``Mihon/``, and the standalone ``AMMDS-Mihon`` repository, where the extension sits
    at the checkout root. Walking up to the nearest ``settings.gradle.kts`` handles both.
    """
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "settings.gradle.kts").is_file():
            return candidate
    raise SystemExit(f"no settings.gradle.kts above {__file__}: not a Keiyoushi-style checkout")


REPO = find_extension_root()
EXT_DIR = REPO / "src" / "all" / "ammds"
INDEX_PB2_DIR = REPO / ".github" / "scripts"

# The repository index is published next to the artifacts it describes.
DEFAULT_TAG_PREFIX = "mihon-ext-"
DEFAULT_DIST_NAME = "ammds-keiyoushi-extensions"
DEFAULT_STORE_NAME = "ammds-store.pb"
DEFAULT_OUT_DIR = REPO / "dist" / "mihon"

sys.path.insert(0, str(INDEX_PB2_DIR))
import index_pb2  # noqa: E402
from google.protobuf import json_format  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-info", type=Path, help="keiyoushi-source-info.json emitted by assembleRelease")
    parser.add_argument("--apk", type=Path, help="release APK")
    parser.add_argument("--jar", type=Path, help="release JAR")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--tag", help="GitHub release tag hosting the artifacts")
    parser.add_argument("--release-base-url", help="full URL prefix of the release assets directory")
    parser.add_argument("--icon-url", help="absolute URL of the extension icon")
    parser.add_argument("--signing-key", help="SHA-256 of the APK signing certificate (auto-detected by default)")
    parser.add_argument("--repo-url", help="GitHub repository URL (defaults to the origin remote)")
    return parser.parse_args()


def find_build_artifact(build_dir: Path, pattern: str) -> Path:
    matches = sorted(build_dir.glob(pattern))
    if not matches:
        raise SystemExit(f"no file matching {pattern!r} under {build_dir}; run :src:all:ammds:assembleRelease first")
    if len(matches) > 1:
        raise SystemExit(f"ambiguous build output for {pattern!r}: {matches}")
    return matches[0]


def git_remote_url() -> str:
    """Best-effort origin URL; empty when there is no origin (e.g. before the first push)."""
    result = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    raw = result.stdout.strip()
    if not raw:
        return ""
    ssh = re.fullmatch(r"git@([^:]+):(.+?)(?:\.git)?", raw)
    if ssh:
        return f"https://{ssh.group(1)}/{ssh.group(2)}"
    return re.sub(r"\.git$", "", raw)


def android_sdk_dirs() -> list[Path]:
    """Candidate Android SDK locations, most explicit first."""
    import os

    candidates: list[Path] = []
    for env_var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(env_var)
        if value:
            candidates.append(Path(value))
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        candidates.append(Path(local_app_data) / "Android" / "Sdk")
    candidates.append(Path.home() / "Android" / "Sdk")
    return [candidate for candidate in candidates if candidate.is_dir()]


def find_apksigner() -> str | None:
    """Locate apksigner in the Android SDK build-tools (highest version wins)."""
    name = "apksigner.bat" if sys.platform == "win32" else "apksigner"
    for sdk in android_sdk_dirs():
        build_tools = sdk / "build-tools"
        if not build_tools.is_dir():
            continue
        for entry in sorted((e for e in build_tools.iterdir() if e.is_dir()), reverse=True):
            candidate = entry / name
            if candidate.exists():
                return str(candidate)
    return None


def find_keytool() -> str | None:
    """Locate keytool on PATH, then in JAVA_HOME, then in the running interpreter's JDK."""
    found = shutil.which("keytool")
    if found:
        return found
    import os

    name = "keytool.exe" if sys.platform == "win32" else "keytool"
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        candidate = Path(java_home) / "bin" / name
        if candidate.exists():
            return str(candidate)
    candidate = Path(sys.base_prefix) / "bin" / name
    return str(candidate) if candidate.exists() else None


def signing_key_fingerprint(apk: Path) -> str:
    """SHA-256 of the APK signing certificate, as Mihon expects in the repository index.

    apksigner is preferred over keytool: release APKs are v2/v3-signed and carry no v1 (JAR)
    signature, which is all ``keytool -printcert -jarfile`` can read.
    """
    apksigner = find_apksigner()
    if apksigner is not None:
        result = subprocess.run(
            [apksigner, "verify", "--print-certs", str(apk)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            match = re.search(r"SHA-256 digest:\s*([0-9A-Fa-f:]+)", result.stdout)
            if match:
                return match.group(1).replace(":", "").lower()
            print("warning: could not parse apksigner output; falling back to keytool")
        else:
            print(f"warning: apksigner failed: {result.stderr.strip() or result.stdout.strip()}")

    keytool = find_keytool()
    if keytool is None:
        print("warning: no apksigner or keytool found; leaving signingKey empty (Mihon will skip the signer check)")
        return ""

    result = subprocess.run(
        [keytool, "-printcert", "-jarfile", str(apk)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"warning: keytool failed; leaving signingKey empty\n{result.stderr.strip()}")
        return ""
    match = re.search(r"SHA-?256:?\s*([0-9A-Fa-f:]+)", result.stdout)
    if not match:
        print("warning: could not parse the certificate fingerprint; leaving signingKey empty")
        return ""
    return match.group(1).replace(":", "").lower()


def main() -> None:
    args = parse_args()
    build_dir = EXT_DIR / "build"
    source_info_path = args.source_info or build_dir / "keiyoushi-source-info.json"
    if not source_info_path.is_file():
        raise SystemExit(f"missing {source_info_path}; run :src:all:ammds:assembleRelease first")

    info = json.loads(source_info_path.read_text(encoding="utf-8"))
    apk = args.apk or find_build_artifact(build_dir, "outputs/apk/release/*.apk")
    jar = args.jar or find_build_artifact(build_dir, "outputs/jar/release/*.jar")

    tag = args.tag or f"{DEFAULT_TAG_PREFIX}{info['versionName']}"
    repo_url = args.repo_url or git_remote_url()
    release_base = args.release_base_url or (f"{repo_url}/releases/download/{tag}" if repo_url else "")
    if not release_base:
        raise SystemExit(
            "cannot tell where the artifacts will be hosted: pass --release-base-url, "
            "or add an 'origin' remote so it can be derived"
        )
    # The icon ships next to the APK, so it resolves under either hosting mode.
    icon_url = args.icon_url or f"{release_base}/ammds-icon.png"

    out_dir = args.out_dir if args.out_dir.is_absolute() else REPO / args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    dist_apk = out_dir / f"{DEFAULT_DIST_NAME}.apk"
    dist_jar = out_dir / f"{DEFAULT_DIST_NAME}.jar"
    dist_icon = out_dir / "ammds-icon.png"
    shutil.copyfile(apk, dist_apk)
    shutil.copyfile(jar, dist_jar)
    shutil.copyfile(EXT_DIR / "res" / "mipmap-xhdpi" / "ic_launcher.png", dist_icon)

    extension = index_pb2.Extension(
        name=info["name"],
        packageName=info["packageName"],
        resources=index_pb2.Resources(
            apkUrl=f"{release_base}/{dist_apk.name}",
            iconUrl=icon_url,
            jarUrl=f"{release_base}/{dist_jar.name}",
        ),
        extensionLib=info["extensionLib"],
        versionCode=info["versionCode"],
        versionName=info["versionName"],
        contentWarning=info["contentWarning"],
        sources=[
            index_pb2.Source(
                id=int(source["id"]),
                name=source["name"],
                language=source["lang"],
                homeUrl=source["baseUrl"],
                mirrorUrls=source.get("mirrorUrls", []),
            )
            for source in info["sources"]
        ],
    )

    if args.signing_key is None:
        # A missing signature is a silent downgrade: Mihon skips the signer check entirely,
        # so a tampered APK would install. Fail loudly instead, with an explicit escape hatch.
        signing_key = signing_key_fingerprint(dist_apk)
        if not signing_key:
            raise SystemExit(
                "could not read the APK signing certificate. Set ANDROID_HOME (apksigner) or "
                "JAVA_HOME (keytool), or pass --signing-key <sha256>, or --signing-key \"\" to "
                "publish without a signer check on purpose."
            )
    else:
        signing_key = args.signing_key

    index = index_pb2.Index(
        name="AMMDS",
        badgeLabel="AMMDS",
        signingKey=signing_key,
        contact=index_pb2.Contact(website=repo_url),
        extensionList=index_pb2.ExtensionList(extensions=[extension]),
    )

    store = out_dir / DEFAULT_STORE_NAME
    store.write_bytes(gzip.compress(index.SerializeToString(deterministic=True), mtime=0))
    (out_dir / "ammds-store.json").write_text(
        json_format.MessageToJson(
            index,
            always_print_fields_with_no_presence=False,
            preserving_proto_field_name=True,
        ),
        encoding="utf-8",
    )

    print(f"\nindex: {store}")
    print(json.dumps(json.loads((out_dir / 'ammds-store.json').read_text(encoding='utf-8')), indent=2, ensure_ascii=False))
    print(f"\nadd this repository in Mihon:\n  {release_base}/{DEFAULT_STORE_NAME}\n")
    if "/releases/download/" in release_base:
        print(f"publish: upload every file below as an asset of GitHub release '{tag}'\n")
    else:
        print(
            "publish: commit the files below and push; they are fetched from the URL above.\n"
            "         (CDN caching can delay a new version by a few minutes.)\n"
        )
    for produced in sorted(out_dir.iterdir()):
        print(f"  {produced.name}  ({produced.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
