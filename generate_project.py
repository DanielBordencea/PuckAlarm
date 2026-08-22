#!/usr/bin/env python3
"""Generates PuckAlarm.xcodeproj/project.pbxproj.

Hand-editing a pbxproj is how projects get corrupted; regenerating it from a declarative
file list is not. Run this after adding or removing a source file:

    python3 generate_project.py

Shared sources are compiled into both the app and the widget extension. The widget needs
the metadata type (to decode the Live Activity payload) and the intent types (for the
"Scan Puck" button); it never touches the NFC or view layers.
"""

from __future__ import annotations

import hashlib
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
PROJECT_NAME = "PuckAlarm"
APP_TARGET = "PuckAlarm"
EXT_TARGET = "PuckAlarmWidgetExtension"
BUNDLE_ID = "com.bordencea.PuckAlarm"
EXT_BUNDLE_ID = f"{BUNDLE_ID}.PuckAlarmWidget"
DEPLOYMENT_TARGET = "26.1"  # AlarmPresentation.Alert's stopButton-free initialiser.
SWIFT_VERSION = "6.0"

# The NFC reader-session entitlement requires a paid Apple Developer Program membership.
# A free Apple ID cannot sign a build that carries it — signing fails outright rather than
# degrading. Set this to False to sideload with a free account and use the app's
# "Simulate puck scans" switch instead of real tag reads.
USE_NFC_ENTITLEMENT = False

# Compiled into both targets.
SHARED_SOURCES = [
    "PuckAlarm/Model/PuckAlarmMetadata.swift",
    "PuckAlarm/Model/AlarmItem.swift",
    "PuckAlarm/Store/AlarmStore.swift",
    "PuckAlarm/Store/PuckKeychain.swift",
    "PuckAlarm/Alarm/AlarmScheduler.swift",
    "PuckAlarm/Alarm/WakeEnforcer.swift",
    "PuckAlarm/Intents/AlarmIntents.swift",
    "PuckAlarm/Intents/AppRouter.swift",
    "PuckAlarm/Design/Theme.swift",
    "PuckAlarm/Design/AppLog.swift",
]

APP_ONLY_SOURCES = [
    "PuckAlarm/PuckAlarmApp.swift",
    "PuckAlarm/NFC/PuckReader.swift",
    "PuckAlarm/Views/RootView.swift",
    "PuckAlarm/Views/AlarmListView.swift",
    "PuckAlarm/Views/AlarmEditorView.swift",
    "PuckAlarm/Views/ScanGateView.swift",
    "PuckAlarm/Views/SettingsView.swift",
]

EXT_ONLY_SOURCES = [
    "PuckAlarmWidget/PuckAlarmWidgetBundle.swift",
    "PuckAlarmWidget/PuckAlarmLiveActivity.swift",
]

APP_RESOURCES = ["PuckAlarm/Assets.xcassets"]

OTHER_FILES = [
    "PuckAlarm/Info.plist",
    "PuckAlarm/PuckAlarm.entitlements",
    "PuckAlarmWidget/Info.plist",
]

_used_ids: set[str] = set()


def oid(*parts: str) -> str:
    """Deterministic 24-hex-character object id, so regenerating produces a stable diff."""
    base = hashlib.sha1("::".join(parts).encode()).hexdigest()[:24].upper()
    while base in _used_ids:
        base = hashlib.sha1((base + "!").encode()).hexdigest()[:24].upper()
    _used_ids.add(base)
    return base


def file_type(path: str) -> str:
    suffix = pathlib.Path(path).suffix
    return {
        ".swift": "sourcecode.swift",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".xcassets": "folder.assetcatalog",
        ".md": "net.daringfireball.markdown",
    }.get(suffix, "text")


