from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from signing import identity

source = Path(__file__).resolve().parent
outputs = source.parent
frontend = outputs / 'relay'
parser = argparse.ArgumentParser(description='Build Buddy without leaving additional searchable apps.')
parser.add_argument('--install', action='store_true', help='Update the existing /Applications/Buddy.app after building.')
options = parser.parse_args()
signing_identity = identity()

with tempfile.TemporaryDirectory(prefix='buddy-build-', suffix='.noindex') as temporary:
    build = Path(temporary)
    build_source = build / 'Source'
    shutil.copytree(source, build_source, ignore=shutil.ignore_patterns('tests', '__pycache__'))
    staged = build / 'Buddy.app'
    contents = staged / 'Contents'
    binary = contents / 'MacOS' / 'Buddy'
    resources = contents / 'Resources'
    binary.parent.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copytree(source / 'MarkdownViewer', resources / 'MarkdownViewer')
    shutil.copytree(frontend, resources / 'Web', ignore=shutil.ignore_patterns('*.test.js', 'README.md', 'prompts.json', '.*'))
    shutil.copytree(outputs / 'buddy-worker', resources / 'Worker', ignore=shutil.ignore_patterns('test', '*.test.mjs', 'README.md', '.*'))
    plist = {
        'CFBundleName': 'Buddy', 'CFBundleDisplayName': 'Buddy',
        'CFBundleIdentifier': 'app.buddy.desktop', 'CFBundleExecutable': 'Buddy',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.24.6',
        'CFBundleVersion': '50', 'CFBundleIconFile': 'Buddy.icns',
        'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication', 'LSApplicationCategoryType': 'public.app-category.productivity',
        'NSHumanReadableCopyright': 'Buddy · Personal teamwork edition',
    }
    with (contents / 'Info.plist').open('wb') as handle:
        plistlib.dump(plist, handle)
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    compiler = ['xcrun', 'swiftc', '-sdk', sdk, '-O', '-module-cache-path', str(build / 'module-cache'), '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'JavaScriptCore']
    for architecture in ['arm64', 'x86_64']:
        subprocess.run(compiler + ['-target', f'{architecture}-apple-macosx13.0', str(build_source / 'main.swift'), str(build_source / 'BuddyFilePreview.swift'), str(build_source / 'BuddyMarkdownRenderer.swift'), str(build_source / 'BuddyMarkdownPreview.swift'), str(build_source / 'ConversationService.swift'), str(build_source / 'BuddyInboxReview.swift'), str(build_source / 'BuddyMailVerification.swift'), str(build_source / 'BuddyComputer.swift'), str(build_source / 'BuddyTransport.swift'), str(build_source / 'BuddyToolInput.swift'), str(build_source / 'BuddyConnections.swift'), str(build_source / 'BuddyTeam.swift'), str(build_source / 'BuddyProjectFiles.swift'), str(build_source / 'BuddyDocuments.swift'), str(build_source / 'BuddyAgentProposals.swift'), str(build_source / 'BuddyTeamService.swift'), *[str(build_source / name) for name in ['BuddyWorkerCore.swift', 'BuddyOperationsDB.swift', 'BuddyWorkerProcess.swift', 'BuddyWorkerHost.swift', 'BuddyCodexCoding.swift', 'BuddyPlan.swift', 'BuddySupervisor.swift', 'BuddyMigrations.swift', 'BuddyWorkerClient.swift', 'BuddyAISettings.swift', 'BuddyAgentMemory.swift', 'BuddyTeamMonitorStore.swift', 'BuddyTeamMonitor.swift', 'BuddyAgentSetup.swift', 'BuddyClaudeConversations.swift', 'BuddyAIRouter.swift', 'BuddyCredentials.swift', 'BuddyChromeAccounts.swift', 'BuddyCommandReview.swift', 'BuddyDesktopDrop.swift', 'BuddyConnectedServices.swift', 'BuddyLeases.swift']], '-o', str(build / architecture)], check=True)
    subprocess.run(['lipo', '-create', str(build / 'arm64'), str(build / 'x86_64'), '-output', str(binary)], check=True)
    helper = contents / 'Helpers' / 'Buddy Worker.app'
    helper_binary = helper / 'Contents/MacOS/BuddyWorker'
    helper_binary.parent.mkdir(parents=True)
    shutil.copyfile(binary, helper_binary); helper_binary.chmod(0o755)
    helper_info = {'CFBundleName': 'Buddy Worker', 'CFBundleIdentifier': 'app.buddy.workerhelper', 'CFBundleExecutable': 'BuddyWorker', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.24.6', 'CFBundleVersion': '50', 'LSUIElement': True, 'LSMinimumSystemVersion': '13.0', 'NSPrincipalClass': 'NSApplication'}
    (helper / 'Contents/Info.plist').write_bytes(plistlib.dumps(helper_info))
    subprocess.run(['codesign', '--force', '--sign', signing_identity, '--timestamp=none', '--identifier', 'app.buddy.workerhelper', str(helper)], check=True)
    renderer = build / 'render-icon'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(build / 'module-cache'), '-framework', 'AppKit', str(build_source / 'render-icon.swift'), '-o', str(renderer)], check=True)
    iconset = build / 'Buddy.iconset'
    subprocess.run([str(renderer), str(iconset), str(build_source / 'icon-logo.png')], check=True)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'Buddy.icns')], check=True)
    shutil.copyfile(iconset / 'icon_512x512@2x.png', outputs / 'buddy-app-icon.png')
    subprocess.run(['codesign', '--force', '--sign', signing_identity, '--timestamp=none', '--identifier', 'app.buddy.desktop', str(staged)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
    archive = build / 'Buddy-mac.zip'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(staged), str(archive)], check=True)
    # Only the archive leaves temporary staging. Loose build/test app bundles must
    # never accumulate beside the one installed application.
    pending = outputs / '.Buddy-mac.zip.pending'
    try:
        shutil.copyfile(archive, pending)
        os.replace(pending, outputs / 'Buddy-mac.zip')
    finally:
        pending.unlink(missing_ok=True)
print(f'Built and verified {outputs / "Buddy-mac.zip"}')
if options.install:
    import sys
    subprocess.run([sys.executable, str(source / 'install.py')], check=True)
