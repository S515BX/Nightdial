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

# Holiday decoration glyphs (vector, tinted in code)
GLYPHS = {
    "snow": '<g fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round"><path d="M12 2.5v19M3.8 7.25l16.4 9.5M3.8 16.75l16.4-9.5"/><path d="M9.6 4.2L12 6.4l2.4-2.2M9.6 19.8L12 17.6l2.4 2.2M4.4 10.3l3.1-.9-.7-3.2M19.6 13.7l-3.1.9.7 3.2M6.8 17.8l.7-3.2-3.1-.9M17.2 6.2l-.7 3.2 3.1.9"/></g>',
    "bat": '<path d="M12 9.6c.5-.9.9-1.5 1.3-1.5l.4 1.3c1.8-1 4.1-1.8 7.1-1.6-1 .8-1.5 2-1.4 3.3-1.2-.6-2.5-.5-3.3.4-.7-.6-1.5-.7-2.2-.1L12 14.2l-1.9-2.8c-.7-.6-1.5-.5-2.2.1-.8-.9-2.1-1-3.3-.4.1-1.3-.4-2.5-1.4-3.3 3-.2 5.3.6 7.1 1.6l.4-1.3c.4 0 .8.6 1.3 1.5z"/>',
    "pumpkin": '<path d="M12 7.4c-1.2-.9-3.1-1.2-4.8-.5-2.8 1.1-3.7 4.1-3 7.2.7 3.1 3 5.2 5.6 5.2.8 0 1.5-.2 2.2-.6.7.4 1.4.6 2.2.6 2.6 0 4.9-2.1 5.6-5.2.7-3.1-.2-6.1-3-7.2-1.7-.7-3.6-.4-4.8.5z"/><path d="M11.3 7.2c-.1-1.7.5-3.1 1.8-4l1 1c-1 .7-1.4 1.7-1.3 3z"/>',
    "leaf": '<path d="M12 2.5l1.6 3.5 3-1-.9 3.8 3.8-.6-2 3.2 3 1.5-3.5 1.4.8 3-3.4-1.3L13 21.5h-2l-1.4-5.5-3.4 1.3.8-3-3.5-1.4 3-1.5-2-3.2 3.8.6-.9-3.8 3 1z"/>',
    "heart": '<path d="M12 20.5s-7.5-4.6-7.5-10.1A4.3 4.3 0 0 1 12 7.6a4.3 4.3 0 0 1 7.5 2.8c0 5.5-7.5 10.1-7.5 10.1z"/>',
    "clover": '<circle cx="12" cy="7.3" r="3.6"/><circle cx="7.5" cy="11.8" r="3.6"/><circle cx="16.5" cy="11.8" r="3.6"/><circle cx="12" cy="11.6" r="2.6"/><path d="M12.2 13.6c.3 3 1.3 5.4 3 7.4" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round"/>',
    "flower": '<circle cx="12" cy="6.6" r="3.3"/><circle cx="17.1" cy="10.4" r="3.3"/><circle cx="15.2" cy="16.4" r="3.3"/><circle cx="8.8" cy="16.4" r="3.3"/><circle cx="6.9" cy="10.4" r="3.3"/>',
    "star": '<path d="M12 2.8l2.7 5.6 6.1.8-4.5 4.2 1.1 6-5.4-2.9-5.4 2.9 1.1-6-4.5-4.2 6.1-.8z"/>',
    "spark": '<path d="M12 2c.8 5.6 4.4 9.2 10 10-5.6.8-9.2 4.4-10 10-.8-5.6-4.4-9.2-10-10 5.6-.8 9.2-4.4 10-10z"/>',
    "tree": '<path d="M12 2l4 5.2h-2l4.5 5.6h-2.3L21 19H3l4.8-6.2H5.5L10 7.2H8z"/><path d="M10.7 19h2.6v3h-2.6z"/>',
}
for name, body in GLYPHS.items():
    d = os.path.join(assets, "deco-" + name + ".imageset")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "deco-" + name + ".svg"), "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 24 24" fill="#000">{body}</svg>\n')
    jdump(os.path.join(d, "Contents.json"), {"images": [{"filename": "deco-" + name + ".svg", "idiom": "universal"}], "info": info,
                                             "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}})

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
