
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parent


def main():
    files = {ROOT / 'README.txt', ROOT / 'README_START_HERE.txt',
             ROOT / '.gitignore', ROOT / 'python/.env.example',
             ROOT / 'python/requirements.txt'}
    for pattern in ('*.cmd', '*.ps1', '*.py', 'python/*.py', 'sql/*.sql',
                    'tests/*.py', 'tests/*.sql', 'docs/*.md'):
        files.update(ROOT.glob(pattern))
    destination = ROOT / 'dist/OracleQuizArena.zip'
    destination.parent.mkdir(exist_ok=True)
    with ZipFile(destination, 'w', ZIP_DEFLATED) as archive:
        for path in sorted(files):
            archive.write(path, 'OracleQuizArena/' + path.relative_to(ROOT).as_posix())
    with ZipFile(destination) as archive:
        assert archive.testzip() is None
        assert not any('/.local/' in name or '/.venv/' in name or name.endswith('/.env')
                       for name in archive.namelist())
    print(f'{destination} ({destination.stat().st_size:,} bytes, {len(files)} files)')


if __name__ == '__main__':
    main()
