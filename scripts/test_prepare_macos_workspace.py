#!/usr/bin/env python3
"""Bounded synthetic checks for the Catalyst workspace generator."""

import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("prepare_macos_workspace", Path(__file__).with_name("prepare_macos_workspace.py"))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def fixture_project(targets):
    objects = {
        "PROJECT": {"isa": "PBXProject", "buildConfigurationList": "PROJECT_CONFIGS", "targets": []},
        "PROJECT_CONFIGS": {"isa": "XCConfigurationList", "buildConfigurations": ["PROJECT_DEBUG"]},
        "PROJECT_DEBUG": {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": {"SDKROOT": "iphoneos"}},
    }
    for index, (name, product, settings) in enumerate(targets):
        key = f"TARGET_{index}"
        objects["PROJECT"]["targets"].append(key)
        objects[key] = {
            "isa": "PBXNativeTarget", "name": name, "productType": product,
            "buildConfigurationList": key + "_CONFIGS", "buildPhases": [],
        }
        objects[key + "_CONFIGS"] = {"isa": "XCConfigurationList", "buildConfigurations": [key + "_DEBUG"]}
        objects[key + "_DEBUG"] = {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings}
    return {"archiveVersion": "1", "objectVersion": "56", "rootObject": "PROJECT", "objects": objects}


class WorkspacePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="trio-mirror-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "Original Sources"
        self.source.mkdir()
        workspace = self.source / "Trio.xcworkspace"
        workspace.mkdir()
        (workspace / "contents.xcworkspacedata").write_text('<Workspace version="1.0"/>')
        package = self.source / "LocalPackage"
        package.mkdir()
        (package / "Package.swift").write_text("// Synthetic package fixture")
        (package / "Package.resolved").write_text('{"version": 3, "pins": []}')
        (package / "Sources").mkdir()
        (package / "Sources/Fixture.swift").write_text("// Original source must stay unchanged")
        self.project = self.source / "Trio.xcodeproj/project.pbxproj"
        self.project.parent.mkdir()
        model = fixture_project([
            ("Framework", "com.apple.product-type.framework", {"SUPPORTS_MACCATALYST": "NO"}),
            ("Plugin", "com.apple.product-type.bundle", {}),
            ("TrioMac", "com.apple.product-type.application", {"SUPPORTS_MACCATALYST": "YES"}),
            ("TrioMacWidgets", "com.apple.product-type.app-extension", {
                "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx", "SUPPORTS_MACCATALYST": "NO"
            }),
            ("TrioMenuBar", "com.apple.product-type.application", {
                "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx", "SUPPORTS_MACCATALYST": "NO"
            }),
            ("WatchFramework", "com.apple.product-type.framework", {"SDKROOT": "watchos"}),
        ])
        self.project.write_bytes(plistlib.dumps(model))

    def testOnlyIOSDependenciesGainCatalystAndOriginalMetadataIsUnchanged(self):
        original = self.project.read_bytes()
        output, manifest = generator.prepare(self.source, self.base / "Prepared Workspace")
        self.assertEqual(self.project.read_bytes(), original)
        copy = generator.read_project(output / "Source/Trio.xcodeproj/project.pbxproj")["objects"]
        for index in [0, 1]:
            settings = copy[f"TARGET_{index}_DEBUG"]["buildSettings"]
            self.assertEqual(settings["SUPPORTS_MACCATALYST"], "YES")
            self.assertIn("macosx", settings["SUPPORTED_PLATFORMS"].split())
            self.assertEqual(settings["MACOSX_DEPLOYMENT_TARGET"], "14.6")
        for index in [3, 4]:
            settings = copy[f"TARGET_{index}_DEBUG"]["buildSettings"]
            self.assertEqual(settings["SUPPORTS_MACCATALYST"], "NO")
            self.assertEqual(settings["SDKROOT"], "macosx")
        self.assertNotIn("SUPPORTS_MACCATALYST", copy["TARGET_5_DEBUG"]["buildSettings"])
        self.assertEqual(len(manifest["projects"][0]["patchedConfigurations"]), 2)

    def testSourcesAndMetadataAreIndependentWhileInternalLinksRemainInsideCopy(self):
        (self.source / "LinkedSources").symlink_to("LocalPackage/Sources", target_is_directory=True)
        output, _ = generator.prepare(self.source, self.base / "mirror")
        mirror = output / "Source"
        self.assertFalse((mirror / "LocalPackage/Sources").is_symlink())
        self.assertFalse((mirror / "LocalPackage/Package.swift").is_symlink())
        self.assertTrue((mirror / "LinkedSources").is_symlink())
        self.assertEqual((mirror / "LinkedSources").resolve(), mirror / "LocalPackage/Sources")
        self.assertFalse((mirror / "LocalPackage/Package.resolved").is_symlink())
        self.assertFalse((mirror / "Trio.xcodeproj").is_symlink())
        self.assertFalse((mirror / "Trio.xcworkspace").is_symlink())
        (mirror / "LocalPackage/Package.resolved").write_text("updated in mirror")
        self.assertNotEqual((self.source / "LocalPackage/Package.resolved").read_text(), "updated in mirror")
        original = self.source / "LocalPackage/Sources/Fixture.swift"
        isolated = mirror / "LinkedSources/Fixture.swift"
        self.assertNotEqual(os.stat(original).st_ino, os.stat(isolated).st_ino)
        isolated.write_text("changed only inside copied sources")
        self.assertEqual(original.read_text(), "// Original source must stay unchanged")

    def testReusesFreshMetadataAndRejectsUnsafeOutputsOrGlobalPlatformOverrides(self):
        first, _ = generator.prepare(self.source, self.base / "first")
        changed = plistlib.loads(self.project.read_bytes())
        changed["objects"]["TARGET_0_DEBUG"]["buildSettings"]["NEW_SOURCE_SETTING"] = "fresh"
        self.project.write_bytes(plistlib.dumps(changed))
        second, _ = generator.prepare(self.source, self.base / "second")
        self.assertNotIn("NEW_SOURCE_SETTING", generator.read_project(first / "Source/Trio.xcodeproj/project.pbxproj")["objects"]["TARGET_0_DEBUG"]["buildSettings"])
        self.assertEqual(generator.read_project(second / "Source/Trio.xcodeproj/project.pbxproj")["objects"]["TARGET_0_DEBUG"]["buildSettings"]["NEW_SOURCE_SETTING"], "fresh")
        with self.assertRaises(generator.PreparationError):
            generator.prepare(self.source, self.source / "unsafe")
        with self.assertRaises(generator.PreparationError):
            generator.prepare(self.source, first)
        for argument in ["SUPPORTS_MACCATALYST=YES", "SDKROOT=macosx", "SUPPORTED_PLATFORMS=macosx", "IPHONEOS_DEPLOYMENT_TARGET=13.1", "-derivedDataPath", "-scheme=Other", "-xcconfig"]:
            with self.assertRaises(generator.PreparationError):
                generator.validate_extra_arguments([argument])

    def testUnknownDependencyScriptsFailClosed(self):
        changed = plistlib.loads(self.project.read_bytes())
        changed["objects"]["SCRIPT"] = {"isa": "PBXShellScriptBuildPhase", "shellScript": "touch source.swift"}
        changed["objects"]["TARGET_0"]["buildPhases"] = ["SCRIPT"]
        self.project.write_bytes(plistlib.dumps(changed))
        with self.assertRaisesRegex(generator.PreparationError, "Unaudited shell"):
            generator.prepare(self.source, self.base / "unsafe-script")

    def testSelectedSharedSchemeActionsFailClosed(self):
        scheme = self.project.parent / "xcshareddata/xcschemes/Trio Mac.xcscheme"
        scheme.parent.mkdir(parents=True)
        scheme.write_text('<Scheme><ExecutionAction ActionType="ShellScriptAction"/></Scheme>')
        with self.assertRaisesRegex(generator.PreparationError, "Unaudited scheme"):
            generator.prepare(self.source, self.base / "unsafe-scheme")

    def testExternalLinksBecomeIndependentCopies(self):
        external = self.base / "External Sources"
        external.mkdir()
        (external / "external.swift").write_text("// External original")
        (self.source / "External").symlink_to(external, target_is_directory=True)
        output, _ = generator.prepare(self.source, self.base / "copied-external")
        isolated = output / "Source/External"
        self.assertFalse(isolated.is_symlink())
        (isolated / "external.swift").write_text("// Only the copy changes")
        self.assertEqual((external / "external.swift").read_text(), "// External original")

    def testBuildCommandPinsMatchingDeploymentFloorsWithoutGlobalPlatformOverrides(self):
        output = self.base / "output"
        manifest = {"workspace": str(output / "Source/Trio.xcworkspace")}
        for destinations in [False, True]:
            command = generator.xcodebuild_command(manifest, output, "Debug", destinations, ["CODE_SIGNING_ALLOWED=NO"])
            self.assertIn("MACOSX_DEPLOYMENT_TARGET=14.6", command)
            self.assertIn("IPHONEOS_DEPLOYMENT_TARGET=17.6", command)
            self.assertFalse(any(argument.split("=", 1)[0] in {
                "SUPPORTS_MACCATALYST", "SUPPORTED_PLATFORMS", "SDKROOT"
            } for argument in command))
            self.assertEqual("-showdestinations" in command, destinations)
            self.assertEqual("build" in command, not destinations)


if __name__ == "__main__":
    unittest.main()
