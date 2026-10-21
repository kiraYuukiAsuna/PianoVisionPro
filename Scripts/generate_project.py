#!/usr/bin/env python3
"""Generate the dependency-free, two-target Xcode project. Run after adding sources."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
objects = {}

# Xcode stores the user's development team here. Adding source files must not
# discard a working device-signing configuration or a personalized bundle ID.
saved_signing = {}
existing_project = ROOT / "PianoVisionPro.xcodeproj/project.pbxproj"
if existing_project.exists():
    existing = json.loads(subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(existing_project)],
        capture_output=True, text=True, check=True).stdout)["objects"]
    signing_keys = {"DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY",
                    "PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE",
                    "PRODUCT_BUNDLE_IDENTIFIER"}
    for target in existing.values():
        if target.get("isa") != "PBXNativeTarget":
            continue
        configs = existing[target["buildConfigurationList"]]["buildConfigurations"]
        for config_id in configs:
            config = existing[config_id]
            saved_signing[(target["name"], config["name"])] = {
                key: value for key, value in config.get("buildSettings", {}).items()
                if key in signing_keys or key.startswith("CODE_SIGN_IDENTITY[")
            }

def identifier(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def add(key, body):
    uid = identifier(key)
    objects[uid] = body
    return uid

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

def array(items):
    return "(" + ", ".join(items) + ")"

def config_list(key, settings):
    configs = []
    for name in ["Debug", "Release"]:
        values = dict(settings)
        values.update(saved_signing.get((key, name), {}))
        values.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                       "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym"})
        if name == "Debug":
            values["ONLY_ACTIVE_ARCH"] = "YES"
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
            values["ENABLE_TESTABILITY"] = "YES"
        configs.append(add(f"{key}-{name}", "isa = XCBuildConfiguration; name = " + name + "; buildSettings = {" + " ".join(f"{k} = {quote(v)};" for k, v in values.items()) + "};"))
    return add(f"{key}-configs", "isa = XCConfigurationList; buildConfigurations = " + array(configs) + "; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

package = add("shared-package", "isa = XCLocalSwiftPackageReference; relativePath = Packages/PianoShared;")
targets, products, source_groups = [], [], []
for target, directory, sdk, bundle in [
    ("PianoVision", "Apps/PianoVision", "xros", "com.pianovisionpro.mvp"),
    ("PianoBridge", "Apps/PianoBridge", "macosx", "com.pianovisionpro.bridge")
]:
    sources, resources, files = [], [], []
    for path in sorted((ROOT / directory).rglob("*")):
        if path.is_file() and path.suffix in {".swift", ".mid"}:
            rel = path.relative_to(ROOT).as_posix()
            kind = "sourcecode.swift" if path.suffix == ".swift" else "audio.midi"
            ref = add(rel, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(rel)}; sourceTree = SOURCE_ROOT;")
            files.append(ref)
            build = add(rel + "-build", f"isa = PBXBuildFile; fileRef = {ref};")
            (sources if path.suffix == ".swift" else resources).append(build)
    source_groups.append(add(target + "-group", "isa = PBXGroup; name = " + target + "; children = " + array(files) + '; sourceTree = "<group>";'))
    product = add(target + "-product", f"isa = PBXFileReference; explicitFileType = wrapper.application; path = {target}.app; sourceTree = BUILT_PRODUCTS_DIR;")
    products.append(product)
    deps, frameworks = [], []
    for name in (["PianoCore", "PianoLink"] if target == "PianoVision" else ["PianoLink"]):
        dep = add(target + "-" + name, f"isa = XCSwiftPackageProductDependency; package = {package}; productName = {name};")
        deps.append(dep)
        frameworks.append(add(target + "-" + name + "-build", f"isa = PBXBuildFile; productRef = {dep};"))
    phases = []
    for phase, values in [("Sources", sources), ("Frameworks", frameworks), ("Resources", resources)]:
        phases.append(add(target + phase, f"isa = PBX{phase}BuildPhase; buildActionMask = 2147483647; files = {array(values)}; runOnlyForDeploymentPostprocessing = 0;"))
    settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": bundle,
        "INFOPLIST_FILE": directory + "/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "SDKROOT": sdk, "SWIFT_VERSION": "6.0", "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES"
    }
    if sdk == "xros":
        settings.update({"SUPPORTED_PLATFORMS": "xros xrsimulator", "XROS_DEPLOYMENT_TARGET": "2.0", "TARGETED_DEVICE_FAMILY": "7"})
    else:
        settings.update({"SUPPORTED_PLATFORMS": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "ENABLE_HARDENED_RUNTIME": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks"})
    configs = config_list(target, settings)
    targets.append(add(target, f"isa = PBXNativeTarget; name = {target}; productName = {target}; productReference = {product}; productType = \"com.apple.product-type.application\"; buildConfigurationList = {configs}; buildPhases = {array(phases)}; buildRules = (); dependencies = (); packageProductDependencies = {array(deps)};"))

product_group = add("products", "isa = PBXGroup; name = Products; children = " + array(products) + '; sourceTree = "<group>";')
main_group = add("root", "isa = PBXGroup; children = " + array(source_groups + [product_group]) + '; sourceTree = "<group>";')
configs = config_list("project", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_VERSION": "6.0"})
project = add("project", f"isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {configs}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; knownRegions = (en, Base, \"zh-Hans\"); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = {array(targets)}; packageReferences = ({package});")
output = ROOT / "PianoVisionPro.xcodeproj"
output.mkdir(exist_ok=True)
(output / "project.pbxproj").write_text("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n" + "\n".join(f"{uid} = {{{body}}};" for uid, body in objects.items()) + f"\n}}; rootObject = {project}; }}\n")
schemes = output / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for target in ["PianoVision", "PianoBridge"]:
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(target)}" BuildableName="{target}.app" BlueprintName="{target}" ReferencedContainer="container:PianoVisionPro.xcodeproj"/>'
    (schemes / f"{target}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f"Generated {output.name} ({len(objects)} objects)")
