
from __future__ import annotations

import argparse
import subprocess
import sys

from dotenv import dotenv_values
import oracledb

from installer_db import ROOT, install_or_update, run_script
from setup_game import dsn_from_config


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['init', 'verify', 'auth', 'smoke', 'full'])
    action = parser.parse_args().action
    if action == 'auth':
        subprocess.run([sys.executable, str(ROOT / 'tests/oracle_auth_test.py')], check=True)
        return
    config = dotenv_values(ROOT / 'python/.env')
    with oracledb.connect(
        user=config['ORACLE_USER'], password=config['ORACLE_PASSWORD'],
        dsn=dsn_from_config(config), tcp_connect_timeout=5,
    ) as connection:
        if action == 'init':
            install_or_update(connection)
        else:
            filename = {'verify': 'verify_install.sql', 'smoke': 'smoke_test.sql',
                        'full': 'full_regression.sql'}[action]
            run_script(connection, ROOT / 'tests' / filename)
            if action == 'verify':
                run_script(connection, ROOT / 'tests/verify_demo_history.sql')
        print(f'PASS: {action}')


if __name__ == '__main__':
    main()
