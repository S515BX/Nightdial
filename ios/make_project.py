#!/usr/bin/env python3
"""Generates the Xcode project (Tuner.xcodeproj, shown as Nightdial), the asset catalog, icon, fonts and glyphs, then checks the project file's structure."""
import json, os, re, shutil, sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "Tuner")
SWIFT = sorted(f for f in os.listdir(SRC) if f.endswith(".swift"))

counter = [0]
def gid():
    counter[0] += 1
    return "7C1A%020X" % counter[0]

ids = {k: gid() for k in ["project", "mainGroup", "appGroup", "productsGroup", "product", "target", "sources",
                          "frameworks", "resources", "projectList", "targetList", "projDebug", "projRelease",
                          "tgtDebug", "tgtRelease", "assetsRef", "assetsBuild", "plistRef"]}
files = [(f, gid(), gid()) for f in SWIFT]  # (name, fileRef, buildFile)

common_proj = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				SDKROOT = iphoneos;
"""
debug_proj = common_proj + """				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
"""
release_proj = common_proj + """				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				MTL_ENABLE_DEBUG_INFO = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
"""
target_settings = """				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = Tuner/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = Nightdial;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.entertainment";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UIUserInterfaceStyle = Dark;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "app.tuner.player.$(DEVELOPMENT_TEAM)";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

def cfg(id_, name, settings):
    return f"""		{id_} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings}			}};
			name = {name};
		}};
"""

