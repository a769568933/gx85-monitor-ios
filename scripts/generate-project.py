"""Generate the dependency-free Xcode project. Run again after adding source files."""
from pathlib import Path
import hashlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def add(key, isa, **fields):
    uid = ident(key)
    objects[uid] = dict(isa=isa, **fields)
    return uid

class Ref(str):
    pass

def ref(key):
    return Ref(ident(key))

def serialize(value, depth=0):
    if isinstance(value, Ref): return str(value)
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (depth + 1) + k + ' = ' + serialize(v, depth + 1) + ';\n' for k, v in value.items()) + '\t' * depth + '}'
    if isinstance(value, list): return '(' + ', '.join(serialize(v, depth) for v in value) + (',' if value else '') + ')'
    if isinstance(value, int): return str(value)
    return quote(value)

def source_group(folder, prefix):
    files = sorted((ROOT / folder).rglob('*.swift'))
    refs, builds = [], []
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        filekey = f'file:{relative}'
        add(filekey, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=relative, sourceTree='<group>')
        refs.append(ref(filekey))
        buildkey = f'build:{prefix}:{relative}'
        add(buildkey, 'PBXBuildFile', fileRef=ref(filekey))
        builds.append(ref(buildkey))
    add(f'group:{prefix}', 'PBXGroup', children=refs, name=folder, sourceTree='<group>')
    return ref(f'group:{prefix}'), builds

