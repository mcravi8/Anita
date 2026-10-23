"""Update the single Buddy installation; backups are archives, never loose apps."""
from pathlib import Path, PurePosixPath
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import posixpath
import plistlib
import shutil
import sqlite3
import subprocess
import stat
import tempfile
import zipfile
from signing import verify_update

OUTPUTS = Path(__file__).resolve().parent.parent
INSTALLED = Path('/Applications/Buddy.app')
SUPPORT = Path.home() / 'Library/Application Support/Buddy'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def fingerprint(bundle):
    """Compare actual contents without reading any user data or credentials."""
    digest = hashlib.sha256()
    for path in sorted(bundle.rglob('*')):
        digest.update(str(path.relative_to(bundle)).encode() + b'\0')
        if path.is_symlink():
            digest.update(b'link\0' + os.readlink(path).encode())
        elif path.is_file():
            digest.update(b'file\0' + str(path.stat().st_mode & 0o777).encode())
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
        else:
            digest.update(b'dir\0')
    return digest.digest()


def verify(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.buddy.desktop' or info.get('CFBundleExecutable') != 'Buddy':
        raise RuntimeError('Refusing an unrelated app or executable.')
    helper = bundle / 'Contents/Helpers/Buddy Worker.app'
    helper_info = plistlib.loads((helper / 'Contents/Info.plist').read_bytes())
    if helper_info.get('CFBundleIdentifier') != 'app.buddy.workerhelper':
        raise RuntimeError('Unexpected worker identity.')
    for path in bundle.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()):
            raise RuntimeError('App contains an external link.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    return info


def unpack(archive, directory):
    with zipfile.ZipFile(archive) as zipped:
        links = set()
        for entry in zipped.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] not in ('Buddy.app', '__MACOSX'):
                raise RuntimeError('Archive must contain only Buddy.app and its resource metadata.')
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = zipped.read(entry).decode('utf-8')
                resolved = PurePosixPath(posixpath.normpath(str(path.parent / target)))
                if path.parts[0] != 'Buddy.app' or resolved.is_absolute() or not resolved.parts or resolved.parts[0] != 'Buddy.app':
                    raise RuntimeError('Archive contains an external link.')
                links.add(path)
        if any(parent in links for name in zipped.namelist() for parent in PurePosixPath(name).parents):
            raise RuntimeError('Archive contains entries beneath a link.')
        if zipped.testzip() is not None:
            raise RuntimeError('Damaged Buddy archive.')
    subprocess.run(['ditto', '-x', '-k', str(archive), str(directory)], check=True)
    return directory / 'Buddy.app'


def saved_queue():
    """The background task queue as the worker last saved it: from its database once that exists, else from the old tasks.json."""
    database = SUPPORT / 'Worker/operations.sqlite'
    if database.exists():
        connection = sqlite3.connect(f'file:{database}?mode=rw', uri=True, timeout=5)
        try:
            marker = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'").fetchone()
            if marker and connection.execute("SELECT 1 FROM meta WHERE key='migration'").fetchone():
                paused = connection.execute("SELECT value FROM meta WHERE key='paused'").fetchone()
                tasks = [json.loads(row[0]) for row in connection.execute('SELECT body FROM tasks WHERE archived = 0 ORDER BY seq')]
                return {'paused': bool(paused and paused[0] == '1'), 'tasks': tasks}
        finally:
            connection.close()
    tasks = SUPPORT / 'Worker/tasks.json'
    return json.loads(tasks.read_text()) if tasks.exists() else None


def ensure_idle():
    if (SUPPORT / 'Worker/PrivateSignIn.json').exists():
        raise RuntimeError('Finish private sign-in before updating Buddy.')
    workspace = SUPPORT / 'workspace.json'
    if workspace.exists():
        state = json.loads(workspace.read_text())
        if any(run.get('status') in ('starting', 'answering', 'stopping') for run in state.get('runs', {}).values()):
            raise RuntimeError('Finish or stop active conversations before updating Buddy.')
    queue = saved_queue()
    if queue is not None:
        # Running, queued and waiting work carries on after the worker restarts, so it never has to be paused for an update. The one
        # thing an update must not cut off is an approved action that is being handed over to be sent right now.
        for task in queue.get('tasks', []):
            if any(isinstance(review, dict) and review.get('status') == 'dispatched' for review in task.get('reviews') or []):
                title = str(task.get('title') or 'a background task')
                raise RuntimeError(f'An approved action is being sent right now ({title}). Try the update again in a minute.')
    commands = subprocess.check_output(['ps', '-axww', '-o', 'comm='], text=True).splitlines()
    if str(INSTALLED / 'Contents/MacOS/Buddy') in (line.strip() for line in commands):
        raise RuntimeError('Quit Buddy before updating; reopen the same app in Applications afterward.')
    return commands


