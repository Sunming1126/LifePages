"""Add empty book-mode metadata tables to backed-up, stopped account databases."""
import argparse
import ast
import json
from pathlib import Path
import sqlite3


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path, required=True)
    args = parser.parse_args()
    tree = ast.parse((Path(__file__).resolve().parents[1] / 'server/book_modes.py').read_text())
    schema = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == 'SCHEMA' for target in node.targets))
    managed = 0
    for path in sorted((args.data / 'accounts').glob('*/lifepages.sqlite3')):
        with sqlite3.connect(path) as connection:
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE name='books'").fetchone():
                continue
            connection.executescript('BEGIN IMMEDIATE;\n' + schema + '\nCOMMIT;')
            assert connection.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
            managed += 1
    print(json.dumps({'mode_metadata_migration': 'OK', 'managed_account_databases': managed,
                      'added_metadata_tables': 4, 'existing_rows_rewritten': False}), flush=True)


if __name__ == '__main__':
    main()
