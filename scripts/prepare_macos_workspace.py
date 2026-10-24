#!/usr/bin/env python3
"""Prepare and use a disposable Catalyst workspace without editing source projects.

Source files use APFS copy-on-write clones where available, with ordinary copies
as a fallback. Internal links are redirected into the copy; external link targets
are copied. Original sources and project metadata are never build outputs.
No Ruby gems or third-party Python packages are required.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile


EXCLUDED = {
    ".git", ".build", ".swiftpm", ".DS_Store", "node_modules", "xcuserdata",
    "DerivedData", "buildlog", "artifacts", "handover", "__pycache__",
}
CATALYST_PRODUCTS = {
    "com.apple.product-type.framework",
    "com.apple.product-type.bundle",  # LibreTransmitter/ShareClient plug-ins.
    "com.apple.product-type.library.static",
    "com.apple.product-type.library.dynamic",
}
NATIVE_TARGETS = {"TrioMacWidgets", "TrioMenuBar"}
MAC_DEPLOYMENT = "14.6"
CATALYST_IOS_DEPLOYMENT = "17.6"
APP_TARGET = "TrioMac"
SCHEME = "Trio Mac"
LIBRE_SCRIPT_SHA256 = "641dd1fdbf9965d8418ffe66d728a67aad46054911fa5316b5ae96ee66c0a7f3"


class PreparationError(RuntimeError):
    pass


def read_project(path: Path) -> dict:
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        check=False, capture_output=True, text=True,
    )
    if result.returncode:
        raise PreparationError(f"Cannot parse project metadata: {path}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def configurations(objects: dict, owner: dict) -> list[dict]:
    configuration_list = objects[owner["buildConfigurationList"]]
    return [objects[identifier] for identifier in configuration_list["buildConfigurations"]]


def platform_words(value: str | list | None) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    return shlex.split(value or "")


def validate_build_phases(source: Path, relative_project: Path, target: dict, objects: dict) -> None:
    for identifier in target.get("buildRules", []):
        if objects[identifier].get("script"):
            raise PreparationError(f"Unaudited build rule: {relative_project}: {target['name']}")
    for identifier in target.get("buildPhases", []):
        phase = objects[identifier]
        if phase.get("isa") != "PBXShellScriptBuildPhase":
            continue
        script_lines = [
            line.strip() for line in phase.get("shellScript", "").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        libre_path = Path("LibreTransmitter/LibreTransmitter.xcodeproj/project.pbxproj")
        if (
            relative_project == libre_path
            and target.get("name") == "LibreTransmitterPlugin"
            and script_lines == ['"${SRCROOT}/Scripts/capture-build-details.sh"']
        ):
            script = source / "LibreTransmitter/Scripts/capture-build-details.sh"
            if hashlib.sha256(script.read_bytes()).hexdigest() == LIBRE_SCRIPT_SHA256:
                # Audited: writes only the built product Info.plist. No .git is
                # mirrored, so it also cannot update the source repository index.
                continue
        raise PreparationError(
            f"Unaudited shell build phase: {relative_project}: {target['name']}: {phase.get('name', identifier)}"
        )


def patch_project(path: Path, relative_project: Path, source: Path) -> dict:
    project = read_project(path)
    objects = project["objects"]
    project_object = objects[project["rootObject"]]
    project_configurations = {
        item["name"]: item.get("buildSettings", {}) for item in configurations(objects, project_object)
    }
    patched = []
    native = []
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget":
            continue
        name = target.get("name", "")
        target_configurations = configurations(objects, target)
        is_dependency = target.get("productType") in CATALYST_PRODUCTS
        if name in NATIVE_TARGETS or name == APP_TARGET or is_dependency:
            validate_build_phases(source, relative_project, target, objects)
        for configuration in target_configurations:
            settings = configuration.setdefault("buildSettings", {})
            effective = {**project_configurations.get(configuration["name"], {}), **settings}
            sdk = str(effective.get("SDKROOT", ""))
            platforms = platform_words(effective.get("SUPPORTED_PLATFORMS"))
            if name in NATIVE_TARGETS:
                if sdk != "macosx" or effective.get("SUPPORTS_MACCATALYST") != "NO":
                    raise PreparationError(f"Native target must already remain native: {name}/{configuration['name']}")
                native.append({"target": name, "configuration": configuration["name"]})
                continue
            if not is_dependency:
                continue
            # Target-level SDKROOT=macosx remains native, even when project-level
            # defaults describe iOS. Never turn a native dependency into Catalyst.
            if sdk.startswith("macosx") or sdk.startswith("watchos"):
                continue
            if not (sdk.startswith("iphone") or any(word.startswith("iphone") for word in platforms)):
                continue
            settings["SUPPORTS_MACCATALYST"] = "YES"
            settings["SUPPORTED_PLATFORMS"] = " ".join(dict.fromkeys([
                *platforms, "iphoneos", "iphonesimulator", "macosx"
            ]))
            settings["MACOSX_DEPLOYMENT_TARGET"] = MAC_DEPLOYMENT
            patched.append({"target": name, "configuration": configuration["name"]})
    # Xcode accepts XML property lists as project metadata. plutil parses both
    # the original OpenStep format and this output; no lossy text substitutions.
    path.write_bytes(plistlib.dumps(project, fmt=plistlib.FMT_XML, sort_keys=False))
    read_project(path)
    return {"project": str(relative_project), "patchedConfigurations": patched, "nativeConfigurations": native}


def copy_file(source: Path, destination: Path) -> None:
    # clonefile creates a distinct inode with copy-on-write APFS extents. Unlike
    # hard links, later Xcode writes therefore cannot alter the original file.
    if sys.platform == "darwin":
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        clone = library.clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        clone.restype = ctypes.c_int
        if clone(os.fsencode(source), os.fsencode(destination), 0) == 0:
            return
    shutil.copy2(source, destination)


def copy_source_tree(source: Path, destination: Path, source_root: Path, mirror_root: Path,
                     ancestors: tuple[Path, ...] = ()) -> None:
    if source.is_symlink():
        resolved = source.resolve(strict=True)
        if resolved == source_root or source_root in resolved.parents:
            isolated_target = mirror_root / resolved.relative_to(source_root)
            destination.symlink_to(os.path.relpath(isolated_target, destination.parent),
                                   target_is_directory=resolved.is_dir())
        else:
            # External links must not leave a route back to the original data.
            copy_source_tree(resolved, destination, source_root, mirror_root, ancestors)
    elif source.is_dir():
        if source in ancestors:
            raise PreparationError(f"Cyclic external source link: {source}")
        destination.mkdir()
        for entry in source.iterdir():
            if entry.name not in EXCLUDED:
                copy_source_tree(entry, destination / entry.name, source_root, mirror_root,
                                 (*ancestors, source))
    elif source.is_file():
        copy_file(source, destination)
    else:
        raise PreparationError(f"Unsupported source file: {source}")


def validate_source_isolation(mirror: Path) -> None:
    for directory, folders, files in os.walk(mirror, followlinks=False):
        for name in [*folders, *files]:
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            resolved = path.resolve(strict=True)
            if resolved != mirror and mirror not in resolved.parents:
                raise PreparationError(f"Source link escapes isolated copy: {path}")


def prepare(source: Path, output: Path | None = None) -> tuple[Path, dict]:
    source = source.resolve(strict=True)
    if not (source / "Trio.xcworkspace/contents.xcworkspacedata").is_file():
        raise PreparationError(f"Not a Trio source checkout: {source}")
    if output is None:
        output = Path(tempfile.mkdtemp(prefix="trio-macos-workspace-"))
    else:
        output = output.resolve()
        if output == source or source in output.parents:
            raise PreparationError("Output must be outside the original source checkout")
        if output.exists() and any(output.iterdir()):
            raise PreparationError(f"Output directory is not empty: {output}")
        output.mkdir(parents=True, exist_ok=True)
    mirror = output / "Source"
    copy_source_tree(source, mirror, source, mirror)
    validate_source_isolation(mirror)
    projects = [path.relative_to(mirror) for path in mirror.rglob("*.xcodeproj/project.pbxproj")]
    records = []
    for relative in sorted(projects):
        path = mirror / relative
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        record = patch_project(path, relative, source)
        record["sourceMetadataSHA256"] = digest
        records.append(record)

    # Copied shared schemes may contain executable pre/post actions. Reject
    # such actions for our selected scheme instead of running unaudited code.
    for scheme in mirror.glob(f"**/xcshareddata/xcschemes/{SCHEME}.xcscheme"):
        if "<ExecutionAction" in scheme.read_text():
            raise PreparationError(f"Unaudited scheme execution action: {scheme.relative_to(mirror)}")

    (output / "DerivedData").mkdir()
    (output / "SourcePackages").mkdir()
    manifest = {
        "sourceRoot": str(source), "mirrorRoot": str(mirror), "scheme": SCHEME,
        "macOSDeploymentTarget": MAC_DEPLOYMENT,
        "catalystIOSDeploymentTarget": CATALYST_IOS_DEPLOYMENT,
        "workspace": str(mirror / "Trio.xcworkspace"),
        "sourceIsolation": "APFS copy-on-write clones or independent copies; links remain inside the copy",
        "projects": records,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return output, manifest


def validate_extra_arguments(arguments: list[str]) -> None:
    forbidden_options = {
        "-workspace", "-project", "-scheme", "-destination", "-sdk", "-derivedDataPath",
        "-clonedSourcePackagesDirPath", "-archivePath", "-resultBundlePath", "-xcconfig",
    }
    forbidden_settings = {
        "SUPPORTS_MACCATALYST", "SUPPORTED_PLATFORMS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET",
        "IPHONEOS_DEPLOYMENT_TARGET",
        "SRCROOT", "SOURCE_ROOT", "PROJECT_DIR", "SYMROOT", "OBJROOT", "BUILD_DIR", "CONFIGURATION_BUILD_DIR",
    }
    for argument in arguments:
        key = argument.split("=", 1)[0].split("[", 1)[0]
        if key in forbidden_options or key in forbidden_settings:
            raise PreparationError(f"Argument would bypass target or output isolation: {argument}")


def xcodebuild_command(manifest: dict, output: Path, configuration: str,
                       show_destinations: bool, extras: list[str]) -> list[str]:
    validate_extra_arguments(extras)
    command = [
        "/usr/bin/xcrun", "xcodebuild", "-workspace", manifest["workspace"], "-scheme", SCHEME,
        "-configuration", configuration,
        "-derivedDataPath", str(output / "DerivedData"),
        "-clonedSourcePackagesDirPath", str(output / "SourcePackages"),
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
        # Catalyst derives its effective macOS minimum from the iOS minimum,
        # including SwiftPM dependencies. SDKSettings maps 17.6 to macOS 14.6.
        # Both deployment floors are safe for native widgets/helper as well;
        # platform and SUPPORTS_MACCATALYST overrides must remain target-local.
        f"MACOSX_DEPLOYMENT_TARGET={MAC_DEPLOYMENT}",
        f"IPHONEOS_DEPLOYMENT_TARGET={CATALYST_IOS_DEPLOYMENT}",
    ]
    if show_destinations:
        command += ["-showdestinations"]
    else:
        command += ["-destination", "platform=macOS,variant=Mac Catalyst", "build"]
    return command + extras


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New/empty output directory outside the source checkout")
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--developer-dir", type=Path, help="Full Xcode Contents/Developer directory; otherwise uses DEVELOPER_DIR")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--prepare-only", action="store_true", help="Generate isolated metadata without invoking Xcode")
    action.add_argument("--show-destinations", action="store_true", help="Validate project parsing and show available destinations")
    parser.add_argument("xcodebuild_arguments", nargs=argparse.REMAINDER, help="Additional xcodebuild options after --")
    options = parser.parse_args(argv)
    extras = options.xcodebuild_arguments
    if extras[:1] == ["--"]:
        extras = extras[1:]
    validate_extra_arguments(extras)
    output, manifest = prepare(options.source_root, options.output)
    print(f"Isolated workspace: {manifest['workspace']}", flush=True)
    print(f"Build output: {output}", flush=True)
    if options.prepare_only:
        return 0
    environment = os.environ.copy()
    if options.developer_dir:
        environment["DEVELOPER_DIR"] = str(options.developer_dir.resolve())
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    command = xcodebuild_command(manifest, output, options.configuration, options.show_destinations, extras)
    print("Command: " + shlex.join(command), flush=True)
    return subprocess.run(command, cwd=manifest["mirrorRoot"], env=environment, check=False).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PreparationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Mac workspace preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