class Project:
    def __init__(self) -> None:
        self.objects: list[str] = []
        self.file_refs: dict[str, str] = {}

    def emit(self, identifier: str, isa: str, body: str, comment: str = "") -> str:
        label = f" /* {comment} */" if comment else ""
        self.objects.append(f"\t\t{identifier}{label} = {{\n\t\t\tisa = {isa};\n{body}\t\t}};")
        return identifier

    def file_ref(self, path: str) -> str:
        if path in self.file_refs:
            return self.file_refs[path]
        identifier = oid("fileref", path)
        name = pathlib.Path(path).name
        self.emit(
            identifier,
            "PBXFileReference",
            f"\t\t\tlastKnownFileType = {file_type(path)};\n"
            f"\t\t\tpath = {name};\n"
            f"\t\t\tsourceTree = \"<group>\";\n",
            name,
        )
        self.file_refs[path] = identifier
        return identifier

    def build_file(self, path: str, target: str) -> str:
        identifier = oid("buildfile", target, path)
        ref = self.file_ref(path)
        name = pathlib.Path(path).name
        self.emit(
            identifier,
            "PBXBuildFile",
            f"\t\t\tfileRef = {ref} /* {name} */;\n",
            f"{name} in {target}",
        )
        return identifier


def build_tree(paths: list[str]) -> dict:
    """Nested dict mirroring the on-disk folders, so Xcode's navigator matches Finder."""
    tree: dict = {}
    for path in paths:
        parts = path.split("/")
        node = tree
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node.setdefault("__files__", []).append(path)
    return tree


