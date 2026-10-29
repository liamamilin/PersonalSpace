"""Generate the checked-in Xcode project using only the Python standard library."""
from pathlib import Path
import hashlib

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, body):
    objects.append(f'{uid(name)} = {{ {body} }};')
    return uid(name)

def refs(names):
    return ', '.join(uid(n) for n in names) + (',' if names else '')

appfiles = sorted(str(p) for p in Path('PersonalSpace').rglob('*.swift'))
testfiles = sorted(str(p) for p in Path('PersonalSpaceTests').rglob('*.swift'))
assets = 'PersonalSpace/Assets.xcassets'
obj(assets, f'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "{assets}"; sourceTree = SOURCE_ROOT;')
obj('build:'+assets, f'isa = PBXBuildFile; fileRef = {uid(assets)};')
for path in appfiles + testfiles:
    obj(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT;')
    obj('build:'+path, f'isa = PBXBuildFile; fileRef = {uid(path)};')
obj('app-product','isa = PBXFileReference; explicitFileType = wrapper.application; path = PersonalSpace.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('test-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = PersonalSpaceTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('sources',f'isa = PBXGroup; name = PersonalSpace; children = ({refs(appfiles+[assets])}); sourceTree = "<group>";')
obj('tests',f'isa = PBXGroup; name = PersonalSpaceTests; children = ({refs(testfiles)}); sourceTree = "<group>";')
obj('products',f'isa = PBXGroup; name = Products; children = ({refs(["app-product","test-product"])}); sourceTree = "<group>";')
obj('root',f'isa = PBXGroup; children = ({refs(["sources","tests","products"])}); sourceTree = "<group>";')
obj('grdb','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/groue/GRDB.swift.git"; requirement = {kind = exactVersion; version = 7.11.1;};')
obj('grdb-product',f'isa = XCSwiftPackageProductDependency; package = {uid("grdb")}; productName = GRDB;')
obj('grdb-build',f'isa = PBXBuildFile; productRef = {uid("grdb-product")};')
for target,files in [('app',appfiles),('test',testfiles)]:
    obj(target+'-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({refs(["build:"+p for p in files])}); runOnlyForDeploymentPostprocessing = 0;')
    obj(target+'-frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({refs(["grdb-build"] if target=="app" else [])}); runOnlyForDeploymentPostprocessing = 0;')
    obj(target+'-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({refs(["build:"+assets] if target=="app" else [])}); runOnlyForDeploymentPostprocessing = 0;')
    for config in ['Debug','Release']:
        settings = 'SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 26.0; SDKROOT = macosx; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "-";'
        if target=='app':
            settings += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; INFOPLIST_KEY_CFBundleIconName = AppIcon;'
            settings += ' PRODUCT_BUNDLE_IDENTIFIER = com.liamamilin.PersonalSpace; PRODUCT_NAME = PersonalSpace; ENABLE_APP_SANDBOX = YES; ENABLE_USER_SELECTED_FILES = readwrite; CODE_SIGN_ENTITLEMENTS = PersonalSpace/PersonalSpace.entitlements; MARKETING_VERSION = 0.10.0; CURRENT_PROJECT_VERSION = 13; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; INFOPLIST_KEY_CFBundleDisplayName = PersonalSpace; INFOPLIST_KEY_CFBundleDevelopmentRegion = zh_CN; INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "仅用于查看已授权照片并关联个人对象，不修改图库，不下载iCloud原片。";'
        else:
            settings += f' PRODUCT_BUNDLE_IDENTIFIER = com.liamamilin.PersonalSpaceTests; PRODUCT_NAME = PersonalSpaceTests; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/PersonalSpace.app/Contents/MacOS/PersonalSpace"; BUNDLE_LOADER = "$(TEST_HOST)"; SWIFT_INCLUDE_PATHS = "$(BUILT_PRODUCTS_DIR)";'
        if config=='Debug': settings += ' ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
        else: settings += ' SWIFT_OPTIMIZATION_LEVEL = "-O";'
        if target=='app' and config=='Release': settings += ' CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;'
        obj(target+'-'+config,f'isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {config};')
    obj(target+'-config',f'isa = XCConfigurationList; buildConfigurations = ({refs([target+"-Debug",target+"-Release"])}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("app")}; remoteInfo = PersonalSpace;')
obj('dependency',f'isa = PBXTargetDependency; target = {uid("app")}; targetProxy = {uid("proxy")};')
obj('app',f'isa = PBXNativeTarget; buildConfigurationList = {uid("app-config")}; buildPhases = ({refs(["app-sources","app-frameworks","app-resources"])}); buildRules = (); dependencies = (); name = PersonalSpace; packageProductDependencies = ({uid("grdb-product")},); productName = PersonalSpace; productReference = {uid("app-product")}; productType = "com.apple.product-type.application";')
obj('test',f'isa = PBXNativeTarget; buildConfigurationList = {uid("test-config")}; buildPhases = ({refs(["test-sources","test-frameworks","test-resources"])}); buildRules = (); dependencies = ({uid("dependency")},); name = PersonalSpaceTests; productName = PersonalSpaceTests; productReference = {uid("test-product")}; productType = "com.apple.product-type.bundle.unit-test";')
for config in ['Debug','Release']:
    obj('project-'+config,f'isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 26.0;}}; name = {config};')
obj('project-config',f'isa = XCConfigurationList; buildConfigurations = ({refs(["project-Debug","project-Release"])}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project',f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{{uid("app")} = {{CreatedOnToolsVersion = 27.1; SystemCapabilities = {{com.apple.Sandbox = {{enabled = 1;}};}};}}; {uid("test")} = {{TestTargetID = {uid("app")};}};}};}}; buildConfigurationList = {uid("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (zh_CN, en, Base); mainGroup = {uid("root")}; packageReferences = ({uid("grdb")},); productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({refs(["app","test"])});')
p = Path('PersonalSpace.xcodeproj')
p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
scheme = p/'xcshareddata/xcschemes'
scheme.mkdir(parents=True,exist_ok=True)
def buildable(target,name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(target)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:PersonalSpace.xcodeproj"/>'
(scheme/'PersonalSpace.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('app','PersonalSpace.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('test','PersonalSpaceTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','PersonalSpace.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','PersonalSpace.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
