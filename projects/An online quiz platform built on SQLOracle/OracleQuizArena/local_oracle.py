
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time

from dotenv import dotenv_values
import oracledb

ROOT = Path(__file__).resolve().parent
NAME = 'oracle-quiz-local'
VOLUME = 'oracle-quiz-local-data'
IMAGE = 'container-registry.oracle.com/database/free:latest-lite'


def docker(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ['docker', *args], cwd=ROOT, text=True, encoding='utf-8', errors='replace',
        capture_output=capture, check=False,
    )


def check_storage() -> None:
    if os.name != 'nt':
        return

    project_drive = ROOT.drive.casefold()
    settings_path = Path(os.environ['APPDATA']) / 'Docker/settings-store.json'
    settings = json.loads(settings_path.read_text(encoding='utf-8-sig')) if settings_path.exists() else {}
    storage = settings.get('CustomWslDistroDir') or settings.get('DataFolder')
    if not storage:
        storage = str(Path(os.environ['LOCALAPPDATA']) / 'Docker/wsl')
    if Path(storage).drive.casefold() != project_drive:
        raise RuntimeError(
            f'Docker data is on {storage}, but the project is on {ROOT.drive}. '
            'In Docker Settings > Resources > Advanced, move Disk image location '
            'to the project drive, then rerun INSTALL_AND_RUN.cmd.'
        )


def start(*, allow_pull: bool = False) -> None:
    if docker('info', capture=True).returncode:
        raise RuntimeError('Open Docker Desktop and wait for Engine running, then retry.')
    env_path = ROOT / '.local/oracle.env'
    password = dotenv_values(env_path).get('ORACLE_PWD')
    if not password:
        raise RuntimeError('Local database credentials are missing. Run INSTALL_AND_RUN.cmd.')
    existing = docker('container', 'inspect', NAME, capture=True)
    if existing.returncode == 0:
        container = json.loads(existing.stdout)[0]
        if container['Config'].get('Labels', {}).get('com.oraclequiz.local') != 'true':
            raise RuntimeError(f'Container {NAME} exists but is not managed by this project.')
        result = docker('start', NAME)
    else:
        check_storage()
        if docker('image', 'inspect', IMAGE, capture=True).returncode:
            if not allow_pull:
                raise RuntimeError('Oracle image is not cached. Run INSTALL_AND_RUN.cmd to download it.')
            print('Downloading Oracle Free Lite once; the cached image will be reused.', flush=True)
            if docker('pull', IMAGE).returncode:
                raise RuntimeError('Oracle image download failed. Check your internet connection and retry.')
        volume = docker('volume', 'inspect', VOLUME, capture=True)
        if volume.returncode == 0:
            labels = json.loads(volume.stdout)[0].get('Labels') or {}
            if labels.get('com.oraclequiz.local') != 'true':
                raise RuntimeError(f'Volume {VOLUME} is not managed by this installer. No data was changed.')
        elif docker('volume', 'create', '--label', 'com.oraclequiz.local=true', VOLUME).returncode:
            raise RuntimeError('Could not create the Oracle data volume.')
        result = docker(
            'run', '-d', '--pull=never', '--name', NAME,
            '--label', 'com.oraclequiz.local=true', '--restart=no',
            '--cpus=2', '--memory=3g', '--shm-size=1g',
            '-p', '127.0.0.1:1521:1521', '--env-file', str(env_path),
            '--mount', f'type=volume,source={VOLUME},target=/opt/oracle/oradata', IMAGE,
        )
    if result.returncode:
        raise RuntimeError('Docker did not start Oracle. Review its message above.')
    print('Waiting for Oracle on 127.0.0.1:1521/FREEPDB1...', flush=True)
    for attempt in range(120):
        try:
            with oracledb.connect(
                user='system', password=password, dsn='127.0.0.1:1521/FREEPDB1',
                tcp_connect_timeout=3,
            ) as connection:
                print(f'Oracle {connection.version} is ready.', flush=True)
                return
        except oracledb.Error as exc:
            if getattr(exc.args[0], 'code', None) == 1017:
                raise RuntimeError('Saved Oracle password does not match the existing database. Restore .local/oracle.env.') from exc
            if attempt % 6 == 0:
                print('Database initialization is still running...', flush=True)
            time.sleep(5)
    raise RuntimeError('Oracle startup timed out. Review its Logs in Docker Desktop.')


def stop() -> None:
    existing = docker('container', 'inspect', NAME, capture=True)
    if existing.returncode:
        raise RuntimeError('The local Oracle container was not found.')
    container = json.loads(existing.stdout)[0]
    if container['Config'].get('Labels', {}).get('com.oraclequiz.local') != 'true':
        raise RuntimeError('This container is not managed by the project.')
    if docker('stop', '--time', '90', NAME).returncode:
        raise RuntimeError('Could not stop Oracle.')
    print('Oracle stopped. Its persistent data is preserved.')


if __name__ == '__main__':
    try:
        action = sys.argv[1] if len(sys.argv) > 1 else 'start'
        if action == 'start':
            start()
        elif action == 'stop':
            stop()
        else:
            raise RuntimeError('Use start or stop.')
    except (RuntimeError, OSError, ValueError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
