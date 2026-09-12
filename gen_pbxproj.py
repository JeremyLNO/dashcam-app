#!/usr/bin/env python3
"""Generate Dashcam.xcodeproj/project.pbxproj from the source tree.

The project file is derived, never hand-edited: every `.swift` under the source
directories below is discovered recursively and mirrored as nested PBXGroups, so adding
a file means creating it and re-running this script. UUIDs are md5 hashes of a role key,
which keeps successive runs byte-stable and diffable.

Targets: the app, a unit-test bundle, a UI-test bundle, and a widget extension carrying
the Control Center buttons. CarPlay needs no separate target (its scene delegate ships
inside the app), which is part of why the CarPlay feature can be switched off by simply not
granting the entitlement.

The control extension is a target only because it has to be: Control Center runs its
buttons from a separate process. It compiles two files — its own widget bundle and the
shared intent file, which the app compiles as well so the system can perform the intent in
whichever binary is running.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = "Dashcam"
BUNDLE_ID_VAR = "$(BUNDLE_IDENTIFIER)"

APP_SOURCE_DIRS = [
    "App", "Core", "Capture", "Storage", "Location", "Motion",
    "Protection", "Export", "Subscriptions", "CarPlay", "Notifications",
    "Features", "UI", "Intents",
]
WATCH_SOURCE_DIR = "Watch"
# Compiled into the watch app *and* the phone: one definition of the remote protocol, so
# a rename cannot leave the two halves speaking different dialects.
WATCH_SHARED_SOURCES = ["Watch/RemoteProtocol.swift"]
WATCH_INFO_PLIST = "Watch/Info.plist"
# The watch app needs an icon of its own: App Store Connect refuses a bundle whose
# Info.plist has no CFBundleIconName, and the key means nothing without a catalog
# carrying the icon it names.
WATCH_ASSETS = "Watch/Assets.xcassets"
WATCH_TARGET = f"{PROJ}Watch"
CONTROL_SOURCE_DIR = "Controls"
# Compiled into the extension *and* the app: an intent must exist in both binaries for
# iOS to hand it to the app once the control has opened it.
CONTROL_SHARED_SOURCES = ["Intents/ControlCommands.swift"]
CONTROL_INFO_PLIST = "Controls/Info.plist"
CONTROL_TARGET = f"{PROJ}Controls"
TEST_SOURCE_DIR = "Tests"
UITEST_SOURCE_DIR = "UITests"
RESOURCES_DIR = "Resources"

# Push provider. The Swift side is wrapped in `#if canImport(OneSignalFramework)`, so
# removing this entry leaves a project that still builds — notifications simply become
# local-only.
SPM_PACKAGES = [
    ("OneSignal-XCFramework", "https://github.com/OneSignal/OneSignal-XCFramework", "5.5.1", ["OneSignalFramework"]),
]

RESOURCE_FILES = [
    (f"{RESOURCES_DIR}/Assets.xcassets", "folder.assetcatalog"),
    (f"{RESOURCES_DIR}/Localizable.xcstrings", "text.json.xcstrings"),
    (f"{RESOURCES_DIR}/PrivacyInfo.xcprivacy", "text.plist.xml"),
]
# Local StoreKit definitions. Referenced by the scheme for interactive runs *and*
# bundled into the unit-test target, where `SKTestSession(configurationFileNamed:)`
# loads it directly — that path does not depend on the scheme being wired correctly,
# which is what makes the subscription tests reproducible from the command line.
STOREKIT_FILE = f"{RESOURCES_DIR}/{PROJ}.storekit"

INFO_PLIST = "App/Info.plist"
ENTITLEMENTS = f"App/{PROJ}.entitlements"
XCCONFIGS = ["Base.xcconfig", "Debug.xcconfig", "Release.xcconfig"]
ENVIRONMENTS = [("Debug", "Debug.xcconfig"), ("Release", "Release.xcconfig")]
KNOWN_REGIONS = ["en", "fr", "es", "de", "pt", "Base"]


def uid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def find_swift(top):
    results = []
    base = os.path.join(ROOT, top)
    if not os.path.isdir(base):
        return results
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, ROOT)
        for name in sorted(filenames):
            if name.endswith(".swift"):
                results.append(os.path.join(rel_dir, name).replace(os.sep, "/"))
    return results


app_files = []
for d in APP_SOURCE_DIRS:
    app_files += find_swift(d)
app_files += WATCH_SHARED_SOURCES
test_files = find_swift(TEST_SOURCE_DIR)
uitest_files = find_swift(UITEST_SOURCE_DIR)
control_files = find_swift(CONTROL_SOURCE_DIR) + CONTROL_SHARED_SOURCES
watch_files = find_swift(WATCH_SOURCE_DIR)

_fileref = {}


def fileref(path):
    if path not in _fileref:
        _fileref[path] = uid("fileref:" + path)
    return _fileref[path]


_group = {}


def group_uid(path):
    if path not in _group:
        _group[path] = uid("group:" + path)
    return _group[path]


def build_tree(paths):
    tree = {"files": [], "dirs": {}}
    for rel in paths:
        parts = rel.split("/")
        node = tree
        for part in parts[:-1]:
            node = node["dirs"].setdefault(part, {"files": [], "dirs": {}})
        node["files"].append(parts[-1])
    return tree


lines = []


def L(s=""):
    lines.append(s)


_emitted = set()


def emit_group(node, prefix, name):
    path = f"{prefix}/{name}" if prefix else name
    this = group_uid(path)
    if path in _emitted:
        return this
    _emitted.add(path)

    children = []
    for sub in sorted(node["dirs"]):
        children.append((emit_group(node["dirs"][sub], path, sub), sub))
    for fname in sorted(node["files"]):
        children.append((fileref(f"{path}/{fname}"), fname))

    L(f"\t\t{this} /* {name} */ = {{")
    L("\t\t\tisa = PBXGroup;")
    L("\t\t\tchildren = (")
    for child, comment in children:
        L(f"\t\t\t\t{child} /* {comment} */,")
    L("\t\t\t);")
    L(f"\t\t\tpath = {name};")
    L('\t\t\tsourceTree = "<group>";')
    L("\t\t};")
    return this


def emit_top_group(name, paths):
    tree = build_tree(paths)
    node = tree["dirs"].get(name, {"files": [], "dirs": {}})
    return emit_group(node, "", name)


# ---- UUIDs ------------------------------------------------------------------
prod_ref = uid("product.app")
watch_prod_ref = uid("product.watch")
watch_target = uid("target.watch")
watch_sources_phase = uid("phase.watch.sources")
watch_frameworks_phase = uid("phase.watch.frameworks")
watch_cfg_list = uid("cfglist.watch")
watch_proxy = uid("containerproxy.watch")
watch_dep = uid("targetdep.watch")
watch_embed_phase = uid("phase.app.embedwatch")
watch_embed_build = uid("build.embed.watch")
watch_group = uid("group.watch")
watch_plist_ref = uid("fileref.watch.plist")
watch_assets_ref = uid("fileref.watch.assets")
watch_assets_build = uid("buildfile.watch.assets")
watch_resources_phase = uid("phase.watch.resources")
control_prod_ref = uid("product.controls")
control_target = uid("target.controls")
control_sources_phase = uid("phase.control.sources")
control_frameworks_phase = uid("phase.control.frameworks")
control_cfg_list = uid("cfglist.controls")
control_proxy = uid("containerproxy.controls")
control_dep = uid("targetdep.controls")
control_embed_phase = uid("phase.app.embedextensions")
control_embed_build = uid("build.embed.controls")
control_group = uid("group.controls")
control_plist_ref = uid("fileref.control.plist")
test_prod_ref = uid("product.tests")
uitest_prod_ref = uid("product.uitests")
main_group = uid("group.main")
products_group = uid("group.Products")
config_group = uid("group.Config")
resources_group = uid("group.Resources")
app_target = uid("target.app")
test_target = uid("target.tests")
uitest_target = uid("target.uitests")
project_uid = uid("project")
sources_phase = uid("phase.sources")
resources_phase = uid("phase.resources")
frameworks_phase = uid("phase.frameworks")
test_sources_phase = uid("phase.test.sources")
test_frameworks_phase = uid("phase.test.frameworks")
test_resources_phase = uid("phase.test.resources")
uitest_sources_phase = uid("phase.uitest.sources")
uitest_frameworks_phase = uid("phase.uitest.frameworks")
proj_cfg_list = uid("cfglist.project")
app_cfg_list = uid("cfglist.app")
test_cfg_list = uid("cfglist.tests")
uitest_cfg_list = uid("cfglist.uitests")
test_proxy = uid("containerproxy.tests")
uitest_proxy = uid("containerproxy.uitests")
test_dep = uid("targetdep.tests")
uitest_dep = uid("targetdep.uitests")

xcconfig_refs = {f: fileref("Config/" + f) for f in XCCONFIGS}
app_build = {f: uid("buildfile.app." + f) for f in app_files}
test_build = {f: uid("buildfile.tests." + f) for f in test_files}
uitest_build = {f: uid("buildfile.uitests." + f) for f in uitest_files}
control_build = {f: uid("buildfile.controls." + f) for f in control_files}
watch_build = {f: uid("buildfile.watch." + f) for f in watch_files}
resource_build = {path: uid("buildfile.resource." + path) for path, _ in RESOURCE_FILES}
storekit_test_build = uid("buildfile.tests.storekit")

pkg_refs, product_deps, product_build_files = {}, {}, {}
for name, url, version, products in SPM_PACKAGES:
    pkg_refs[name] = uid("pkgref." + name)
    for prod in products:
        product_deps[prod] = uid("proddep." + prod)
        product_build_files[prod] = uid("buildfile.product." + prod)

# ================================================================================
L("// !$*UTF8*$!")
L("{")
L("\tarchiveVersion = 1;")
L("\tclasses = {")
L("\t};")
L("\tobjectVersion = 56;")
L("\tobjects = {")

L("\n/* Begin PBXBuildFile section */")
for f in app_files:
    L(f'\t\t{app_build[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref(f)} /* {os.path.basename(f)} */; }};')
for f in test_files:
    L(f'\t\t{test_build[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref(f)} /* {os.path.basename(f)} */; }};')
for f in uitest_files:
    L(f'\t\t{uitest_build[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref(f)} /* {os.path.basename(f)} */; }};')
for f in control_files:
    L(f'\t\t{control_build[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref(f)} /* {os.path.basename(f)} */; }};')
for f in watch_files:
    L(f'\t\t{watch_build[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref(f)} /* {os.path.basename(f)} */; }};')
L(f'\t\t{watch_assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {watch_assets_ref} /* Assets.xcassets */; }};')
L(f'\t\t{watch_embed_build} /* {WATCH_TARGET}.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {watch_prod_ref} /* {WATCH_TARGET}.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
L(f'\t\t{control_embed_build} /* {CONTROL_TARGET}.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {control_prod_ref} /* {CONTROL_TARGET}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
for path, _ in RESOURCE_FILES:
    base = os.path.basename(path)
    L(f'\t\t{resource_build[path]} /* {base} in Resources */ = {{isa = PBXBuildFile; fileRef = {fileref(path)} /* {base} */; }};')
L(f'\t\t{storekit_test_build} /* {os.path.basename(STOREKIT_FILE)} in Resources */ = {{isa = PBXBuildFile; fileRef = {fileref(STOREKIT_FILE)} /* {os.path.basename(STOREKIT_FILE)} */; }};')
for prod, bf in product_build_files.items():
    L(f'\t\t{bf} /* {prod} in Frameworks */ = {{isa = PBXBuildFile; productRef = {product_deps[prod]} /* {prod} */; }};')
L("/* End PBXBuildFile section */")

L("\n/* Begin PBXFileReference section */")
L(f'\t\t{prod_ref} /* {PROJ}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{PROJ}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
L(f'\t\t{watch_prod_ref} /* {WATCH_TARGET}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{WATCH_TARGET}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
L(f'\t\t{watch_plist_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
L(f'\t\t{watch_assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
for f in find_swift(WATCH_SOURCE_DIR):
    L(f'\t\t{fileref(f)} /* {os.path.basename(f)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{os.path.basename(f)}"; sourceTree = "<group>"; }};')
L(f'\t\t{control_prod_ref} /* {CONTROL_TARGET}.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = "{CONTROL_TARGET}.appex"; sourceTree = BUILT_PRODUCTS_DIR; }};')
L(f'\t\t{control_plist_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
# The extension's own sources are not under any app source directory, so nothing else
# emits their file references. A reference listed in a group but never defined is not an
# error in Xcode: the file is quietly dropped from the target, which is how the widget
# bundle came to be missing from a binary that still built and linked.
for f in find_swift(CONTROL_SOURCE_DIR):
    L(f'\t\t{fileref(f)} /* {os.path.basename(f)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{os.path.basename(f)}"; sourceTree = "<group>"; }};')
L(f'\t\t{test_prod_ref} /* {PROJ}Tests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{PROJ}Tests.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};')
L(f'\t\t{uitest_prod_ref} /* {PROJ}UITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{PROJ}UITests.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};')
for f in sorted(set(app_files + test_files + uitest_files)):
    base = os.path.basename(f)
    L(f'\t\t{fileref(f)} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{base}"; sourceTree = "<group>"; }};')
for path, kind in RESOURCE_FILES:
    base = os.path.basename(path)
    L(f'\t\t{fileref(path)} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {base}; sourceTree = "<group>"; }};')
L(f'\t\t{fileref(STOREKIT_FILE)} /* {os.path.basename(STOREKIT_FILE)} */ = {{isa = PBXFileReference; lastKnownFileType = text; path = {os.path.basename(STOREKIT_FILE)}; sourceTree = "<group>"; }};')
L(f'\t\t{fileref(INFO_PLIST)} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
L(f'\t\t{fileref(ENTITLEMENTS)} /* {PROJ}.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {PROJ}.entitlements; sourceTree = "<group>"; }};')
for f in XCCONFIGS:
    L(f'\t\t{xcconfig_refs[f]} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = {f}; sourceTree = "<group>"; }};')
L("/* End PBXFileReference section */")

L("\n/* Begin PBXFrameworksBuildPhase section */")
for phase in [frameworks_phase, test_frameworks_phase, uitest_frameworks_phase, control_frameworks_phase, watch_frameworks_phase]:
    L(f"\t\t{phase} /* Frameworks */ = {{")
    L("\t\t\tisa = PBXFrameworksBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = (")
    if phase == frameworks_phase:
        for prod, bf in product_build_files.items():
            L(f"\t\t\t\t{bf} /* {prod} in Frameworks */,")
    L("\t\t\t);")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
L("/* End PBXFrameworksBuildPhase section */")

L("\n/* Begin PBXGroup section */")
top_groups = {}
for d in APP_SOURCE_DIRS:
    top_groups[d] = emit_top_group(d, app_files)
# Info.plist and the entitlements live in App/, folded into that same group so their
# paths resolve relative to it.
L(f"\t\t{watch_group} /* {WATCH_SOURCE_DIR} */ = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
for f in find_swift(WATCH_SOURCE_DIR):
    L(f"\t\t\t\t{fileref(f)} /* {os.path.basename(f)} */,")
L(f"\t\t\t\t{watch_assets_ref} /* Assets.xcassets */,")
L(f"\t\t\t\t{watch_plist_ref} /* Info.plist */,")
L("\t\t\t);")
L(f"\t\t\tpath = {WATCH_SOURCE_DIR};")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")

control_swift = find_swift(CONTROL_SOURCE_DIR)
L(f"\t\t{control_group} /* {CONTROL_SOURCE_DIR} */ = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
for f in control_swift:
    L(f"\t\t\t\t{fileref(f)} /* {os.path.basename(f)} */,")
L(f"\t\t\t\t{control_plist_ref} /* Info.plist */,")
L("\t\t\t);")
L(f"\t\t\tpath = {CONTROL_SOURCE_DIR};")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")

test_group = emit_top_group(TEST_SOURCE_DIR, test_files)
uitest_group = emit_top_group(UITEST_SOURCE_DIR, uitest_files)

L(f"\t\t{resources_group} /* Resources */ = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
for path, _ in RESOURCE_FILES:
    L(f"\t\t\t\t{fileref(path)} /* {os.path.basename(path)} */,")
L(f"\t\t\t\t{fileref(STOREKIT_FILE)} /* {os.path.basename(STOREKIT_FILE)} */,")
L("\t\t\t);")
L(f"\t\t\tpath = {RESOURCES_DIR};")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")

L(f"\t\t{config_group} /* Config */ = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
for f in XCCONFIGS:
    L(f"\t\t\t\t{xcconfig_refs[f]} /* {f} */,")
L("\t\t\t);")
L("\t\t\tpath = Config;")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")

L(f"\t\t{products_group} /* Products */ = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
L(f"\t\t\t\t{prod_ref} /* {PROJ}.app */,")
L(f"\t\t\t\t{control_prod_ref} /* {CONTROL_TARGET}.appex */,")
L(f"\t\t\t\t{watch_prod_ref} /* {WATCH_TARGET}.app */,")
L(f"\t\t\t\t{test_prod_ref} /* {PROJ}Tests.xctest */,")
L(f"\t\t\t\t{uitest_prod_ref} /* {PROJ}UITests.xctest */,")
L("\t\t\t);")
L("\t\t\tname = Products;")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")

L(f"\t\t{main_group} = {{")
L("\t\t\tisa = PBXGroup;")
L("\t\t\tchildren = (")
for d in APP_SOURCE_DIRS:
    L(f"\t\t\t\t{top_groups[d]} /* {d} */,")
L(f"\t\t\t\t{resources_group} /* Resources */,")
L(f"\t\t\t\t{config_group} /* Config */,")
L(f"\t\t\t\t{control_group} /* {CONTROL_SOURCE_DIR} */,")
L(f"\t\t\t\t{watch_group} /* {WATCH_SOURCE_DIR} */,")
L(f"\t\t\t\t{test_group} /* Tests */,")
L(f"\t\t\t\t{uitest_group} /* UITests */,")
L(f"\t\t\t\t{products_group} /* Products */,")
L("\t\t\t);")
L('\t\t\tsourceTree = "<group>";')
L("\t\t};")
L("/* End PBXGroup section */")

L("\n/* Begin PBXNativeTarget section */")
L(f"\t\t{app_target} /* {PROJ} */ = {{")
L("\t\t\tisa = PBXNativeTarget;")
L(f'\t\t\tbuildConfigurationList = {app_cfg_list} /* Build configuration list for PBXNativeTarget "{PROJ}" */;')
L("\t\t\tbuildPhases = (")
L(f"\t\t\t\t{sources_phase} /* Sources */,")
L(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
L(f"\t\t\t\t{resources_phase} /* Resources */,")
L(f"\t\t\t\t{control_embed_phase} /* Embed Foundation Extensions */,")
L(f"\t\t\t\t{watch_embed_phase} /* Embed Watch Content */,")
L("\t\t\t);")
L("\t\t\tbuildRules = (")
L("\t\t\t);")
L("\t\t\tdependencies = (")
L(f"\t\t\t\t{control_dep} /* PBXTargetDependency */,")
L(f"\t\t\t\t{watch_dep} /* PBXTargetDependency */,")
L("\t\t\t);")
L(f"\t\t\tname = {PROJ};")
L("\t\t\tpackageProductDependencies = (")
for prod, dep in product_deps.items():
    L(f"\t\t\t\t{dep} /* {prod} */,")
L("\t\t\t);")
L(f"\t\t\tproductName = {PROJ};")
L(f"\t\t\tproductReference = {prod_ref} /* {PROJ}.app */;")
L('\t\t\tproductType = "com.apple.product-type.application";')
L("\t\t};")

for name, target, cfg, sphase, fphase, dep, prod, ptype in [
    (f"{PROJ}Tests", test_target, test_cfg_list, test_sources_phase, test_frameworks_phase, test_dep, test_prod_ref, "com.apple.product-type.bundle.unit-test"),
    (f"{PROJ}UITests", uitest_target, uitest_cfg_list, uitest_sources_phase, uitest_frameworks_phase, uitest_dep, uitest_prod_ref, "com.apple.product-type.bundle.ui-testing"),
]:
    L(f"\t\t{target} /* {name} */ = {{")
    L("\t\t\tisa = PBXNativeTarget;")
    L(f'\t\t\tbuildConfigurationList = {cfg} /* Build configuration list for PBXNativeTarget "{name}" */;')
    L("\t\t\tbuildPhases = (")
    L(f"\t\t\t\t{sphase} /* Sources */,")
    L(f"\t\t\t\t{fphase} /* Frameworks */,")
    if target == test_target:
        L(f"\t\t\t\t{test_resources_phase} /* Resources */,")
    L("\t\t\t);")
    L("\t\t\tbuildRules = (")
    L("\t\t\t);")
    L("\t\t\tdependencies = (")
    L(f"\t\t\t\t{dep} /* PBXTargetDependency */,")
    L("\t\t\t);")
    L(f"\t\t\tname = {name};")
    L(f"\t\t\tproductName = {name};")
    L(f"\t\t\tproductReference = {prod} /* {name}.xctest */;")
    L(f'\t\t\tproductType = "{ptype}";')
    L("\t\t};")
L(f"\t\t{control_target} /* {CONTROL_TARGET} */ = {{")
L("\t\t\tisa = PBXNativeTarget;")
L(f'\t\t\tbuildConfigurationList = {control_cfg_list} /* Build configuration list for PBXNativeTarget "{CONTROL_TARGET}" */;')
L("\t\t\tbuildPhases = (")
L(f"\t\t\t\t{control_sources_phase} /* Sources */,")
L(f"\t\t\t\t{control_frameworks_phase} /* Frameworks */,")
L("\t\t\t);")
L("\t\t\tbuildRules = (")
L("\t\t\t);")
L("\t\t\tdependencies = (")
L("\t\t\t);")
L(f"\t\t\tname = {CONTROL_TARGET};")
L(f"\t\t\tproductName = {CONTROL_TARGET};")
L(f"\t\t\tproductReference = {control_prod_ref} /* {CONTROL_TARGET}.appex */;")
L('\t\t\tproductType = "com.apple.product-type.app-extension";')
L("\t\t};")
L(f"\t\t{watch_target} /* {WATCH_TARGET} */ = {{")
L("\t\t\tisa = PBXNativeTarget;")
L(f'\t\t\tbuildConfigurationList = {watch_cfg_list} /* Build configuration list for PBXNativeTarget "{WATCH_TARGET}" */;')
L("\t\t\tbuildPhases = (")
L(f"\t\t\t\t{watch_sources_phase} /* Sources */,")
L(f"\t\t\t\t{watch_frameworks_phase} /* Frameworks */,")
L(f"\t\t\t\t{watch_resources_phase} /* Resources */,")
L("\t\t\t);")
L("\t\t\tbuildRules = (")
L("\t\t\t);")
L("\t\t\tdependencies = (")
L("\t\t\t);")
L(f"\t\t\tname = {WATCH_TARGET};")
L(f"\t\t\tproductName = {WATCH_TARGET};")
L(f"\t\t\tproductReference = {watch_prod_ref} /* {WATCH_TARGET}.app */;")
L('\t\t\tproductType = "com.apple.product-type.application";')
L("\t\t};")
L("/* End PBXNativeTarget section */")

L("\n/* Begin PBXProject section */")
L(f"\t\t{project_uid} /* Project object */ = {{")
L("\t\t\tisa = PBXProject;")
L("\t\t\tattributes = {")
L("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
L("\t\t\t\tLastSwiftUpdateCheck = 1620;")
L("\t\t\t\tLastUpgradeCheck = 1620;")
L("\t\t\t\tTargetAttributes = {")
L(f"\t\t\t\t\t{app_target} = {{")
L("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
L("\t\t\t\t\t};")
L(f"\t\t\t\t\t{control_target} = {{")
L("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
L("\t\t\t\t\t};")
L(f"\t\t\t\t\t{watch_target} = {{")
L("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
L("\t\t\t\t\t};")
for t in (test_target, uitest_target):
    L(f"\t\t\t\t\t{t} = {{")
    L("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
    L(f"\t\t\t\t\t\tTestTargetID = {app_target};")
    L("\t\t\t\t\t};")
L("\t\t\t\t};")
L("\t\t\t};")
L(f'\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject "{PROJ}" */;')
L('\t\t\tcompatibilityVersion = "Xcode 14.0";')
L("\t\t\tdevelopmentRegion = en;")
L("\t\t\thasScannedForEncodings = 0;")
L("\t\t\tknownRegions = (")
for region in KNOWN_REGIONS:
    L(f"\t\t\t\t{region},")
L("\t\t\t);")
L(f"\t\t\tmainGroup = {main_group};")
L("\t\t\tpackageReferences = (")
for name in pkg_refs:
    L(f'\t\t\t\t{pkg_refs[name]} /* XCRemoteSwiftPackageReference "{name}" */,')
L("\t\t\t);")
L(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
L('\t\t\tprojectDirPath = "";')
L('\t\t\tprojectRoot = "";')
L("\t\t\ttargets = (")
L(f"\t\t\t\t{app_target} /* {PROJ} */,")
L(f"\t\t\t\t{control_target} /* {CONTROL_TARGET} */,")
L(f"\t\t\t\t{watch_target} /* {WATCH_TARGET} */,")
L(f"\t\t\t\t{test_target} /* {PROJ}Tests */,")
L(f"\t\t\t\t{uitest_target} /* {PROJ}UITests */,")
L("\t\t\t);")
L("\t\t};")
L("/* End PBXProject section */")

L("\n/* Begin PBXContainerItemProxy section */")
for proxy in (test_proxy, uitest_proxy):
    L(f"\t\t{proxy} /* PBXContainerItemProxy */ = {{")
    L("\t\t\tisa = PBXContainerItemProxy;")
    L(f"\t\t\tcontainerPortal = {project_uid} /* Project object */;")
    L("\t\t\tproxyType = 1;")
    L(f"\t\t\tremoteGlobalIDString = {app_target};")
    L(f"\t\t\tremoteInfo = {PROJ};")
    L("\t\t};")
L(f"\t\t{control_proxy} /* PBXContainerItemProxy */ = {{")
L("\t\t\tisa = PBXContainerItemProxy;")
L(f"\t\t\tcontainerPortal = {project_uid} /* Project object */;")
L("\t\t\tproxyType = 1;")
L(f"\t\t\tremoteGlobalIDString = {control_target};")
L(f"\t\t\tremoteInfo = {CONTROL_TARGET};")
L("\t\t};")
L(f"\t\t{watch_proxy} /* PBXContainerItemProxy */ = {{")
L("\t\t\tisa = PBXContainerItemProxy;")
L(f"\t\t\tcontainerPortal = {project_uid} /* Project object */;")
L("\t\t\tproxyType = 1;")
L(f"\t\t\tremoteGlobalIDString = {watch_target};")
L(f"\t\t\tremoteInfo = {WATCH_TARGET};")
L("\t\t};")
L("/* End PBXContainerItemProxy section */")

L("\n/* Begin PBXTargetDependency section */")
for dep, proxy in ((test_dep, test_proxy), (uitest_dep, uitest_proxy)):
    L(f"\t\t{dep} /* PBXTargetDependency */ = {{")
    L("\t\t\tisa = PBXTargetDependency;")
    L(f"\t\t\ttarget = {app_target} /* {PROJ} */;")
    L(f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;")
    L("\t\t};")
L(f"\t\t{control_dep} /* PBXTargetDependency */ = {{")
L("\t\t\tisa = PBXTargetDependency;")
L(f"\t\t\ttarget = {control_target} /* {CONTROL_TARGET} */;")
L(f"\t\t\ttargetProxy = {control_proxy} /* PBXContainerItemProxy */;")
L("\t\t};")
L(f"\t\t{watch_dep} /* PBXTargetDependency */ = {{")
L("\t\t\tisa = PBXTargetDependency;")
L(f"\t\t\ttarget = {watch_target} /* {WATCH_TARGET} */;")
L(f"\t\t\ttargetProxy = {watch_proxy} /* PBXContainerItemProxy */;")
L("\t\t};")
L("/* End PBXTargetDependency section */")

if SPM_PACKAGES:
    L("\n/* Begin XCRemoteSwiftPackageReference section */")
    for name, url, version, products in SPM_PACKAGES:
        L(f'\t\t{pkg_refs[name]} /* XCRemoteSwiftPackageReference "{name}" */ = {{')
        L("\t\t\tisa = XCRemoteSwiftPackageReference;")
        L(f'\t\t\trepositoryURL = "{url}";')
        L("\t\t\trequirement = {")
        L("\t\t\t\tkind = exactVersion;")
        L(f"\t\t\t\tversion = {version};")
        L("\t\t\t};")
        L("\t\t};")
    L("/* End XCRemoteSwiftPackageReference section */")

    L("\n/* Begin XCSwiftPackageProductDependency section */")
    for name, url, version, products in SPM_PACKAGES:
        for prod in products:
            L(f"\t\t{product_deps[prod]} /* {prod} */ = {{")
            L("\t\t\tisa = XCSwiftPackageProductDependency;")
            L(f'\t\t\tpackage = {pkg_refs[name]} /* XCRemoteSwiftPackageReference "{name}" */;')
            L(f"\t\t\tproductName = {prod};")
            L("\t\t};")
    L("/* End XCSwiftPackageProductDependency section */")

L("\n/* Begin PBXResourcesBuildPhase section */")
L(f"\t\t{resources_phase} /* Resources */ = {{")
L("\t\t\tisa = PBXResourcesBuildPhase;")
L("\t\t\tbuildActionMask = 2147483647;")
L("\t\t\tfiles = (")
for path, _ in RESOURCE_FILES:
    L(f"\t\t\t\t{resource_build[path]} /* {os.path.basename(path)} in Resources */,")
L("\t\t\t);")
L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
L("\t\t};")
L(f"\t\t{watch_resources_phase} /* Resources */ = {{")
L("\t\t\tisa = PBXResourcesBuildPhase;")
L("\t\t\tbuildActionMask = 2147483647;")
L("\t\t\tfiles = (")
L(f"\t\t\t\t{watch_assets_build} /* Assets.xcassets in Resources */,")
L("\t\t\t);")
L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
L("\t\t};")
L(f"\t\t{test_resources_phase} /* Resources */ = {{")
L("\t\t\tisa = PBXResourcesBuildPhase;")
L("\t\t\tbuildActionMask = 2147483647;")
L("\t\t\tfiles = (")
L(f"\t\t\t\t{storekit_test_build} /* {os.path.basename(STOREKIT_FILE)} in Resources */,")
L("\t\t\t);")
L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
L("\t\t};")
L("/* End PBXResourcesBuildPhase section */")

L("\n/* Begin PBXCopyFilesBuildPhase section */")
L(f"\t\t{control_embed_phase} /* Embed Foundation Extensions */ = {{")
L("\t\t\tisa = PBXCopyFilesBuildPhase;")
L("\t\t\tbuildActionMask = 2147483647;")
L('\t\t\tdstPath = "";')
L("\t\t\tdstSubfolderSpec = 13;")
L("\t\t\tfiles = (")
L(f"\t\t\t\t{control_embed_build} /* {CONTROL_TARGET}.appex in Embed Foundation Extensions */,")
L("\t\t\t);")
L('\t\t\tname = "Embed Foundation Extensions";')
L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
L("\t\t};")
L("/* End PBXCopyFilesBuildPhase section */")

L(f"\t\t{watch_embed_phase} /* Embed Watch Content */ = {{")
L("\t\t\tisa = PBXCopyFilesBuildPhase;")
L("\t\t\tbuildActionMask = 2147483647;")
L('\t\t\tdstPath = "$(CONTENTS_FOLDER_PATH)/Watch";')
L("\t\t\tdstSubfolderSpec = 16;")
L("\t\t\tfiles = (")
L(f"\t\t\t\t{watch_embed_build} /* {WATCH_TARGET}.app in Embed Watch Content */,")
L("\t\t\t);")
L('\t\t\tname = "Embed Watch Content";')
L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
L("\t\t};")

L("\n/* Begin PBXSourcesBuildPhase section */")
for phase, files, table in [
    (sources_phase, app_files, app_build),
    (test_sources_phase, test_files, test_build),
    (uitest_sources_phase, uitest_files, uitest_build),
    (control_sources_phase, control_files, control_build),
    (watch_sources_phase, watch_files, watch_build),
]:
    L(f"\t\t{phase} /* Sources */ = {{")
    L("\t\t\tisa = PBXSourcesBuildPhase;")
    L("\t\t\tbuildActionMask = 2147483647;")
    L("\t\t\tfiles = (")
    for f in files:
        L(f"\t\t\t\t{table[f]} /* {os.path.basename(f)} in Sources */,")
    L("\t\t\t);")
    L("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L("\t\t};")
L("/* End PBXSourcesBuildPhase section */")


def proj_common():
    return [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "GCC_NO_COMMON_BLOCKS = YES;",
        "MTL_FAST_MATH = YES;",
        "SDKROOT = iphoneos;",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
    ]


def app_common():
    return [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        f'CODE_SIGN_ENTITLEMENTS = "{ENTITLEMENTS}";',
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f'INFOPLIST_FILE = "{INFO_PLIST}";',
        'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");',
        f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID_VAR}";',
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        'TARGETED_DEVICE_FAMILY = "1";',
    ]


def test_common():
    return [
        'BUNDLE_LOADER = "$(TEST_HOST)";',
        "GENERATE_INFOPLIST_FILE = YES;",
        'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");',
        f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID_VAR}.tests";',
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        'TARGETED_DEVICE_FAMILY = "1";',
        f'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/{PROJ}.app/{PROJ}";',
    ]


def uitest_common():
    return [
        "GENERATE_INFOPLIST_FILE = YES;",
        'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");',
        f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID_VAR}.uitests";',
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        'TARGETED_DEVICE_FAMILY = "1";',
        f"TEST_TARGET_NAME = {PROJ};",
    ]


def control_common():
    return [
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f'INFOPLIST_FILE = "{CONTROL_INFO_PLIST}";',
        "INFOPLIST_KEY_CFBundleDisplayName = \"Dashcam Controls\";",
        # Controls are an iOS 18 feature. The app itself still runs on 17: the extension
        # simply is not installed on anything older.
        "IPHONEOS_DEPLOYMENT_TARGET = 18.0;",
        'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");',
        f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID_VAR}.controls";',
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        "SKIP_INSTALL = YES;",
        'TARGETED_DEVICE_FAMILY = "1";',
    ]


def watch_common():
    return [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f'INFOPLIST_FILE = "{WATCH_INFO_PLIST}";',
        # The watch app is a companion: it carries no code signing identity of its own
        # beyond the team's, and its bundle id has to sit under the phone's.
        f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID_VAR}.watchkitapp";',
        'PRODUCT_NAME = "$(TARGET_NAME)";',
        "SDKROOT = watchos;",
        "SKIP_INSTALL = YES;",
        'SUPPORTED_PLATFORMS = "watchsimulator watchos";',
        "TARGETED_DEVICE_FAMILY = 4;",
        "WATCHOS_DEPLOYMENT_TARGET = 10.0;",
    ]


L("\n/* Begin XCBuildConfiguration section */")
for env, xcconfig in ENVIRONMENTS:
    cfg = uid("cfg.proj." + env)
    L(f"\t\t{cfg} /* {env} */ = {{")
    L("\t\t\tisa = XCBuildConfiguration;")
    L(f"\t\t\tbaseConfigurationReference = {xcconfig_refs[xcconfig]} /* {xcconfig} */;")
    L("\t\t\tbuildSettings = {")
    for s in proj_common():
        L("\t\t\t\t" + s)
    if env == "Debug":
        L("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
        L("\t\t\t\tENABLE_TESTABILITY = YES;")
        L("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
        L('\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)");')
        L("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
        L('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";')
        L('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
    else:
        L('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
        L("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
        L("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    L("\t\t\t};")
    L(f"\t\t\tname = {env};")
    L("\t\t};")

for prefix, settings in [
    ("cfg.app.", app_common()),
    ("cfg.controls.", control_common()),
    ("cfg.watch.", watch_common()),
    ("cfg.tests.", test_common()),
    ("cfg.uitests.", uitest_common()),
]:
    for env, _ in ENVIRONMENTS:
        cfg = uid(prefix + env)
        L(f"\t\t{cfg} /* {env} */ = {{")
        L("\t\t\tisa = XCBuildConfiguration;")
        L("\t\t\tbuildSettings = {")
        for s in settings:
            L("\t\t\t\t" + s)
        L("\t\t\t};")
        L(f"\t\t\tname = {env};")
        L("\t\t};")
L("/* End XCBuildConfiguration section */")

L("\n/* Begin XCConfigurationList section */")


def emit_cfg_list(list_uid, comment, prefix):
    L(f"\t\t{list_uid} /* {comment} */ = {{")
    L("\t\t\tisa = XCConfigurationList;")
    L("\t\t\tbuildConfigurations = (")
    for env, _ in ENVIRONMENTS:
        L(f"\t\t\t\t{uid(prefix + env)} /* {env} */,")
    L("\t\t\t);")
    L("\t\t\tdefaultConfigurationIsVisible = 0;")
    L("\t\t\tdefaultConfigurationName = Release;")
    L("\t\t};")


emit_cfg_list(proj_cfg_list, f'Build configuration list for PBXProject "{PROJ}"', "cfg.proj.")
emit_cfg_list(app_cfg_list, f'Build configuration list for PBXNativeTarget "{PROJ}"', "cfg.app.")
emit_cfg_list(control_cfg_list, f'Build configuration list for PBXNativeTarget "{CONTROL_TARGET}"', "cfg.controls.")
emit_cfg_list(watch_cfg_list, f'Build configuration list for PBXNativeTarget "{WATCH_TARGET}"', "cfg.watch.")
emit_cfg_list(test_cfg_list, f'Build configuration list for PBXNativeTarget "{PROJ}Tests"', "cfg.tests.")
emit_cfg_list(uitest_cfg_list, f'Build configuration list for PBXNativeTarget "{PROJ}UITests"', "cfg.uitests.")
L("/* End XCConfigurationList section */")

L("\t};")
L(f"\trootObject = {project_uid} /* Project object */;")
L("}")

out_dir = os.path.join(ROOT, f"{PROJ}.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "project.pbxproj"), "w") as fh:
    fh.write("\n".join(lines) + "\n")


# ---- Shared scheme ----------------------------------------------------------
# A project generated from source has no scheme until Xcode opens it once, so headless
# `xcodebuild -scheme Dashcam` needs this written explicitly. It also carries the
# StoreKit configuration reference, which is what makes the paywall testable locally.
def buildable_ref(blueprint, name):
    return (
        "            <BuildableReference\n"
        '               BuildableIdentifier = "primary"\n'
        f'               BlueprintIdentifier = "{blueprint}"\n'
        f'               BuildableName = "{name}"\n'
        f'               BlueprintName = "{name.rsplit(".", 1)[0]}"\n'
        f'               ReferencedContainer = "container:{PROJ}.xcodeproj">\n'
        "            </BuildableReference>\n"
    )


scheme = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Scheme LastUpgradeVersion = "1620" version = "1.7">\n'
    '   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">\n'
    "      <BuildActionEntries>\n"
    '         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">\n'
    + buildable_ref(app_target, PROJ + ".app")
    + "         </BuildActionEntry>\n"
    '         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">\n'
    + buildable_ref(test_target, PROJ + "Tests.xctest")
    + "         </BuildActionEntry>\n"
    '         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">\n'
    + buildable_ref(uitest_target, PROJ + "UITests.xctest")
    + "         </BuildActionEntry>\n"
    "      </BuildActionEntries>\n"
    "   </BuildAction>\n"
    '   <TestAction\n'
    '      buildConfiguration = "Debug"\n'
    '      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
    '      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
    '      shouldUseLaunchSchemeArgsEnv = "YES">\n'
    f'      <StoreKitConfigurationFileReference identifier = "../../../{STOREKIT_FILE}">\n'
    "      </StoreKitConfigurationFileReference>\n"
    "      <Testables>\n"
    '         <TestableReference skipped = "NO">\n'
    + buildable_ref(test_target, PROJ + "Tests.xctest")
    + "         </TestableReference>\n"
    '         <TestableReference skipped = "NO">\n'
    + buildable_ref(uitest_target, PROJ + "UITests.xctest")
    + "         </TestableReference>\n"
    "      </Testables>\n"
    "   </TestAction>\n"
    "   <LaunchAction\n"
    '      buildConfiguration = "Debug"\n'
    '      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
    '      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
    '      launchStyle = "0"\n'
    '      useCustomWorkingDirectory = "NO"\n'
    '      ignoresPersistentStateOnLaunch = "NO"\n'
    '      debugDocumentVersioning = "YES"\n'
    '      debugServiceExtension = "internal"\n'
    '      allowLocationSimulation = "YES">\n'
    f'      <StoreKitConfigurationFileReference identifier = "../../../{STOREKIT_FILE}">\n'
    "      </StoreKitConfigurationFileReference>\n"
    '      <BuildableProductRunnable runnableDebuggingMode = "0">\n'
    + buildable_ref(app_target, PROJ + ".app")
    + "      </BuildableProductRunnable>\n"
    "   </LaunchAction>\n"
    '   <ArchiveAction\n'
    '      buildConfiguration = "Release"\n'
    '      revealArchiveInOrganizer = "YES">\n'
    "   </ArchiveAction>\n"
    "</Scheme>\n"
)

scheme_dir = os.path.join(out_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
with open(os.path.join(scheme_dir, f"{PROJ}.xcscheme"), "w") as fh:
    fh.write(scheme)

print(f"Wrote {out_dir}/project.pbxproj — app: {len(app_files)}, tests: {len(test_files)}, uitests: {len(uitest_files)}")
