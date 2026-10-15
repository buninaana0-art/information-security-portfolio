
from __future__ import annotations

import argparse
from getpass import getpass
from pathlib import Path
import re
import secrets
import subprocess
import sys

from dotenv import dotenv_values, set_key
import oracledb

from installer_db import ROOT, install_or_update
import local_oracle

ENV_PATH = ROOT / 'python/.env'
LOCAL_DSN = '127.0.0.1:1521/FREEPDB1'


def save_settings(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(exist_ok=True)
    for key, value in values.items():


        set_key(str(path), key, value, quote_mode='auto')


def dsn_from_config(config: dict) -> str:
    if config.get('ORACLE_HOST'):
        mode = config.get('ORACLE_CONNECT_MODE', 'SERVICE').upper()
        database = config.get('ORACLE_DATABASE', 'FREEPDB1')
        if mode not in ('SID', 'SERVICE'):
            raise ValueError('ORACLE_CONNECT_MODE must be SID or SERVICE')
        return oracledb.makedsn(
            config['ORACLE_HOST'], int(config.get('ORACLE_PORT', '1521')),
            **({'sid': database} if mode == 'SID' else {'service_name': database}),
        )
    return config.get('ORACLE_DSN') or LOCAL_DSN


def prepare_local() -> dict:
    config = dict(dotenv_values(ENV_PATH))
    if config.get('ORACLE_HOST', '127.0.0.1') not in ('127.0.0.1', 'localhost') or (
        config.get('ORACLE_DSN') not in (None, LOCAL_DSN, 'localhost:1521/FREEPDB1')
    ) or config.get('ORACLE_USER', 'QUIZ_APP').upper() != 'QUIZ_APP':
        raise RuntimeError('Existing connection is not the local QUIZ_APP database. Use -UseExistingDatabase.')
    oracle_env = ROOT / '.local/oracle.env'
    if not oracle_env.exists():
        for kind, name in (('container', local_oracle.NAME), ('volume', local_oracle.VOLUME)):
            if local_oracle.docker(kind, 'inspect', name, capture=True).returncode == 0:
                raise RuntimeError('Existing Oracle data has no saved credentials. Restore .local/oracle.env; no password was reset.')
        save_settings(oracle_env, {'ORACLE_PWD': 'Qa' + secrets.token_hex(16)})
    if not config.get('ORACLE_PASSWORD') or config['ORACLE_PASSWORD'] == 'change_me':
        config['ORACLE_PASSWORD'] = 'Qa' + secrets.token_hex(16)
    values = {
        'ORACLE_USER': 'QUIZ_APP', 'ORACLE_PASSWORD': config['ORACLE_PASSWORD'],
        'ORACLE_HOST': '127.0.0.1', 'ORACLE_PORT': '1521',
        'ORACLE_DATABASE': 'FREEPDB1', 'ORACLE_CONNECT_MODE': 'SERVICE',
        'ORACLE_DSN': LOCAL_DSN, 'ORACLE_SCHEMA': 'QUIZ_APP',
    }
    save_settings(ENV_PATH, values)
    local_oracle.start(allow_pull=True)
    password = dotenv_values(oracle_env)['ORACLE_PWD']
    with oracledb.connect(user='system', password=password, dsn=LOCAL_DSN) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM all_users WHERE username = 'QUIZ_APP'")
            if cursor.fetchone()[0] == 0:

                cursor.execute("SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name = 'QUIZ_DATA'")
                if cursor.fetchone()[0] == 0:
                    cursor.execute(
                        "CREATE TABLESPACE quiz_data DATAFILE "
                        "'/opt/oracle/oradata/FREE/FREEPDB1/quiz_data01.dbf' "
                        "SIZE 16M AUTOEXTEND ON NEXT 8M MAXSIZE 256M"
                    )
                app_password = values['ORACLE_PASSWORD']
                if not re.fullmatch(r'[A-Za-z0-9_!@#$%^&*+=:.-]{8,128}', app_password):
                    raise ValueError('Local schema password contains unsupported characters.')
                cursor.execute(f'CREATE USER quiz_app IDENTIFIED BY "{app_password}" DEFAULT TABLESPACE quiz_data QUOTA 256M ON quiz_data')
                cursor.execute('GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE, CREATE SEQUENCE TO quiz_app')
    return values


def existing_config() -> dict:
    config = dict(dotenv_values(ENV_PATH))
    if config.get('ORACLE_USER') and config.get('ORACLE_PASSWORD') not in (None, '', 'change_me'):
        return config
    print('Enter the existing Oracle schema owner. No database user will be created.')
    host = input('Oracle host [127.0.0.1]: ').strip() or '127.0.0.1'
    port = input('Oracle port [1521]: ').strip() or '1521'
    mode = input('Connection mode SERVICE or SID [SERVICE]: ').strip().upper() or 'SERVICE'
    database = input('Service name / SID [FREEPDB1]: ').strip() or 'FREEPDB1'
    user = input('Oracle schema user: ').strip()
    password = getpass('Oracle schema password: ')
    config = {'ORACLE_HOST': host, 'ORACLE_PORT': port, 'ORACLE_CONNECT_MODE': mode,
              'ORACLE_DATABASE': database, 'ORACLE_USER': user, 'ORACLE_SCHEMA': user,
              'ORACLE_PASSWORD': password}

    with oracledb.connect(user=user, password=password, dsn=dsn_from_config(config)):
        pass
    save_settings(ENV_PATH, config)
    return config


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--existing-database', action='store_true')
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args()
    config = existing_config() if args.existing_database else prepare_local()
    if config.get('ORACLE_SCHEMA', config['ORACLE_USER']).upper() != config['ORACLE_USER'].upper():
        raise RuntimeError('Installation must connect as the schema owner (ORACLE_USER = ORACLE_SCHEMA).')
    with oracledb.connect(
        user=config['ORACLE_USER'], password=config['ORACLE_PASSWORD'],
        dsn=dsn_from_config(config), tcp_connect_timeout=10,
    ) as connection:
        print(f'Connected to Oracle Database {connection.version}.')
        install_or_update(connection)
    print('Ready: DEMO_ALICE / DemoAlice123! and DEMO_BOB / DemoBob123!, 12 games each.')
    if not args.no_launch:
        executable = Path(sys.executable).with_name('pythonw.exe')
        subprocess.Popen([str(executable), str(ROOT / 'python/desktop_app.py')], cwd=ROOT / 'python')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, oracledb.Error) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