appgroup, appsources = source_group('GX85Monitor', 'app')
testgroup, testsources = source_group('GX85MonitorTests', 'tests')
uitestgroup, uitestsources = source_group('GX85MonitorUITests', 'uitests')
add('file:assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='GX85Monitor/Assets.xcassets', sourceTree='<group>')
objects[ident('group:app')]['children'].append(ref('file:assets'))
add('file:plist', 'PBXFileReference', lastKnownFileType='text.plist.xml', path='GX85Monitor/Info.plist', sourceTree='<group>')
objects[ident('group:app')]['children'].append(ref('file:plist'))
add('build:assets', 'PBXBuildFile', fileRef=ref('file:assets'))
add('product:app', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex=0, path='GX85Monitor.app', sourceTree='BUILT_PRODUCTS_DIR')
add('product:tests', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path='GX85MonitorTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
add('product:uitests', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path='GX85MonitorUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
add('group:products', 'PBXGroup', children=[ref('product:app'), ref('product:tests'), ref('product:uitests')], name='Products', sourceTree='<group>')
add('group:main', 'PBXGroup', children=[appgroup, testgroup, uitestgroup, ref('group:products')], sourceTree='<group>')
add('package:core', 'XCLocalSwiftPackageReference', relativePath='GX85Core')
for target in ['app', 'tests']:
    add(f'dep:core:{target}', 'XCSwiftPackageProductDependency', package=ref('package:core'), productName='GX85Core')
    add(f'build:core:{target}', 'PBXBuildFile', productRef=ref(f'dep:core:{target}'))
    add(f'phase:frameworks:{target}', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[ref(f'build:core:{target}')], runOnlyForDeploymentPostprocessing=0)
    add(f'phase:resources:{target}', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[ref('build:assets')] if target == 'app' else [], runOnlyForDeploymentPostprocessing=0)
    add(f'phase:sources:{target}', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=appsources if target == 'app' else testsources, runOnlyForDeploymentPostprocessing=0)
add('phase:frameworks:uitests', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
add('phase:resources:uitests', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
add('phase:sources:uitests', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=uitestsources, runOnlyForDeploymentPostprocessing=0)
add('proxy:app', 'PBXContainerItemProxy', containerPortal=ref('project'), proxyType=1, remoteGlobalIDString=ref('target:app'), remoteInfo='GX85Monitor')
add('dependency:app', 'PBXTargetDependency', target=ref('target:app'), targetProxy=ref('proxy:app'))

for scope in ['project', 'app', 'tests', 'uitests']:
    for name in ['Debug', 'Release']:
        if scope == 'project':
            settings = dict(CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', IPHONEOS_DEPLOYMENT_TARGET='16.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if name == 'Debug' else 'dwarf-with-dsym')
            if name == 'Debug': settings.update(ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ONLY_ACTIVE_ARCH='YES')
        else:
            settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.gx85monitor.' + scope, TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', CODE_SIGN_STYLE='Automatic', SWIFT_EMIT_LOC_STRINGS='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks'])
            if scope == 'app':
                settings.update(GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='GX85Monitor/Info.plist', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor', CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='0.1.0')
            elif scope == 'tests':
                settings.update(GENERATE_INFOPLIST_FILE='YES', TEST_HOST='$(BUILT_PRODUCTS_DIR)/GX85Monitor.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/GX85Monitor', BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'])
            else:
                settings.update(GENERATE_INFOPLIST_FILE='YES', TEST_TARGET_NAME='GX85Monitor')
        add(f'config:{scope}:{name}', 'XCBuildConfiguration', buildSettings=settings, name=name)
    add(f'configs:{scope}', 'XCConfigurationList', buildConfigurations=[ref(f'config:{scope}:Debug'), ref(f'config:{scope}:Release')], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

for target, name, product_type in [('app', 'GX85Monitor', 'com.apple.product-type.application'), ('tests', 'GX85MonitorTests', 'com.apple.product-type.bundle.unit-test'), ('uitests', 'GX85MonitorUITests', 'com.apple.product-type.bundle.ui-testing')]:
    add(f'target:{target}', 'PBXNativeTarget', buildConfigurationList=ref(f'configs:{target}'), buildPhases=[ref(f'phase:sources:{target}'), ref(f'phase:frameworks:{target}'), ref(f'phase:resources:{target}')], buildRules=[], dependencies=[ref('dependency:app')] if target != 'app' else [], name=name, packageProductDependencies=[ref(f'dep:core:{target}')] if target != 'uitests' else [], productName=name, productReference=ref(f'product:{target}'), productType=product_type)

add('project', 'PBXProject', attributes=dict(BuildIndependentTargetsInParallel='YES', LastSwiftUpdateCheck='1600', LastUpgradeCheck='1600', TargetAttributes={ident('target:app'): dict(CreatedOnToolsVersion='16.0'), ident('target:tests'): dict(CreatedOnToolsVersion='16.0', TestTargetID=ref('target:app')), ident('target:uitests'): dict(CreatedOnToolsVersion='16.0', TestTargetID=ref('target:app'))}), buildConfigurationList=ref('configs:project'), compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN', hasScannedForEncodings=0, knownRegions=['zh_CN', 'en', 'Base'], mainGroup=ref('group:main'), packageReferences=[ref('package:core')], productRefGroup=ref('group:products'), projectDirPath='', projectRoot='', targets=[ref('target:app'), ref('target:tests'), ref('target:uitests')])

projectdir = ROOT / 'GX85Monitor.xcodeproj'
projectdir.mkdir(exist_ok=True)
text = '// !$*UTF8*$!\n' + serialize(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=ref('project'))) + '\n'
(projectdir / 'project.pbxproj').write_text(text, encoding='utf-8')
scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')

def build_ref(parent, target):
    name = {'app': 'GX85Monitor', 'tests': 'GX85MonitorTests', 'uitests': 'GX85MonitorUITests'}[target]
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=ident(f'target:{target}'), BuildableName=name + ('.app' if target == 'app' else '.xctest'), BlueprintName=name, ReferencedContainer='container:GX85Monitor.xcodeproj')

build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
entries = ET.SubElement(build, 'BuildActionEntries')
entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
build_ref(entry, 'app')
test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
testables = ET.SubElement(test, 'Testables')
for target in ['tests', 'uitests']:
    testable = ET.SubElement(testables, 'TestableReference', skipped='NO')
    build_ref(testable, target)
macro = ET.SubElement(test, 'MacroExpansion')
build_ref(macro, 'app')
launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
build_ref(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), 'app')
profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
build_ref(ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0'), 'app')
ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
ET.indent(scheme, space='  ')
schemedir = projectdir / 'xcshareddata/xcschemes'
schemedir.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(schemedir / 'GX85Monitor.xcscheme', encoding='utf-8', xml_declaration=True)
workspace = projectdir / 'project.xcworkspace'
workspace.mkdir(exist_ok=True)
(workspace / 'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"/></Workspace>\n', encoding='utf-8')
print(f'Generated project with {len(appsources)} app sources and {len(testsources)} test sources.')
