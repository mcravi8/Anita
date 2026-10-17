from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parent
outputs = source.parent
app = outputs / 'Buddy.app'
frontend = outputs / 'relay'

with tempfile.TemporaryDirectory(prefix='buddy-build-') as temporary:
    build = Path(temporary)
    staged = build / 'Buddy.app'
    contents = staged / 'Contents'
    binary = contents / 'MacOS' / 'Buddy'
    resources = contents / 'Resources'
    binary.parent.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copytree(frontend, resources / 'Web', ignore=shutil.ignore_patterns('*.test.js', 'README.md', 'prompts.json', '.*'))
    plist = {
        'CFBundleName': 'Buddy', 'CFBundleDisplayName': 'Buddy',
        'CFBundleIdentifier': 'app.buddy.desktop', 'CFBundleExecutable': 'Buddy',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.11.0',
        'CFBundleVersion': '15', 'CFBundleIconFile': 'Buddy.icns',
        'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication', 'LSApplicationCategoryType': 'public.app-category.productivity',
        'NSHumanReadableCopyright': 'Buddy · Personal teamwork edition',
    }
    with (contents / 'Info.plist').open('wb') as handle:
        plistlib.dump(plist, handle)
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    compiler = ['xcrun', 'swiftc', '-sdk', sdk, '-O', '-framework', 'AppKit', '-framework', 'WebKit']
    for architecture in ['arm64', 'x86_64']:
        subprocess.run(compiler + ['-target', f'{architecture}-apple-macosx13.0', str(source / 'main.swift'), str(source / 'BuddyFilePreview.swift'), str(source / 'ConversationService.swift'), str(source / 'BuddyComputer.swift'), str(source / 'BuddyTransport.swift'), str(source / 'BuddyToolInput.swift'), str(source / 'BuddyConnections.swift'), str(source / 'BuddyTeam.swift'), str(source / 'BuddyProjectFiles.swift'), str(source / 'BuddyDocuments.swift'), str(source / 'BuddyAgentProposals.swift'), str(source / 'BuddyTeamService.swift'), '-o', str(build / architecture)], check=True)
    subprocess.run(['lipo', '-create', str(build / 'arm64'), str(build / 'x86_64'), '-output', str(binary)], check=True)
    renderer = build / 'render-icon'
    subprocess.run(['xcrun', 'swiftc', '-O', '-framework', 'AppKit', str(source / 'render-icon.swift'), '-o', str(renderer)], check=True)
    iconset = build / 'Buddy.iconset'
    subprocess.run([str(renderer), str(iconset)], check=True)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'Buddy.icns')], check=True)
    shutil.copyfile(iconset / 'icon_512x512@2x.png', outputs / 'buddy-app-icon.png')
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'app.buddy.desktop', str(staged)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
    if app.exists():
        old_plist = plistlib.loads((app / 'Contents' / 'Info.plist').read_bytes())
        if old_plist.get('CFBundleIdentifier') != 'app.buddy.desktop':
            raise RuntimeError('Refusing to replace an unrelated app.')
        shutil.rmtree(app)
    shutil.copytree(staged, app)
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(outputs / 'Buddy-mac.zip')], check=True)
print(f'Built and verified {app}')
