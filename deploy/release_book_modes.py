"""Scoped, rollback-capable LifePages API overlay. Run as root on the host."""
import argparse
import fcntl
import hashlib
import json
import os
import pwd
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

BASE = Path('/opt/lifepages')
DATA = BASE / 'shared/data'
PYTHON = str(BASE / 'shared/venv/bin/python')
SERVICES = ('nginx', 'lifepages-rtc', 'lifepages-embeddings', 'lifepages-qdrant',
            'duanju-agent', 'healthbutler', 'plotloom-cn-api', 'plotloom-cn-web', 'plotloom-cn-worker')
TIMERS = ('lifepages-drafts.timer', 'lifepages-memory.timer')
MODE_TABLES = {'book_modes', 'book_directory_state', 'book_topic_archives', 'companion_returns'}
CONFIG = ('/etc/nginx/sites-enabled/onesay.top', '/etc/systemd/system/lifepages.service',
          '/opt/lifepages/shared/lifepages.env', '/opt/lifepages/rtc/rtc.env')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def active(unit):
    return subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0


def services():
    return {name: subprocess.check_output(['systemctl', 'show', name + '.service', '-p', 'MainPID',
            '-p', 'ActiveState', '--no-pager'], text=True) for name in SERVICES}


def fingerprint(path):
    with sqlite3.connect(f'file:{path}?mode=ro', uri=True) as c:
        tables = c.execute("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        result = {}
        for name, schema in tables:
            quoted = '"' + name.replace('"', '""') + '"'
            hashes = sorted(hashlib.sha256(json.dumps(list(row), ensure_ascii=False,
                default=lambda value: {'blob': value.hex()}).encode()).hexdigest()
                for row in c.execute('SELECT * FROM ' + quoted))
            result[name] = {'schema': schema, 'rows': len(hashes),
                            'digest': hashlib.sha256(''.join(hashes).encode()).hexdigest()}
        return result


def environment():
    env = os.environ.copy()
    for line in (BASE / 'shared/lifepages.env').read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, value = line.split('=', 1)
        parts = shlex.split(value, comments=True)
        env[key.strip()] = ' '.join(parts)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    return env


def health(base):
    try:
        urllib.request.urlopen(base + '/api/books', timeout=5)
    except urllib.error.HTTPError as error:
        return error.code == 401
    except OSError:
        return False
    return False


def switch(path):
    pending = BASE / 'current.interview-v2-next'
    pending.symlink_to(path)
    os.replace(pending, BASE / 'current')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('stamp')
    parser.add_argument('--expected', required=True)
    args = parser.parse_args()
    assert args.stamp.replace('-', '').replace('T', '').replace('Z', '').isalnum()
    with (BASE / '.deployment.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        previous = (BASE / 'current').resolve()
        assert str(previous) == args.expected, 'Current release changed'
        assert active('lifepages.service')
        before_services = services()
        before_config = {p: digest(p) for p in CONFIG}
        timer_states = {t: active(t) for t in TIMERS}
        release = BASE / 'releases' / args.stamp
        backup = BASE / 'backups' / args.stamp
        assert not release.exists() and not backup.exists()
        backup.mkdir(mode=0o700)
        backup.chmod(0o700)
        shutil.copytree(previous, release, symlinks=True)
        with tarfile.open(args.archive) as archive:
            for member in archive.getmembers():
                p = Path(member.name)
                assert not p.is_absolute() and '..' not in p.parts and member.isfile()
                assert p.parts[0] in ('server', 'deploy', 'tool') or member.name in ('manifest.json', 'assets/memoir-cover.jpg')
                target = release / p
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open('wb') as destination:
                    shutil.copyfileobj(source, destination)
                target.chmod(0o644)
        manifest = json.loads((release / 'manifest.json').read_text())
        for name, value in manifest['baseline'].items():
            assert digest(previous / name) == value, 'Live source changed since review'
        for name, value in manifest['files'].items():
            assert digest(release / name) == value, 'Candidate source hash mismatch'
        with tempfile.TemporaryDirectory(prefix='lifepages-v2-release-qa-') as temporary:
            qa = Path(temporary)
            identity = pwd.getpwnam('lifepages')
            os.chown(qa, identity.pw_uid, identity.pw_gid)
            env = environment()
            env['LIFEPAGES_DATA'] = str(qa / 'data')
            assert not health('http://127.0.0.1:18041'), 'QA port is already occupied'
            run(PYTHON, '-B', '-m', 'unittest', *manifest['test_modules'], cwd=release, env=env,
                user=identity.pw_uid, group=identity.pw_gid, extra_groups=[])
            process = subprocess.Popen([PYTHON, '-B', '-m', 'uvicorn', 'server.app:app', '--host',
                '127.0.0.1', '--port', '18041', '--no-access-log'], cwd=release, env=env,
                stdout=(qa / 'api.log').open('w'), stderr=subprocess.STDOUT,
                user=identity.pw_uid, group=identity.pw_gid, extra_groups=[])
            try:
                for _ in range(40):
                    if health('http://127.0.0.1:18041'):
                        break
                    if process.poll() is not None:
                        raise RuntimeError('Candidate API failed to start')
                    time.sleep(.25)
                assert health('http://127.0.0.1:18041')
                for round_number in range(3):
                    run(PYTHON, '-B', 'deploy/smoke_book_modes_release.py', '--base',
                        'http://127.0.0.1:18041', '--data', str(qa / 'data'), cwd=release)
                    print(f'ISOLATED_ROUND_{round_number + 1}_OK', flush=True)
                print('ISOLATED_CANDIDATE_OK', flush=True)
            finally:
                process.terminate()
                process.wait(timeout=30)
        stopped = False
        try:
            assert (BASE / 'current').resolve() == previous
            assert before_config == {p: digest(p) for p in CONFIG}
            for timer, was_active in timer_states.items():
                if was_active:
                    run('systemctl', 'stop', timer)
            for _ in range(60):
                if not any(active(t.replace('.timer', '.service')) for t in TIMERS):
                    break
                time.sleep(1)
            assert not any(active(t.replace('.timer', '.service')) for t in TIMERS), 'Background task still running'
            run('systemctl', 'stop', 'lifepages.service')
            stopped = True
            databases = [DATA / 'registry.sqlite3', *sorted((DATA / 'accounts').glob('*/lifepages.sqlite3'))]
            before_data = {}
            for source in databases:
                relative = source.relative_to(DATA)
                target = backup / 'data' / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as src, sqlite3.connect(target) as dst:
                    src.backup(dst)
                target.chmod(0o600)
                before_data[str(relative)] = fingerprint(target)
            original_files = {str(p.relative_to(DATA)): digest(p)
                              for p in DATA.rglob('*') if p.is_file() and p.suffix in ('.wav', '.mp3')}
            baseline = {'previous': str(previous), 'services': before_services, 'config': before_config,
                        'data': before_data, 'audio': original_files, 'timers': timer_states}
            (backup / 'baseline.json').write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
            run(PYTHON, '-B', 'deploy/migrate_book_modes.py', '--data', str(DATA), cwd=release,
                env=environment(), user=identity.pw_uid, group=identity.pw_gid, extra_groups=[])
            switch(release)
            run('systemctl', 'start', 'lifepages.service')
            for _ in range(40):
                if health('http://127.0.0.1:8041'):
                    break
                time.sleep(.25)
            assert health('http://127.0.0.1:8041')
            run(PYTHON, '-B', 'deploy/smoke_book_modes_release.py', '--base',
                'https://onesay.top/lifepages', '--data', str(DATA), cwd=release)
            assert before_services == services(), 'An unrelated service changed'
            assert before_config == {p: digest(p) for p in CONFIG}, 'Configuration changed'
            for name, expected in before_data.items():
                current = fingerprint(DATA / name)
                assert set(expected).issubset(current), 'An existing table disappeared'
                assert all(current[table] == value for table, value in expected.items()), 'Existing data changed'
                extras = set(current) - set(expected)
                assert extras.issubset(MODE_TABLES), 'Unexpected schema addition'
                assert all(current[table]['rows'] == 0 for table in extras), 'Migration wrote existing-account metadata'
            assert all(digest(DATA / name) == expected for name, expected in original_files.items()), 'Original audio changed'
            assert set((DATA / 'accounts').glob('*/lifepages.sqlite3')) == set(databases[1:]), 'Synthetic account remains'
            for name, value in manifest['files'].items():
                assert digest(release / name) == value
            report = {'status': 'DEPLOYMENT_OK', 'release': str(release), 'previous': str(previous),
                      'backup': str(backup), 'account_databases': len(databases) - 1,
                      'unchanged_existing_data': True, 'authorized_additive_mode_tables': sorted(MODE_TABLES), 'unchanged_original_audio': True,
                      'unchanged_other_services': True, 'unchanged_configuration': True,
                      'manifest': manifest}
            (backup / 'deployment.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
            print(json.dumps({k: v for k, v in report.items() if k != 'manifest'}, ensure_ascii=False), flush=True)
        except BaseException:
            if stopped:
                if (BASE / 'current').resolve() != previous:
                    switch(previous)
                run('systemctl', 'restart', 'lifepages.service')
                print('ROLLED_BACK_CODE_ONLY; user data was not restored or overwritten', flush=True)
            raise
        finally:
            for timer, was_active in timer_states.items():
                if was_active:
                    run('systemctl', 'start', timer)


if __name__ == '__main__':
    main()