def main() -> None:
    project = Project()

    all_sources = sorted(set(SHARED_SOURCES + APP_ONLY_SOURCES + EXT_ONLY_SOURCES))
    for path in all_sources + APP_RESOURCES + OTHER_FILES:
        if not (ROOT / path).exists():
            raise SystemExit(f"missing file listed in generator: {path}")

    # --- Products -----------------------------------------------------------------
    app_product = oid("product", APP_TARGET)
    project.emit(
        app_product,
        "PBXFileReference",
        "\t\t\texplicitFileType = wrapper.application;\n"
        "\t\t\tincludeInIndex = 0;\n"
        f"\t\t\tpath = {APP_TARGET}.app;\n"
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n",
        f"{APP_TARGET}.app",
    )
    ext_product = oid("product", EXT_TARGET)
    project.emit(
        ext_product,
        "PBXFileReference",
        "\t\t\texplicitFileType = \"wrapper.app-extension\";\n"
        "\t\t\tincludeInIndex = 0;\n"
        f"\t\t\tpath = {EXT_TARGET}.appex;\n"
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n",
        f"{EXT_TARGET}.appex",
    )

    # --- Build files --------------------------------------------------------------
    app_source_files = [
        project.build_file(p, APP_TARGET) for p in sorted(SHARED_SOURCES + APP_ONLY_SOURCES)
    ]
    ext_source_files = [
        project.build_file(p, EXT_TARGET) for p in sorted(SHARED_SOURCES + EXT_ONLY_SOURCES)
    ]
    app_resource_files = [project.build_file(p, APP_TARGET) for p in APP_RESOURCES]
    for path in OTHER_FILES:
        project.file_ref(path)

    embed_ref = oid("embed", EXT_TARGET)
    project.emit(
        embed_ref,
        "PBXBuildFile",
        f"\t\t\tfileRef = {ext_product} /* {EXT_TARGET}.appex */;\n"
        "\t\t\tsettings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); };\n",
        f"{EXT_TARGET}.appex in Embed Foundation Extensions",
    )

    # --- Groups -------------------------------------------------------------------
    def emit_group(name: str, node: dict, path_component: str | None) -> str:
        children: list[tuple[str, str]] = []
        for key in sorted(k for k in node if k != "__files__"):
            child = emit_group(key, node[key], key)
            children.append((child, key))
        for file_path in sorted(node.get("__files__", [])):
            children.append((project.file_refs[file_path], pathlib.Path(file_path).name))

        identifier = oid("group", name, path_component or "root")
        rendered = "".join(f"\t\t\t\t{cid} /* {cname} */,\n" for cid, cname in children)
        body = (
            f"\t\t\tchildren = (\n{rendered}\t\t\t);\n"
            + (f"\t\t\tpath = {path_component};\n" if path_component else f"\t\t\tname = {name};\n")
            + "\t\t\tsourceTree = \"<group>\";\n"
        )
        return project.emit(identifier, "PBXGroup", body, name)

    tree = build_tree(all_sources + APP_RESOURCES + OTHER_FILES)
    app_group = emit_group("PuckAlarm", tree["PuckAlarm"], "PuckAlarm")
    ext_group = emit_group("PuckAlarmWidget", tree["PuckAlarmWidget"], "PuckAlarmWidget")

    products_group = oid("group", "Products")
    project.emit(
        products_group,
        "PBXGroup",
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{app_product} /* {APP_TARGET}.app */,\n"
        f"\t\t\t\t{ext_product} /* {EXT_TARGET}.appex */,\n"
        f"\t\t\t);\n"
        "\t\t\tname = Products;\n"
        "\t\t\tsourceTree = \"<group>\";\n",
        "Products",
    )

    generator_ref = project.file_ref("generate_project.py")
    readme_ref = project.file_ref("README.md")

    root_group = oid("group", "root")
    project.emit(
        root_group,
        "PBXGroup",
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{app_group} /* PuckAlarm */,\n"
        f"\t\t\t\t{ext_group} /* PuckAlarmWidget */,\n"
        f"\t\t\t\t{readme_ref} /* README.md */,\n"
        f"\t\t\t\t{generator_ref} /* generate_project.py */,\n"
        f"\t\t\t\t{products_group} /* Products */,\n"
        f"\t\t\t);\n"
        "\t\t\tsourceTree = \"<group>\";\n",
    )

    # --- Build phases -------------------------------------------------------------
    def phase(isa: str, key: str, files: list[str], extra: str = "") -> str:
        rendered = "".join(f"\t\t\t\t{f},\n" for f in files)
        return project.emit(
            oid("phase", isa, key),
            isa,
            "\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{rendered}\t\t\t);\n"
            + extra
            + "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n",
            key,
        )

    app_sources_phase = phase("PBXSourcesBuildPhase", f"{APP_TARGET} Sources", app_source_files)
    app_frameworks_phase = phase("PBXFrameworksBuildPhase", f"{APP_TARGET} Frameworks", [])
    app_resources_phase = phase("PBXResourcesBuildPhase", f"{APP_TARGET} Resources", app_resource_files)
    embed_phase = project.emit(
        oid("phase", "embed", EXT_TARGET),
        "PBXCopyFilesBuildPhase",
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tdstPath = \"\";\n"
        "\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{embed_ref},\n\t\t\t);\n"
        "\t\t\tname = \"Embed Foundation Extensions\";\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n",
        "Embed Foundation Extensions",
    )

    ext_sources_phase = phase("PBXSourcesBuildPhase", f"{EXT_TARGET} Sources", ext_source_files)
    ext_frameworks_phase = phase("PBXFrameworksBuildPhase", f"{EXT_TARGET} Frameworks", [])
    ext_resources_phase = phase("PBXResourcesBuildPhase", f"{EXT_TARGET} Resources", [])

    # --- Build configurations -----------------------------------------------------
    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    }
    project_debug = {
        **project_common,
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    }
    project_release = {
        **project_common,
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "VALIDATE_PRODUCT": "YES",
    }

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "PuckAlarm/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if USE_NFC_ENTITLEMENT:
        app_common["CODE_SIGN_ENTITLEMENTS"] = "PuckAlarm/PuckAlarm.entitlements"

    ext_common = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "PuckAlarmWidget/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "PuckAlarmWidget",
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": EXT_BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }

    def config(key: str, name: str, settings: dict[str, str]) -> str:
        rendered = "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(settings.items()))
        return project.emit(
            oid("config", key, name),
            "XCBuildConfiguration",
            f"\t\t\tbuildSettings = {{\n{rendered}\t\t\t}};\n\t\t\tname = {name};\n",
            name,
        )

    def config_list(key: str, debug: str, release: str) -> str:
        return project.emit(
            oid("configlist", key),
            "XCConfigurationList",
            f"\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{debug} /* Debug */,\n"
            f"\t\t\t\t{release} /* Release */,\n"
            f"\t\t\t);\n"
            "\t\t\tdefaultConfigurationIsVisible = 0;\n"
            "\t\t\tdefaultConfigurationName = Release;\n",
            f"Build configuration list for {key}",
        )

    project_list = config_list(
        "project", config("project", "Debug", project_debug), config("project", "Release", project_release)
    )
    app_list = config_list(
        "app", config("app", "Debug", app_common), config("app", "Release", app_common)
    )
    ext_list = config_list(
        "ext", config("ext", "Debug", ext_common), config("ext", "Release", ext_common)
    )

    # --- Targets ------------------------------------------------------------------
    proxy = oid("proxy", EXT_TARGET)
    project_id = oid("project", PROJECT_NAME)
    ext_target = oid("target", EXT_TARGET)
    app_target = oid("target", APP_TARGET)

    project.emit(
        proxy,
        "PBXContainerItemProxy",
        f"\t\t\tcontainerPortal = {project_id} /* Project object */;\n"
        "\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {ext_target};\n"
        f"\t\t\tremoteInfo = {EXT_TARGET};\n",
    )
    dependency = project.emit(
        oid("dependency", EXT_TARGET),
        "PBXTargetDependency",
        f"\t\t\ttarget = {ext_target} /* {EXT_TARGET} */;\n"
        f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n",
    )

    project.emit(
        ext_target,
        "PBXNativeTarget",
        f"\t\t\tbuildConfigurationList = {ext_list};\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{ext_sources_phase} /* Sources */,\n"
        f"\t\t\t\t{ext_frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{ext_resources_phase} /* Resources */,\n"
        f"\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = {EXT_TARGET};\n"
        f"\t\t\tproductName = {EXT_TARGET};\n"
        f"\t\t\tproductReference = {ext_product};\n"
        "\t\t\tproductType = \"com.apple.product-type.app-extension\";\n",
        EXT_TARGET,
    )
    project.emit(
        app_target,
        "PBXNativeTarget",
        f"\t\t\tbuildConfigurationList = {app_list};\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{app_sources_phase} /* Sources */,\n"
        f"\t\t\t\t{app_frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{app_resources_phase} /* Resources */,\n"
        f"\t\t\t\t{embed_phase} /* Embed Foundation Extensions */,\n"
        f"\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t\t{dependency},\n\t\t\t);\n"
        f"\t\t\tname = {APP_TARGET};\n"
        f"\t\t\tproductName = {APP_TARGET};\n"
        f"\t\t\tproductReference = {app_product};\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n",
        APP_TARGET,
    )

    project.emit(
        project_id,
        "PBXProject",
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 2650;\n"
        "\t\t\t\tLastUpgradeCheck = 2650;\n"
        "\t\t\t\tTargetAttributes = {\n"
        f"\t\t\t\t\t{app_target} = {{ CreatedOnToolsVersion = 26.5; }};\n"
        f"\t\t\t\t\t{ext_target} = {{ CreatedOnToolsVersion = 26.5; }};\n"
        "\t\t\t\t};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {project_list};\n"
        "\t\t\tcompatibilityVersion = \"Xcode 15.0\";\n"
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t\tmainGroup = {root_group};\n"
        "\t\t\tminimizedProjectReferenceProxies = 1;\n"
        f"\t\t\tproductRefGroup = {products_group} /* Products */;\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        f"\t\t\ttargets = (\n\t\t\t\t{app_target} /* {APP_TARGET} */,\n\t\t\t\t{ext_target} /* {EXT_TARGET} */,\n\t\t\t);\n",
        "Project object",
    )

    body = "\n".join(project.objects)
    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        "\tobjectVersion = 60;\n"
        "\tobjects = {\n"
        f"{body}\n"
        "\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n"
    )

    out_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "project.pbxproj").write_text(content)

    schemes_dir = out_dir / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    (schemes_dir / f"{APP_TARGET}.xcscheme").write_text(scheme(app_target, app_product))

    print(f"wrote {out_dir/'project.pbxproj'}")
    print(f"  app sources: {len(app_source_files)}   widget sources: {len(ext_source_files)}")


def scheme(target_id: str, product_id: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2650" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{APP_TARGET}.app"
               BlueprintName = "{APP_TARGET}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    main()
