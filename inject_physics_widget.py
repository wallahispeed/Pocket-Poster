#!/usr/bin/env python3
"""
Patches 'Pocket Poster.xcodeproj/project.pbxproj' to add the
PhysicsWallpaperExtension widget extension target and embed it
in the main Pocket Poster app.

Run once before xcodebuild. Safe to run multiple times (idempotent).
"""
import sys, re

PBXPROJ = "Pocket Poster.xcodeproj/project.pbxproj"

with open(PBXPROJ, "r") as f:
    src = f.read()

if "PhysicsWallpaperExtension" in src:
    print("project.pbxproj already contains PhysicsWallpaperExtension — nothing to do.")
    sys.exit(0)

# ── UUID constants (deterministic, won't collide with existing 6F/BQ prefixes) ──
W_APPEX_REF  = "PP00000000000000000000A1"  # product file ref (.appex)
W_TARGET     = "PP00000000000000000000A2"  # native target
W_FSSYNC     = "PP00000000000000000000A3"  # file-system sync group
W_SRC_PHASE  = "PP00000000000000000000A4"  # sources build phase
W_FW_PHASE   = "PP00000000000000000000A5"  # frameworks build phase
W_RES_PHASE  = "PP00000000000000000000A6"  # resources build phase
W_DBG_CFG    = "PP00000000000000000000A7"  # Debug XCBuildConfiguration
W_REL_CFG    = "PP00000000000000000000A8"  # Release XCBuildConfiguration
W_CFG_LIST   = "PP00000000000000000000A9"  # XCConfigurationList
W_EMBED_PH   = "PP00000000000000000000AA"  # CopyFiles embed phase (main target)
W_EMBED_BF   = "PP00000000000000000000AB"  # PBXBuildFile for embedding
W_DEP        = "PP00000000000000000000AC"  # PBXTargetDependency
W_PROXY      = "PP00000000000000000000AD"  # PBXContainerItemProxy

BUNDLE_ID = "com.mak5er.pocketposter.PhysicsWallpaperExtension"

# ── 1. PBXBuildFile — the .appex file reference used in the embed phase ──
build_file_entry = f"""
\t\t{W_EMBED_BF} /* PhysicsWallpaperExtension.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {W_APPEX_REF} /* PhysicsWallpaperExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};"""

src = src.replace(
    "/* End PBXBuildFile section */",
    build_file_entry + "\n/* End PBXBuildFile section */"
)

# ── 2. PBXContainerItemProxy ──
proxy_entry = f"""
/* Begin PBXContainerItemProxy section */
\t\t{W_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 6F09B7952DEB694B00CDE89C /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {W_TARGET};
\t\t\tremoteInfo = PhysicsWallpaperExtension;
\t\t}};
/* End PBXContainerItemProxy section */"""

# Insert after PBXBuildFile section ends
src = src.replace(
    "\n/* Begin PBXFileReference section */",
    proxy_entry + "\n\n/* Begin PBXFileReference section */"
)

# ── 3. PBXFileReference — the .appex product ──
file_ref_entry = f"""
\t\t{W_APPEX_REF} /* PhysicsWallpaperExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = PhysicsWallpaperExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};"""

src = src.replace(
    "/* End PBXFileReference section */",
    file_ref_entry + "\n/* End PBXFileReference section */"
)

# ── 4. Add .appex to Products group children ──
src = src.replace(
    "6F09B79D2DEB694B00CDE89C /* Pocket Poster.app */,\n\t\t\t);",
    f"6F09B79D2DEB694B00CDE89C /* Pocket Poster.app */,\n\t\t\t\t{W_APPEX_REF} /* PhysicsWallpaperExtension.appex */,\n\t\t\t);"
)

# ── 5. PBXFileSystemSynchronizedRootGroup for extension source folder ──
fssync_entry = f"""
\t\t{W_FSSYNC} /* PhysicsWallpaperExtension */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = PhysicsWallpaperExtension;
\t\t\tsourceTree = "<group>";
\t\t}};"""

src = src.replace(
    "/* End PBXFileSystemSynchronizedRootGroup section */",
    fssync_entry + "\n/* End PBXFileSystemSynchronizedRootGroup section */"
)

# ── 6. CopyFiles embed phase (goes into main target) ──
embed_phase = f"""
/* Begin PBXCopyFilesBuildPhase section */
\t\t{W_EMBED_PH} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{W_EMBED_BF} /* PhysicsWallpaperExtension.appex in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */"""

src = src.replace(
    "\n/* Begin PBXFrameworksBuildPhase section */",
    embed_phase + "\n\n/* Begin PBXFrameworksBuildPhase section */"
)

