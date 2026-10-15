
from pathlib import Path
from subprocess import CompletedProcess
import sys
import unittest
import tempfile
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from installer_db import statements
import local_oracle
import setup_game


class InstallerTests(unittest.TestCase):
    def test_fresh_configuration_uses_one_schema_and_plain_docker_password(self):
        (ROOT / '.local').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.local') as directory:
            root = Path(directory)
            connection = MagicMock()
            cursor = connection.__enter__.return_value.cursor.return_value.__enter__.return_value
            cursor.fetchone.side_effect = [(0,), (0,)]
            with patch.object(setup_game, 'ROOT', root),\
                 patch.object(setup_game, 'ENV_PATH', root / 'python/.env'),\
                 patch.object(local_oracle, 'docker', return_value=CompletedProcess([], 1, '', '')),\
                 patch.object(local_oracle, 'start') as start,\
                 patch.object(setup_game.oracledb, 'connect', return_value=connection):
                config = setup_game.prepare_local()
            raw_env = (root / '.local/oracle.env').read_text()
            self.assertRegex(raw_env, r'^ORACLE_PWD=[A-Za-z0-9]+\n$')
            self.assertEqual(config['ORACLE_USER'], 'QUIZ_APP')
            sql = [call.args[0] for call in cursor.execute.call_args_list]
            creates = [query for query in sql if query.startswith('CREATE USER')]
            self.assertEqual(len(creates), 1)
            self.assertTrue(creates[0].startswith('CREATE USER quiz_app '))
            self.assertFalse(any(query.startswith('ALTER USER') for query in sql))
            start.assert_called_once_with(allow_pull=True)

    def test_sql_quotes_comments_and_plsql(self):
        script = """SET DEFINE OFF
-- setup
INSERT INTO t VALUES ('a;''b', 1); -- comment
/* between */
DECLARE
    x NUMBER;
BEGIN
    x := 1;
END;
/
COMMIT;
"""
        parsed = list(statements(script))
        self.assertEqual(len(parsed), 3)
        self.assertIn("'a;''b'", parsed[0][1])
        self.assertTrue(parsed[1][1].startswith('DECLARE'))
        self.assertEqual(parsed[2], ('sql', 'COMMIT'))

    def test_existing_managed_container_is_reused(self):
        calls = []

        def docker(*args, **kwargs):
            calls.append(args)
            data = '[{"Config":{"Labels":{"com.oraclequiz.local":"true"}}}]'
            return CompletedProcess(args, 0, data, '')

        with patch.object(local_oracle, 'docker', side_effect=docker),\
             patch.object(local_oracle, 'dotenv_values', return_value={'ORACLE_PWD': 'fake'}),\
             patch.object(local_oracle.oracledb, 'connect', return_value=MagicMock()):
            local_oracle.start(allow_pull=True)
        self.assertIn(('start', local_oracle.NAME), calls)
        self.assertFalse(any(call[0] in ('pull', 'run') for call in calls))

    def test_missing_image_is_downloaded_only_by_installer(self):
        for allow_pull in (False, True):
            calls = []

            def docker(*args, **kwargs):
                calls.append(args)
                missing = args[:2] in (('container', 'inspect'), ('image', 'inspect'), ('volume', 'inspect'))
                return CompletedProcess(args, int(missing), '', '')

            with patch.object(local_oracle, 'docker', side_effect=docker),\
                 patch.object(local_oracle, 'check_storage'),\
                 patch.object(local_oracle, 'dotenv_values', return_value={'ORACLE_PWD': 'fake'}),\
                 patch.object(local_oracle.oracledb, 'connect', return_value=MagicMock()):
                if allow_pull:
                    local_oracle.start(allow_pull=True)
                    run = next(call for call in calls if call[0] == 'run')
                    self.assertIn('127.0.0.1:1521:1521', run)
                    self.assertIn('--pull=never', run)
                else:
                    with self.assertRaises(RuntimeError):
                        local_oracle.start()
            self.assertEqual(any(call[0] == 'pull' for call in calls), allow_pull)


if __name__ == '__main__':
    unittest.main()