out = []
w = out.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n")
w("/* Begin PBXBuildFile section */\n")
for name, ref, bf in files:
    w(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
w(f"\t\t{ids['assetsBuild']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['assetsRef']} /* Assets.xcassets */; }};\n")
w("/* End PBXBuildFile section */\n\n")

w("/* Begin PBXFileReference section */\n")
for name, ref, bf in files:
    w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{ids['assetsRef']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{ids['plistRef']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{ids['product']} /* Tuner.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Tuner.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w("/* End PBXFileReference section */\n\n")

w("/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{ids['frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n\n")

w("/* Begin PBXGroup section */\n")
w(f"\t\t{ids['mainGroup']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids['appGroup']} /* Tuner */,\n\t\t\t\t{ids['productsGroup']} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{ids['appGroup']} /* Tuner */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
for name, ref, bf in files:
    w(f"\t\t\t\t{ref} /* {name} */,\n")
w(f"\t\t\t\t{ids['assetsRef']} /* Assets.xcassets */,\n\t\t\t\t{ids['plistRef']} /* Info.plist */,\n")
w("\t\t\t);\n\t\t\tpath = Tuner;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")
w(f"\t\t{ids['productsGroup']} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids['product']} /* Tuner.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXGroup section */\n\n")

w("/* Begin PBXNativeTarget section */\n")
w(f"""		{ids['target']} /* Tuner */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['targetList']} /* Build configuration list for PBXNativeTarget "Tuner" */;
			buildPhases = (
				{ids['sources']} /* Sources */,
				{ids['frameworks']} /* Frameworks */,
				{ids['resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Tuner;
			productName = Tuner;
			productReference = {ids['product']} /* Tuner.app */;
			productType = "com.apple.product-type.application";
		}};
""")
w("/* End PBXNativeTarget section */\n\n")

w("/* Begin PBXProject section */\n")
w(f"""		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{ids['target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {ids['projectList']} /* Build configuration list for PBXProject "Tuner" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {ids['mainGroup']};
			productRefGroup = {ids['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* Tuner */,
			);
		}};
""")
w("/* End PBXProject section */\n\n")

w("/* Begin PBXResourcesBuildPhase section */\n")
w(f"\t\t{ids['resources']} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{ids['assetsBuild']} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXResourcesBuildPhase section */\n\n")

w("/* Begin PBXSourcesBuildPhase section */\n")
w(f"\t\t{ids['sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
for name, ref, bf in files:
    w(f"\t\t\t\t{bf} /* {name} in Sources */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
w("/* End PBXSourcesBuildPhase section */\n\n")

w("/* Begin XCBuildConfiguration section */\n")
w(cfg(ids['projDebug'], "Debug", debug_proj))
w(cfg(ids['projRelease'], "Release", release_proj))
w(cfg(ids['tgtDebug'], "Debug", target_settings))
w(cfg(ids['tgtRelease'], "Release", target_settings))
w("/* End XCBuildConfiguration section */\n\n")

w("/* Begin XCConfigurationList section */\n")
for lid, kind, d, r in [(ids['projectList'], 'PBXProject', ids['projDebug'], ids['projRelease']),
                        (ids['targetList'], 'PBXNativeTarget', ids['tgtDebug'], ids['tgtRelease'])]:
    w(f"""		{lid} /* Build configuration list for {kind} "Tuner" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{d} /* Debug */,
				{r} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
""")
w("/* End XCConfigurationList section */\n")
w(f"\t}};\n\trootObject = {ids['project']} /* Project object */;\n}}\n")
pbx = "".join(out)

proj = os.path.join(ROOT, "Tuner.xcodeproj")
os.makedirs(os.path.join(proj, "project.xcworkspace"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write(pbx)
open(os.path.join(proj, "project.xcworkspace", "contents.xcworkspacedata"), "w").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')

# ---------- asset catalog ----------
assets = os.path.join(SRC, "Assets.xcassets")
def jdump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(json.dumps(obj, indent=2) + "\n")
info = {"author": "xcode", "version": 1}
jdump(os.path.join(assets, "Contents.json"), {"info": info})
def color(name, r, g, b):
    jdump(os.path.join(assets, f"{name}.colorset", "Contents.json"), {"colors": [{"color": {"color-space": "srgb", "components": {
        "alpha": "1.000", "red": f"{r/255:.3f}", "green": f"{g/255:.3f}", "blue": f"{b/255:.3f}"}}, "idiom": "universal"}], "info": info})
color("AccentColor", 0x5E, 0xE6, 0xC4)
color("LaunchBackground", 0x16, 0x19, 0x22)
jdump(os.path.join(assets, "AppIcon.appiconset", "Contents.json"),
      {"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": info})

# App icon: the Nightdial artwork rendered from brand/icon.svg (see brand/render.js). Keep the existing file if the render isn't here.
_icon = os.path.join(ROOT, "..", "brand", "out", "icon-1024-square.png")
if os.path.exists(_icon):
    shutil.copyfile(_icon, os.path.join(assets, "AppIcon.appiconset", "AppIcon.png"))

# Logo for the sidebar and sign-in screen
if os.path.exists(_icon):
    os.makedirs(os.path.join(assets, "Logo.imageset"), exist_ok=True)
    Image.open(_icon).convert("RGB").resize((256, 256), Image.LANCZOS).save(os.path.join(assets, "Logo.imageset", "Logo.png"))
    jdump(os.path.join(assets, "Logo.imageset", "Contents.json"), {"images": [{"filename": "Logo.png", "idiom": "universal"}], "info": info})

# Bundled fonts (Poppins, Outfit, Manrope, Nunito, Barlow Semi Condensed; SIL Open Font License) as data assets.
_fonts = os.path.join(ROOT, "..", "fonts", "subset")
if os.path.isdir(_fonts):
    for f in sorted(os.listdir(_fonts)):
        if not f.endswith(".ttf") or f.startswith("Barlow-"):
            continue
        name = f[:-4]
        d = os.path.join(assets, "font-" + name + ".dataset")
        os.makedirs(d, exist_ok=True)
        shutil.copyfile(os.path.join(_fonts, f), os.path.join(d, f))
        jdump(os.path.join(d, "Contents.json"), {"data": [{"filename": f, "idiom": "universal", "universal-type-identifier": "public.truetype-ttf-font"}], "info": info})

# Theme art from tuner/themes (generated by apply.js): particle glyphs (tinted in code) and scenery (full color), all vector.
_scenes = os.path.join(ROOT, "scenes")
if os.path.isdir(_scenes):
    for fn in sorted(os.listdir(_scenes)):
        if not fn.endswith(".svg"):
            continue
        name = fn[:-4]
        d = os.path.join(assets, name + ".imageset")
        os.makedirs(d, exist_ok=True)
        shutil.copyfile(os.path.join(_scenes, fn), os.path.join(d, fn))
        props = {"preserves-vector-representation": True}
        if name.startswith("deco-"):
            props["template-rendering-intent"] = "template"
        jdump(os.path.join(d, "Contents.json"), {"images": [{"filename": fn, "idiom": "universal"}], "info": info, "properties": props})

# ---------- structural check of project.pbxproj ----------
def check(text):
    depth = 0
    in_str = False
    i = 0
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\": i += 2; continue
            if c == '"': in_str = False
        elif text.startswith("/*", i):
            j = text.find("*/", i); assert j > 0, "unclosed comment"; i = j + 2; continue
        elif text.startswith("//", i):
            j = text.find("\n", i); i = j + 1; continue
        elif c == '"': in_str = True
        elif c in "{(": depth += 1
        elif c in "})": depth -= 1; assert depth >= 0, f"unbalanced at {i}"
        i += 1
    assert depth == 0 and not in_str, "unbalanced braces or strings"
    defined = set(re.findall(r"^\t\t([0-9A-F]{24}) .*?= \{", text, re.M))
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    missing = referenced - defined
    assert not missing, f"referenced but not defined: {missing}"
    for f in SWIFT:
        assert text.count(f"path = {f};") == 1, f"{f} file ref missing"
    return len(defined)

n = check(pbx)
print(f"project.pbxproj OK: {n} objects, {len(SWIFT)} Swift files: {', '.join(SWIFT)}")