# ── 7. Build phases for the extension target ──
ext_phases = f"""
\t\t{W_SRC_PHASE} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
\t\t{W_FW_PHASE} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
\t\t{W_RES_PHASE} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};"""

src = src.replace(
    "/* End PBXFrameworksBuildPhase section */",
    "/* End PBXFrameworksBuildPhase section */" + ext_phases
)

# ── 8. PBXNativeTarget for extension ──
ext_target = f"""
\t\t{W_TARGET} /* PhysicsWallpaperExtension */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {W_CFG_LIST} /* Build configuration list for PBXNativeTarget "PhysicsWallpaperExtension" */;
\t\t\tbuildPhases = (
\t\t\t\t{W_SRC_PHASE} /* Sources */,
\t\t\t\t{W_FW_PHASE} /* Frameworks */,
\t\t\t\t{W_RES_PHASE} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{W_FSSYNC} /* PhysicsWallpaperExtension */,
\t\t\t);
\t\t\tname = PhysicsWallpaperExtension;
\t\t\tproductName = PhysicsWallpaperExtension;
\t\t\tproductReference = {W_APPEX_REF} /* PhysicsWallpaperExtension.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};"""

src = src.replace(
    "/* End PBXNativeTarget section */",
    ext_target + "\n/* End PBXNativeTarget section */"
)

# ── 9. PBXTargetDependency ──
dep_section = f"""
/* Begin PBXTargetDependency section */
\t\t{W_DEP} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {W_TARGET} /* PhysicsWallpaperExtension */;
\t\t\ttargetProxy = {W_PROXY} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */"""

src = src.replace(
    "\n/* Begin XCBuildConfiguration section */",
    dep_section + "\n\n/* Begin XCBuildConfiguration section */"
)

# ── 10. Add target dependency + embed phase to main Pocket Poster target ──
# Add dependency
src = src.replace(
    "\t\t\tdependencies = (\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t6F09B79F2DEB694B00CDE89C",
    f"\t\t\tdependencies = (\n\t\t\t\t{W_DEP} /* PhysicsWallpaperExtension */,\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t6F09B79F2DEB694B00CDE89C"
)

# Add embed phase to main target's buildPhases
src = src.replace(
    "6F09B79B2DEB694B00CDE89C /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t" + W_DEP,
    "6F09B79B2DEB694B00CDE89C /* Resources */,\n\t\t\t\t" + W_EMBED_PH + " /* Embed Foundation Extensions */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t" + W_DEP
)

# ── 11. Add extension to project targets list ──
src = src.replace(
    "targets = (\n\t\t\t\t6F09B79C2DEB694B00CDE89C /* Pocket Poster */,\n\t\t\t);",
    f"targets = (\n\t\t\t\t6F09B79C2DEB694B00CDE89C /* Pocket Poster */,\n\t\t\t\t{W_TARGET} /* PhysicsWallpaperExtension */,\n\t\t\t);"
)

# ── 12. Add TargetAttributes for the new target ──
src = src.replace(
    "TargetAttributes = {\n\t\t\t\t\t6F09B79C2DEB694B00CDE89C = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;\n\t\t\t\t\t};",
    f"TargetAttributes = {{\n\t\t\t\t\t6F09B79C2DEB694B00CDE89C = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;\n\t\t\t\t\t}};\n\t\t\t\t\t{W_TARGET} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;\n\t\t\t\t\t}};"
)

# ── 13. XCBuildConfiguration for extension (Debug + Release) ──
ext_configs = f"""
\t\t{W_DBG_CFG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\t\tINFOPLIST_FILE = "PhysicsWallpaperExtension/Info.plist";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_MODULE_NAME = PhysicsWallpaperExtension;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{W_REL_CFG} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\t\tINFOPLIST_FILE = "PhysicsWallpaperExtension/Info.plist";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_MODULE_NAME = PhysicsWallpaperExtension;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Release;
\t\t}};"""

src = src.replace(
    "/* End XCBuildConfiguration section */",
    ext_configs + "\n/* End XCBuildConfiguration section */"
)

# ── 14. XCConfigurationList for extension ──
ext_cfglist = f"""
\t\t{W_CFG_LIST} /* Build configuration list for PBXNativeTarget "PhysicsWallpaperExtension" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{W_DBG_CFG} /* Debug */,
\t\t\t\t{W_REL_CFG} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};"""

src = src.replace(
    "/* End XCConfigurationList section */",
    ext_cfglist + "\n/* End XCConfigurationList section */"
)

with open(PBXPROJ, "w") as f:
    f.write(src)

print("✓ project.pbxproj patched — PhysicsWallpaperExtension target added.")