def full_priority(agent):
    """Make the worker an "Interactive" launchd job, which runs like an app at normal priority, as do the programs agents start. An earlier
    Buddy wrote "Background" (the S02a computation ran on the efficiency cores with a third of the Mac idle) or nothing ("Standard", which still
    runs at utility priority). True if the file changed."""
    if not agent.exists():
        return False
    values = plistlib.loads(agent.read_bytes())
    if values.get('ProcessType') == 'Interactive':
        return False
    values['ProcessType'] = 'Interactive'
    agent.write_bytes(plistlib.dumps(values))
    os.chmod(agent, 0o600)
    return True


def update(archive, check_only=False):
    # Both extracted app and replacement/rollback bundles are inside .noindex
    # directories. They are never launched or registered from staging.
    with tempfile.TemporaryDirectory(prefix='buddy-package-', suffix='.noindex') as temporary:
        staged = unpack(archive, Path(temporary))
        info = verify(staged)
        if INSTALLED.is_symlink():
            raise RuntimeError('Refusing a symlink at the installation path.')
        if INSTALLED.exists():
            verify(INSTALLED)
            verify_update(INSTALLED, staged)
            verify_update(INSTALLED / 'Contents/Helpers/Buddy Worker.app', staged / 'Contents/Helpers/Buddy Worker.app')
            if fingerprint(staged) == fingerprint(INSTALLED):
                print('Buddy is already current at /Applications/Buddy.app. No changes made.')
                return
        if check_only:
            print(f'Verified Buddy {info["CFBundleShortVersionString"]}; destination: {INSTALLED}. No changes made.')
            return
        commands = ensure_idle()
        service = f'gui/{os.getuid()}/app.buddy.worker'
        helper = str(INSTALLED / 'Contents/Helpers/Buddy Worker.app/Contents/MacOS/BuddyWorker')
        loaded = subprocess.run(['launchctl', 'print', service], capture_output=True).returncode == 0
        if helper in (line.strip() for line in commands) and not loaded:
            raise RuntimeError('Close the separately launched Buddy worker before updating.')
        backup_directory = OUTPUTS / 'Buddy-backups.noindex'
        backup_directory.mkdir(exist_ok=True)
        if INSTALLED.exists():
            backup = backup_directory / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.zip')
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(INSTALLED), str(backup)], check=True)
            with zipfile.ZipFile(backup) as zipped:
                if zipped.testzip() is not None:
                    raise RuntimeError('Could not verify rollback archive; installation unchanged.')
        with tempfile.TemporaryDirectory(prefix='.Buddy-update-', suffix='.noindex', dir=INSTALLED.parent) as replacement:
            replacement = Path(replacement)
            ready, previous = replacement / 'Buddy.app', replacement / 'Previous.app'
            shutil.copytree(staged, ready, symlinks=True)
            verify(ready)
            if loaded:
                subprocess.run(['launchctl', 'bootout', service], check=True)
            try:
                if INSTALLED.exists():
                    INSTALLED.rename(previous)
                try:
                    ready.rename(INSTALLED)
                    verify(INSTALLED)
                except BaseException:
                    if INSTALLED.exists():
                        shutil.rmtree(INSTALLED)
                    if previous.exists():
                        previous.rename(INSTALLED)
                    raise
            finally:
                agent = Path.home() / 'Library/LaunchAgents/app.buddy.worker.plist'
                full_priority(agent)
                if loaded:
                    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(agent)], check=True)
        subprocess.run([LSREGISTER, '-f', str(INSTALLED)], check=True)
        print(f'Updated Buddy {info["CFBundleShortVersionString"]} at {INSTALLED}. User data and Keychain were untouched.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=OUTPUTS / 'Buddy-mac.zip')
    parser.add_argument('--check', action='store_true', help='Verify package and destination without installing.')
    options = parser.parse_args()
    with (OUTPUTS / '.buddy-install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        update(options.archive.resolve(), options.check)


if __name__ == '__main__':
    main()
