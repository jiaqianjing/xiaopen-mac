#!/usr/bin/env python3
"""Prepare a notarized draft, record real acceptance, then explicitly publish it."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

import release_evidence as evidence
from release_policy import plan_release, ReleasePolicyError

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+')


class ReleaseError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(args, *, data=None, optional=False):
    env = dict(os.environ, GIT_NO_REPLACE_OBJECTS='1', GIT_OPTIONAL_LOCKS='0', GH_HOST='github.com')
    for key in ('GH_DEBUG', 'GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_CURL_VERBOSE'):
        env.pop(key, None)
    result = subprocess.run([str(a) for a in args], cwd=ROOT, input=data, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode and not optional:
        raise ReleaseError(f'{args[0]} failed: {result.stderr.strip()[:600]}')
    return result


def git(*args):
    return run(['git', '--no-pager', '--literal-pathspecs', *args]).stdout.strip()


def api(repo, endpoint, *, method='GET', body=None, missing=False):
    args = ['gh', 'api', f'repos/{repo}/{endpoint}', '--hostname', 'github.com', '--method', method]
    if body is not None:
        args += ['--input', '-']
    r = run(args, data=json.dumps(body) if body is not None else None, optional=missing)
    if r.returncode:
        if missing and 'HTTP 404' in r.stderr:
            return None
        raise ReleaseError(f'GitHub API failed: {r.stderr.strip()[:600]}')
    return json.loads(r.stdout) if r.stdout.strip() else None


def repository():
    remote = git('remote', 'get-url', 'origin')
    m = re.fullmatch(r'(?:git@github\.com:|https://github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?', remote)
    need(m is not None, 'origin must identify the intended github.com repository, without embedded credentials')
    return m[1]


def info():
    p = ROOT / 'Resources/Info.plist'
    d = plistlib.loads(p.read_bytes())
    version, build = d['CFBundleShortVersionString'], d['CFBundleVersion']
    need(isinstance(version, str) and VERSION.fullmatch(version), 'Info.plist needs a stable x.y.z version')
    need(isinstance(build, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build), 'Invalid bundle build number')
    return version, build


def clean_source(expected=None):
    need(not git('status', '--porcelain', '--untracked-files=normal'), 'Commit source changes first; use a clean release worktree')
    head = git('rev-parse', 'HEAD')
    need(expected is None or head == expected, 'Source commit changed; existing candidate cannot be reused')
    return head


def write_json(path, value):
    path = Path(path)
    need(not path.is_symlink(), f'Refusing symlink state file: {path.name}')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False, encoding='utf-8') as f:
        name = f.name
        os.chmod(name, 0o600)
        json.dump(value, f, indent=2, ensure_ascii=True, allow_nan=False)
        f.write('\n')
    os.replace(name, path)


def load(path):
    need(path.is_file() and not path.is_symlink(), f'Missing regular state file: {path.name}')
    return json.loads(path.read_text())


def session_dir(args):
    version, _ = info()
    raw = Path(args.session) if args.session else ROOT / 'build/releases' / f'v{version}'
    need(not raw.is_symlink(), 'Session directory cannot be a symlink')
    p = raw.resolve()
    need(not p.is_relative_to(ROOT) or p.is_relative_to(ROOT / 'build'), 'Keep local release records under ignored build/, or outside the repository')
    return p


@contextmanager
def locked(session):
    build = ROOT / 'build'
    need(not build.is_symlink(), 'build/ cannot be a symlink')
    build.mkdir(exist_ok=True)
    session.mkdir(parents=True, exist_ok=True, mode=0o700)
    session.chmod(0o700)
    lock = build / '.release-automation.lock'
    need(not lock.is_symlink(), 'Lock cannot be a symlink')
    with lock.open('a') as f:
        os.chmod(lock, 0o600)
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError('Another release operation is running in this worktree')
        yield


def remote_tag(repo, tag, *, missing=False):
    need(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag), 'Baseline and target tags must be vX.Y.Z')
    ref = api(repo, f'git/ref/tags/{tag}', missing=missing)
    if ref is None:
        return None
    obj = ref['object']
    for _ in range(5):
        if obj['type'] == 'commit':
            return obj['sha']
        need(obj['type'] == 'tag', 'Unexpected GitHub tag object')
        obj = api(repo, f'git/tags/{obj["sha"]}')['object']
    raise ReleaseError('Too many annotated-tag indirections')


def baseline(repo, tag, *, published_candidate=None):
    need(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag), 'Use a published vX.Y.Z baseline tag')
    release = api(repo, f'releases/tags/{tag}')
    need(not release['draft'] and not release['prerelease'] and release['tag_name'] == tag, 'Baseline must be a public stable Release')
    latest = api(repo, 'releases/latest')
    need(latest['tag_name'] == tag or latest['id'] == published_candidate, 'Baseline is no longer Latest; re-plan against the current release')
    remote = remote_tag(repo, tag)
    local = run(['git', 'rev-parse', '--verify', '--end-of-options', tag + '^{commit}'], optional=True)
    if local.returncode:
        run(['git', 'fetch', 'origin', 'tag', tag])
        local = run(['git', 'rev-parse', '--verify', '--end-of-options', tag + '^{commit}'])
    need(local.stdout.strip() == remote, 'Local baseline tag differs from GitHub; do not overwrite it')
    return release


def source_is_integrated(repo, source):
    remote = api(repo, 'git/ref/heads/main')['object']['sha']
    run(['git', 'fetch', 'origin', 'main'])
    need(git('rev-parse', 'FETCH_HEAD') == remote, 'main moved during verification; retry')
    r = run(['git', 'merge-base', '--is-ancestor', source, remote], optional=True)
    need(r.returncode == 0, 'Release source must already be merged into origin/main')


def current_ci(repo, source):
    runs = api(repo, f'actions/workflows/ci.yml/runs?head_sha={source}&per_page=100')['workflow_runs']
    matches = [r for r in runs if r['head_sha'] == source]
    need(bool(matches), 'No CI run for this exact source; push and merge the version commit first')
    latest = max(matches, key=lambda r: (r.get('updated_at', r['created_at']), r['id']))
    need(latest['status'] == 'completed' and latest['conclusion'] == 'success', 'Latest CI for this exact source has not passed')
    return {'id': latest['id'], 'headCommit': source, 'url': latest['html_url'], 'conclusion': 'success'}


def find_release(repo, tag):
    matches = []
    for page in range(1, 101):
        items = api(repo, f'releases?per_page=100&page={page}')
        matches.extend(r for r in items if r['tag_name'] == tag)
        if len(items) < 100:
            break
    else:
        raise ReleaseError('Cannot safely enumerate releases')
    need(len(matches) <= 1, 'Multiple releases use this tag; resolve the conflict manually')
    return matches[0] if matches else None


def marker(progress):
    return f'<!-- xiaopen-release-session:{progress["ownerID"]} -->'


def owned_release(state, progress, *, allow_published=False):
    r = api(state['repository'], f'releases/{state["releaseID"]}')
    need(r['id'] == state['releaseID'] and r['tag_name'] == state['tag'] and marker(progress) in r['body'], 'Release ownership/session mismatch; no changes made')
    need(r['target_commitish'] == state['sourceCommit'] and not r['prerelease'], 'Remote release source/type changed')
    need(r['draft'] or allow_published, 'Release is already public; prepare cannot alter it')
    return r


def check_asset(asset, record):
    need(asset.get('state') == 'uploaded' and asset.get('size') == record['sizeBytes'] and asset.get('digest') == 'sha256:' + record['sha256'], f'Remote asset differs: {asset.get("name")}; refusing overwrite')


def verify_assets(state, release, *, complete=False):
    expected = {Path(f['path']).name: f for f in state['assets']}
    need(len(expected) == len(state['assets']), 'Duplicate local asset names')
    seen = set()
    for asset in release['assets']:
        name = asset['name']
        need(name not in seen, 'Duplicate remote asset names')
        seen.add(name)
        if name == 'verification.json':
            if complete:
                record = state.get('metadataAsset')
                need(record and asset['id'] == record['id'], 'Verification asset identity changed')
                check_asset(asset, record)
            continue
        need(name in expected, f'Unreviewed remote asset: {name}')
        check_asset(asset, expected[name])
    if complete:
        need(set(expected) <= seen and 'verification.json' in seen, 'Draft upload is incomplete')


def upload(state, path):
    run(['gh', 'release', 'upload', state['tag'], str(path), '--repo', 'github.com/' + state['repository']])


def ensure_draft(state, progress, session):
    if state.get('releaseID') is not None:
        owned_release(state, progress)
        return
    existing = find_release(state['repository'], state['tag'])
    need(existing is None or (existing['draft'] and marker(progress) in existing['body'] and existing['target_commitish'] == state['sourceCommit']), 'Conflicting remote release; no overwrite')
    if existing is None:
        existing = api(state['repository'], 'releases', method='POST', body={'tag_name': state['tag'], 'target_commitish': state['sourceCommit'], 'name': f'XiaoPen {state["version"]}', 'body': notes(state, progress), 'draft': True, 'prerelease': False})
    state['releaseID'] = existing['id']
    write_json(session / 'state.json', state)


def ensure_template(state, session):
    path = session / 'manual-checks.json'
    need(not path.is_symlink(), 'Manual template cannot be a symlink')
    if not path.exists():
        write_json(path, evidence.manual_template(state))


def notes(state, progress):
    text = Path(state['releaseNotes']['path']).read_text().rstrip()
    rows = '\n'.join(f'- {k}: ' + ('passed' if state['confirmations'].get(k, {}).get('result') == 'pass' else 'pending') for k in state['plan']['requiredChecks'])
    d = state['automatic']['distribution']
    return f'{text}\n\n### Release verification\n\nVersion: {state["version"]} ({state["build"]}) · {state["plan"]["tier"]}\n\nSource: `{state["sourceCommit"]}`\n\nDeveloper ID team: `{d["teamID"]}`\n\nApp Apple submission: `{d["submissions"]["app"]["jobID"]}` — Accepted\n\nDMG Apple submission: `{d["submissions"]["dmg"]["jobID"]}` — Accepted\n\nSHA-256: `{state["artifact"]["sha256"]}`\n\n{rows}\n\nNormal privacy and Keychain permissions still apply. Fresh installation and physical audio are separate checks. System voice is selected manually; shortcut stop/replay does not verify natural-speech interruption.\n\n[verification.json](https://github.com/{state["repository"]}/releases/download/{state["tag"]}/verification.json)\n\n{marker(progress)}\n'


def sync_draft(state, progress, session):
    release = owned_release(state, progress)
    verify_assets(state, release)
    by_name = {a['name']: a for a in release['assets']}
    for f in state['assets']:
        if Path(f['path']).name not in by_name:
            upload(state, Path(f['path']))
    sync_metadata(state, progress, session)
    r = api(state['repository'], f'releases/{state["releaseID"]}', method='PATCH', body={'body': notes(state, progress)})
    state['draftURL'] = r['html_url']
    write_json(session / 'state.json', state)
    verify_assets(state, owned_release(state, progress), complete=True)


def sync_metadata(state, progress, session):
    release = owned_release(state, progress, allow_published=True)
    path = session / 'public/verification.json'
    write_json(path, evidence.public_verification(state))
    desired = evidence.file_record(path)
    found = [a for a in release['assets'] if a['name'] == path.name]
    need(len(found) <= 1, 'Duplicate verification assets')
    if found and found[0].get('digest') == 'sha256:' + desired['sha256'] and found[0].get('size') == desired['sizeBytes']:
        state['metadataAsset'] = {'id': found[0]['id'], **desired}
        write_json(session / 'state.json', state)
        return
    if found:
        old = state.get('metadataAsset')
        need(old and found[0]['id'] == old['id'], 'Unknown verification asset; refusing replacement')
        check_asset(found[0], old)
        api(state['repository'], f'releases/assets/{found[0]["id"]}', method='DELETE')
    upload(state, path)
    refreshed = owned_release(state, progress, allow_published=True)
    item = next(a for a in refreshed['assets'] if a['name'] == path.name)
    check_asset(item, desired)
    state['metadataAsset'] = {'id': item['id'], **desired}
    write_json(session / 'state.json', state)


def logged(args, path):
    print(f'Running {args[0]}; log: {path}', flush=True)
    with path.open('w') as f:
        os.chmod(path, 0o600)
        r = subprocess.run([str(a) for a in args], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    need(r.returncode == 0, f'{args[0]} failed; review retained log {path.name}')


def prepare(args, session):
    source = clean_source()
    repo, (version, build) = repository(), info()
    baseline(repo, args.base)
    need(tuple(map(int, version.split('.'))) > tuple(map(int, args.base[1:].split('.'))), 'Bump and commit the next version first; a published version cannot be repackaged')
    source_is_integrated(repo, source)
    ci = current_ci(repo, source)
    plan = plan_release(ROOT, args.base, requested_tier=args.tier)
    need(plan['binaryReleaseAllowed'], 'No binary inputs changed; no new release is needed')
    config = {'repository': repo, 'sourceCommit': source, 'version': version, 'build': build, 'tag': f'v{version}', 'plan': plan, 'signIdentity': args.sign_identity, 'notaryProfile': args.notary_profile, 'notaryKeychain': args.notary_keychain, 'notaryViaXcode': not bool(args.notary_profile)}
    progress_path = session / 'prepare.json'
    if progress_path.exists():
        progress = load(progress_path)
        need(progress['config'] == config, 'Session source, plan or signing options changed; do not reuse its acceptance')
        if args.notes_file:
            need(evidence.file_record(args.notes_file)['sha256'] == progress['releaseNotes']['sha256'], 'Requested release notes changed; do not reuse existing acceptance')
    else:
        need(find_release(repo, config['tag']) is None, 'A release already uses this version; refusing adoption or overwrite')
        need(remote_tag(repo, config['tag'], missing=True) in (None, source), 'Target tag points to another commit')
        progress = {'ownerID': str(uuid.uuid4()), 'config': config}
        if args.notes_file:
            content = Path(args.notes_file).read_text()
        else:
            changelog = (ROOT / 'CHANGELOG.md').read_text()
            m = re.search(rf'^## {re.escape(version)}(?:\s|$).*?(?=^## |\Z)', changelog, re.M | re.S)
            need(m is not None, 'Add the next version to CHANGELOG.md before preparing')
            content = m[0]
        need(not (session / 'notes-source.md').exists() and not (session / 'notes-source.md').is_symlink(), 'Unowned notes file in session; use an empty session directory')
        (session / 'notes-source.md').write_text(content)
        (session / 'notes-source.md').chmod(0o600)
        progress['releaseNotes'] = evidence.file_record(session / 'notes-source.md')
        write_json(progress_path, progress)
    if (session / 'state.json').exists():
        state = load(session / 'state.json')
        validate_local(state, progress)
        ensure_draft(state, progress, session)
        sync_draft(state, progress, session)
        ensure_template(state, session)
        show_status(state, session)
        return
    if 'tests' not in progress:
        stamp = uuid.uuid4().hex[:8]
        metal, metallib = run(['xcrun', '--find', 'metal']).stdout.strip(), run(['xcrun', '--find', 'metallib']).stdout.strip()
        commands = [(['swift', 'test', '--parallel', '-Xxcbuild', f'METAL_EXEC={metal}', '-Xxcbuild', f'METALLIB_EXEC={metallib}'], 'swift'), ([sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_release*.py'], 'python_release')]
        files = []
        for cmd, kind in commands:
            path = session / f'{kind}-{stamp}.log'
            logged(cmd, path)
            files.append(evidence.file_record(path))
        progress['tests'] = {'passed': True, 'sourceCommit': source, 'commands': [{'kind': k, 'exitCode': 0} for _, k in commands], 'files': files, 'ci': ci}
        write_json(progress_path, progress)
    for f in progress['tests']['files']:
        need(evidence.file_record(f['path']) == f, 'Saved test evidence changed')
    if progress.get('buildStarted') and not args.retry_build:
        raise ReleaseError('Previous build/notarization was interrupted. Review retained UUIDs/logs first; --retry-build explicitly starts a new attempt')
    before = set((ROOT / 'build/notarization').glob('*')) if (ROOT / 'build/notarization').exists() else set()
    progress['buildStarted'] = True
    write_json(progress_path, progress)
    command = [ROOT / 'scripts/build_app.sh', '--release']
    if args.notary_profile:
        command += ['--notary-profile', args.notary_profile]
        if args.notary_keychain:
            command += ['--notary-keychain', args.notary_keychain]
    else:
        command += ['--notary-via-xcode']
    if args.sign_identity:
        command += ['--sign-identity', args.sign_identity]
    logged(command, session / f'build-{uuid.uuid4().hex[:8]}.log')
    clean_source(source)
    fresh = set((ROOT / 'build/notarization').glob('*')) - before
    need(len(fresh) == 1, 'Expected exactly one new notarization evidence directory from this build')
    raw = fresh.pop()
    artifact = ROOT / f'build/XiaoPen-{version}.dmg'
    distribution = evidence.collect_distribution_evidence(raw, artifact, source, version, build)
    retained = session / 'raw-notarization'
    need(not retained.is_symlink(), 'Retained evidence directory cannot be a symlink')
    retained.mkdir(exist_ok=True, mode=0o700)
    for record in distribution['files']:
        target = retained / Path(record['path']).name
        need(not target.is_symlink(), 'Retained evidence cannot be a symlink')
        shutil.copy2(record['path'], target)
        target.chmod(0o600)
    distribution = evidence.collect_distribution_evidence(retained, artifact, source, version, build)
    distribution['originalEvidenceDirectory'] = str(raw)
    public = session / 'public'
    need(not public.is_symlink(), 'Public staging directory cannot be a symlink')
    public.mkdir(exist_ok=True, mode=0o700)
    names = (artifact.name, 'SHA256SUMS', 'app-notary-log.json', 'dmg-notary-log.json')
    need(all(p.name in names and p.is_file() and not p.is_symlink() for p in public.iterdir()), 'Unreviewed files in public staging directory')
    shutil.copy2(artifact, public / artifact.name)
    shutil.copy2(raw / 'SHA256SUMS', public / 'SHA256SUMS')
    for kind in ('app', 'dmg'):
        write_json(public / f'{kind}-notary-log.json', evidence.public_notary_log(raw / f'{kind}-notary-log.json'))
    state = evidence.new_state(repository=repo, version=version, build_number=build, plan=plan, artifact=public / artifact.name, automatic={'tests': progress['tests'], 'distribution': distribution})
    state['releaseNotes'] = progress['releaseNotes']
    state['assets'] = [evidence.file_record(public / name) for name in names]
    write_json(session / 'state.json', state)
    ensure_draft(state, progress, session)
    sync_draft(state, progress, session)
    ensure_template(state, session)
    show_status(state, session)


def validate_local(state, progress):
    clean_source(state['sourceCommit'])
    need(repository() == state['repository'] and info() == (state['version'], state['build']), 'Repository or version changed')
    planned = plan_release(ROOT, state['plan']['baseline']['ref'], requested_tier=state['plan']['tier'])
    need(planned == state['plan'], 'Acceptance plan changed')
    need(progress['config']['plan'] == planned and progress['config']['sourceCommit'] == state['sourceCommit'], 'Session provenance differs')
    need(state.get('releaseNotes') == progress['releaseNotes'], 'Release notes provenance changed')
    names = [Path(f['path']).name for f in state.get('assets', [])]
    need(len(names) == 4 and set(names) == {state['artifact']['filename'], 'SHA256SUMS', 'app-notary-log.json', 'dmg-notary-log.json'}, 'Public assets must be exactly the reviewed four files')
    r = evidence.readiness(state)
    need(not r['errors'], '; '.join(r['errors']))


def show_status(state, session):
    r = evidence.readiness(state)
    print(json.dumps({'session': str(session), 'tag': state['tag'], 'sourceCommit': state['sourceCommit'], 'tier': state['plan']['tier'], 'artifactSHA256': state['artifact']['sha256'], 'draftURL': state.get('draftURL'), 'manualTemplate': str(session / 'manual-checks.json'), **r, 'publication': state.get('publication')}, indent=2))


def record_confirmations(args, session):
    state, progress = load(session / 'state.json'), load(session / 'prepare.json')
    validate_local(state, progress)
    verify_assets(state, owned_release(state, progress), complete=True)
    need(not state.get('publication', {}).get('published'), 'Published candidate acceptance cannot be edited')
    bundle = load(Path(args.from_file).resolve())
    need(bundle.get('binding') == evidence.binding(state), 'Template binding is stale')
    records = bundle.get('results')
    need(isinstance(records, list) and bool(records), 'No actual observations supplied')
    ids = [r.get('check') for r in records if r.get('result') is not None]
    need(len(ids) == len(set(ids)), 'Duplicate acceptance check records')
    need(bool(ids), 'Template remains unfilled; no checks were confirmed')
    updated = state
    for record in records:
        if record.get('result') is not None:
            updated = evidence.confirm(updated, record)
    # Save only after the entire supplied batch validates.
    write_json(session / 'state.json', updated)
    sync_draft(updated, progress, session)
    show_status(updated, session)


def anonymous_download(url, target, expected):
    need(not target.is_symlink(), 'Download target cannot be a symlink')
    temporary = target.with_name(target.name + '.part')
    need(not temporary.is_symlink(), 'Partial download cannot be a symlink')
    r = run(['curl', '-q', '--no-netrc', '--header', 'Authorization:', '--header', 'Cookie:', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '20', '--max-time', '600', '--output', str(temporary), '--write-out', '%{http_code}', url])
    need(r.stdout.strip() == '200', 'Public download did not return HTTP 200')
    actual = evidence.file_record(temporary)
    need(actual['sha256'] == expected['sha256'] and actual['sizeBytes'] == expected['sizeBytes'], f'Public download differs: {target.name}')
    os.replace(temporary, target)
    return {'filename': target.name, 'httpStatus': 200, 'sha256': actual['sha256'], 'sizeBytes': actual['sizeBytes'], 'authenticationUsed': False}


def publish(args, session):
    state, progress = load(session / 'state.json'), load(session / 'prepare.json')
    validate_local(state, progress)
    release = owned_release(state, progress, allow_published=True)
    verify_assets(state, release)
    immutable_names = {Path(f['path']).name for f in state['assets']}
    need(immutable_names <= {a['name'] for a in release['assets']}, 'Immutable draft upload is incomplete')
    baseline(state['repository'], state['plan']['baseline']['ref'], published_candidate=state['releaseID'] if not release['draft'] else None)
    source_is_integrated(state['repository'], state['sourceCommit'])
    current_ci(state['repository'], state['sourceCommit'])
    target = remote_tag(state['repository'], state['tag'], missing=True)
    need(target in (None, state['sourceCommit']), 'Target tag changed; no publication attempted')
    if release['draft']:
        state = evidence.approve(state, args.approve_sha, args.approver)
        write_json(session / 'state.json', state)
        sync_metadata(state, progress, session)
        # Read immutable assets and source again immediately before the public action.
        validate_local(state, progress)
        evidence.require_approval(state)
        verify_assets(state, owned_release(state, progress), complete=True)
        release = api(state['repository'], f'releases/{state["releaseID"]}', method='PATCH', body={'body': notes(state, progress), 'draft': False, 'prerelease': False, 'make_latest': 'true'})
    else:
        need(args.approve_sha == state['artifact']['sha256'], 'Use the current full artifact SHA to resume verification')
        evidence.require_approval(state)
        # Metadata replacement can be interrupted after DELETE or after upload.
        # Reconcile only our known metadata; never replace immutable assets.
        sync_metadata(state, progress, session)
        verify_assets(state, owned_release(state, progress, allow_published=True), complete=True)
    need(not release['draft'] and not release['prerelease'], 'GitHub has not confirmed publication')
    need(remote_tag(state['repository'], state['tag']) == state['sourceCommit'], 'Published tag/source mismatch')
    need(api(state['repository'], 'releases/latest')['id'] == state['releaseID'], 'Published Release is not Latest')
    state['publication'] = {'published': True, 'url': release['html_url'], 'publishedAtUTC': release['published_at'], 'publicDownloadsVerified': False}
    write_json(session / 'state.json', state)
    downloads = session / 'public-download'
    downloads.mkdir(exist_ok=True, mode=0o700)
    proofs = []
    for f in state['assets']:
        name = Path(f['path']).name
        url = f'https://github.com/{state["repository"]}/releases/download/{state["tag"]}/{name}'
        proofs.append(anonymous_download(url, downloads / name, f))
    need((downloads / 'SHA256SUMS').read_text() == f'{state["artifact"]["sha256"]}  {state["artifact"]["filename"]}\n', 'Published checksum content differs')
    state['publication']['publicDownloadsVerified'] = True
    write_json(session / 'public-download-verification.json', {'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'files': proofs})
    write_json(session / 'state.json', state)
    sync_metadata(state, progress, session)
    final = evidence.file_record(session / 'public/verification.json')
    url = f'https://github.com/{state["repository"]}/releases/download/{state["tag"]}/verification.json?sha256={final["sha256"]}'
    anonymous_download(url, downloads / 'verification.json', final)
    state['publication']['complete'] = True
    write_json(session / 'state.json', state)
    show_status(state, session)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'prepare', 'status', 'confirm', 'publish'):
        p = sub.add_parser(name)
        if name in ('plan', 'prepare'):
            p.add_argument('--base', required=True)
            p.add_argument('--tier', choices=('standard', 'full'))
        if name != 'plan':
            p.add_argument('--session', type=Path)
        if name == 'prepare':
            auth = p.add_mutually_exclusive_group()
            auth.add_argument('--notary-via-xcode', action='store_true')
            auth.add_argument('--notary-profile')
            p.add_argument('--notary-keychain')
            p.add_argument('--sign-identity')
            p.add_argument('--notes-file', type=Path)
            p.add_argument('--retry-build', action='store_true', help='Explicit new build attempt after reviewing an interrupted notarization')
        if name == 'confirm':
            p.add_argument('--from', dest='from_file', required=True, type=Path)
        if name == 'publish':
            p.add_argument('--approve-sha', required=True)
            p.add_argument('--approver', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'plan':
            if git('status', '--porcelain', '--untracked-files=normal'):
                print('Notice: uncommitted changes are excluded from this commit plan.', file=sys.stderr)
            print(json.dumps(plan_release(ROOT, args.base, requested_tier=args.tier), indent=2, ensure_ascii=True))
            return
        if args.command == 'prepare':
            need(not args.notary_keychain or args.notary_profile, '--notary-keychain requires --notary-profile')
        session = session_dir(args)
        with locked(session):
            if args.command == 'prepare':
                prepare(args, session)
            elif args.command == 'status':
                show_status(load(session / 'state.json'), session)
            elif args.command == 'confirm':
                record_confirmations(args, session)
            else:
                publish(args, session)
    except (ReleaseError, ReleasePolicyError, evidence.EvidenceError, OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(2, f'Release stopped: {exc}\n')


if __name__ == '__main__':
    main()
