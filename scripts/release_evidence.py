#!/usr/bin/env python3
"""Artifact-bound release evidence. Local records are not a user-authentication system."""
from __future__ import annotations

import copy
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path


class EvidenceError(ValueError):
    pass


CHECKS = {
    'clean_install': {'description': 'Browser download, preserved quarantine, normal fresh first launch and About version/build readback', 'observed': {'browserDownloaded': True, 'downloadedSHA256': '$ARTIFACT_SHA256', 'freshEnvironment': True, 'quarantinePreserved': True, 'gatekeeperEnabled': True, 'sipEnabled': True, 'normalLaunch': True, 'candidateVersion': '$VERSION', 'candidateBuild': '$BUILD', 'usedOpenAnyway': False}},
    'upgrade_retention': {'description': 'Actual old-version upgrade preserves settings, non-empty reminder, models and normal credential reuse', 'observed': {'previousVersion': '$NONEMPTY', 'candidateVersion': '$VERSION', 'oldVersionActuallyRan': True, 'settingsRetained': True, 'nonEmptyReminderRetained': True, 'modelsRetained': True, 'credentialsReusedNormally': True}},
    'voice_smoke': {'description': 'Physical-device wake, question and clear audible reply', 'observed': {'physicalMachine': True, 'wakeAndAudibleReply': True, 'heardClearly': True, 'dailySettingsRestored': True}},
    'offline_first_launch': {'description': 'Offline normal first launch on a separate never-opened clean branch', 'observed': {'freshBeforeAnyAssessment': True, 'externalNetworkUnavailable': True, 'downloadedSHA256': '$ARTIFACT_SHA256', 'quarantinePreserved': True, 'gatekeeperEnabled': True, 'sipEnabled': True, 'normalLaunch': True, 'usedOpenAnyway': False}},
    'permission_recovery': {'description': 'Actual microphone and speech denial, recovery and authorized app readback', 'observed': {'microphoneDeniedAndRecovered': True, 'speechDeniedAndRecovered': True, 'appReadbackAuthorized': True}},
    'wake_modes': {'description': 'Physical paused and continuous wake/question cases', 'observed': {'physicalMachine': True, 'pausedWakeAndReply': True, 'continuousWakeAndReply': True, 'heardClearly': True}},
    'follow_up': {'description': 'Physical follow-up reply without another wake phrase', 'observed': {'physicalMachine': True, 'withoutWakeReply': True, 'heardClearly': True}},
    'local_tts': {'description': 'Ready local TTS model and actual clear playback', 'observed': {'physicalMachine': True, 'modelReady': True, 'heardClearly': True}},
    'system_voice': {'description': 'Manual system-voice selection and complete clear preview; no automatic fallback claim', 'observed': {'physicalMachine': True, 'manuallySelected': True, 'completeAndClear': True}},
    'shortcut_replay': {'description': 'Global shortcut stops playback and complete replay recovers; no natural-speech interruption claim', 'observed': {'physicalMachine': True, 'stoppedMidPlayback': True, 'replayCompleteAndClear': True}},
}
CORE = ('clean_install', 'upgrade_retention', 'voice_smoke')
FULL = CORE + tuple(k for k in CHECKS if k not in CORE)
SHA = re.compile(r'[a-f0-9]{64}')
COMMIT = re.compile(r'[a-f0-9]{40}(?:[a-f0-9]{24})?')
JOB = re.compile(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}')


def _need(condition, message):
    if not condition:
        raise EvidenceError(message)


def _now():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def file_record(path):
    p = Path(path).absolute()
    _need(p.is_file() and not p.is_symlink(), f'Expected a regular evidence file: {p.name}')
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return {'path': str(p), 'sizeBytes': p.stat().st_size, 'sha256': h.hexdigest()}


def _verify_file(record):
    _need(isinstance(record, dict) and isinstance(record.get('path'), str), 'Missing evidence file record')
    actual = file_record(record['path'])
    _need(actual == record, f'Evidence file changed: {Path(record["path"]).name}')


def public_notary_log(path):
    """An intentionally small public excerpt; preserve the original log locally."""
    raw = json.loads(Path(path).read_text())
    _need(raw.get('status') == 'Accepted' and type(raw.get('statusCode')) is int and raw['statusCode'] == 0, 'Apple has not accepted the submission')
    _need(JOB.fullmatch(str(raw.get('jobId', ''))), 'Missing Apple submission UUID')
    _need(raw.get('issues') in (None, []), 'Apple diagnostics require review before release')
    tickets = raw.get('ticketContents')
    _need(isinstance(tickets, list) and tickets, 'Apple log has no tickets')
    clean = []
    for t in tickets:
        path = t.get('path', '')
        _need(isinstance(path, str) and not path.startswith('/') and '..' not in Path(path).parts and '://' not in path, 'Unsafe path in Apple ticket')
        _need(re.fullmatch(r'[a-fA-F0-9]{40,64}', str(t.get('cdhash', ''))), 'Missing Apple ticket digest')
        _need(t.get('digestAlgorithm') == 'SHA-256', 'Unexpected ticket digest algorithm')
        _need('arch' not in t or t['arch'] in (None, 'arm64', 'arm64e', 'x86_64', 'x86_64h'), 'Unexpected ticket architecture')
        clean.append({k: t[k] for k in ('path', 'digestAlgorithm', 'cdhash', 'arch') if k in t})
    return {'jobId': raw['jobId'], 'status': 'Accepted', 'statusCode': 0, 'issues': None, 'ticketContents': clean}


def collect_distribution_evidence(evidence_dir, artifact, source_commit, version, build_number):
    e, a = Path(evidence_dir), Path(artifact)
    summary = (e / 'release-summary.txt').read_text()
    _need(f'Source commit: {source_commit}\n' in summary, 'Build source does not match this candidate')
    _need(f'Version: {version} ({build_number})\n' in summary, 'Build version does not match this candidate')
    team = re.search(r'^Team: ([A-Z0-9]{10})$', summary, re.M)
    identity = re.search(r'^Identity: Developer ID Application: .+ \(([A-Z0-9]{10})\)$', summary, re.M)
    _need(team and identity and team[1] == identity[1], 'Missing Developer ID team')
    _need('assessments enabled' in (e / 'gatekeeper-status.log').read_text().splitlines(), 'Gatekeeper was not enabled')
    required = ('release-summary.txt', 'SHA256SUMS', 'gatekeeper-status.log', 'signatures.log', 'app-entitlements.plist', 'app-entitlements-lint.log', 'app-codesign-stapled.log', 'app-stapler-validate.log', 'app-gatekeeper.log', 'dmg-codesign-stapled.log', 'dmg-stapler-validate.log', 'dmg-gatekeeper.log', 'dmg-integrity.log', 'mounted-app-codesign.log', 'mounted-app-stapler.log', 'mounted-app-gatekeeper.log', 'app-notary-log.json', 'dmg-notary-log.json')
    files = [file_record(e / name) for name in required]
    for name in ('app-syspolicy.log', 'mounted-app-syspolicy.log'):
        if (e / name).exists():
            files.append(file_record(e / name))
    art = file_record(a)
    _need((e / 'SHA256SUMS').read_text() == f'{art["sha256"]}  {a.name}\n', 'Final checksum does not match notarized build')
    code_hashes = {}
    # assert_release_signature records the actual codesign output. Its last
    # app entry is read from the verified, final mounted DMG, after Xcode export.
    for block in re.split(r'(?=^Executable=)', (e / 'signatures.log').read_text(), flags=re.M):
        executable = re.search(r'^Executable=(.+)$', block, re.M)
        cdhash = re.search(r'^CDHash=([a-fA-F0-9]{40,64})$', block, re.M)
        signed_team = re.search(r'^TeamIdentifier=(.+)$', block, re.M)
        if not (executable and cdhash and signed_team and signed_team[1] == team[1]):
            continue
        if executable[1].endswith('/XiaoPen.app/Contents/MacOS/XiaoPen'):
            code_hashes['app'] = cdhash[1].lower()
        elif Path(executable[1]).name == a.name:
            code_hashes['dmg'] = cdhash[1].lower()
    _need(set(code_hashes) == {'app', 'dmg'}, 'Missing app or DMG codesign digest evidence')
    submissions = {}
    for kind in ('app', 'dmg'):
        log = public_notary_log(e / f'{kind}-notary-log.json')
        name = a.name if kind == 'dmg' else 'XiaoPen.app'
        suffix = f'/XiaoPen.app/Contents/Resources/Distribution/{name}' if kind == 'dmg' else '/XiaoPen.app'
        _need(any((t['path'] == name or t['path'].endswith(suffix)) and t['cdhash'].lower() == code_hashes[kind] for t in log['ticketContents']), f'Apple ticket does not cover this signed {kind}')
        submissions[kind] = {'jobID': log['jobId'], 'status': 'Accepted', 'statusCode': 0}
    _need(submissions['app']['jobID'] != submissions['dmg']['jobID'], 'Expected separate app and final-DMG submissions')
    return {'passed': True, 'sourceCommit': source_commit, 'teamID': team[1], 'codeHashes': code_hashes, 'submissions': submissions, 'files': files}


def new_state(*, repository, version, build_number, plan, artifact, automatic, release_id=None):
    _need(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid GitHub repository')
    _need(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Expected a stable x.y.z version')
    _need(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(build_number)), 'Invalid bundle build number')
    art = file_record(artifact)
    state = {'schemaVersion': 1, 'runID': str(uuid.uuid4()), 'repository': repository, 'version': version, 'build': str(build_number), 'tag': f'v{version}', 'sourceCommit': plan['sourceCommit'], 'plan': copy.deepcopy(plan), 'artifact': {'filename': Path(artifact).name, **art}, 'automatic': copy.deepcopy(automatic), 'releaseID': release_id, 'confirmations': {}, 'approval': None, 'createdAtUTC': _now()}
    _validate_base(state)
    return state


def binding(state):
    keys = ('schemaVersion', 'runID', 'repository', 'version', 'build', 'tag', 'sourceCommit', 'plan', 'artifact', 'automatic', 'releaseID', 'releaseNotes', 'assets')
    return digest({k: state[k] for k in keys if k in state})


def _validate_base(state):
    _need(state.get('schemaVersion') == 1, 'Unsupported evidence schema')
    _need(isinstance(state.get('repository'), str) and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', state['repository']), 'Invalid GitHub repository')
    _need(isinstance(state.get('version'), str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', state['version']), 'Invalid version')
    _need(isinstance(state.get('build'), str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', state['build']), 'Invalid build number')
    _need(str(uuid.UUID(state['runID'])) == state['runID'], 'Invalid candidate run ID')
    _need(COMMIT.fullmatch(str(state.get('sourceCommit', ''))), 'Invalid source commit')
    plan = state.get('plan', {})
    tier = plan.get('tier')
    _need(tier in ('standard', 'full') and plan.get('binaryReleaseAllowed') is True, 'This change does not permit a new binary release')
    detected = plan.get('detectedTier', tier)
    _need(detected in ('standard', 'full') and not (detected == 'full' and tier != 'full'), 'Detected acceptance tier cannot be lowered')
    _need(plan.get('sourceCommit') == state['sourceCommit'], 'Plan/source mismatch')
    _need(COMMIT.fullmatch(str(plan.get('baseline', {}).get('commit', ''))), 'Invalid baseline commit')
    _need(plan.get('requiredChecks') == list(CORE if tier == 'standard' else FULL), 'Required acceptance checks were changed')
    _need(state.get('tag') == f'v{state["version"]}', 'Tag/version mismatch')
    art = state.get('artifact', {})
    _need(art.get('filename') == f'XiaoPen-{state["version"]}.dmg', 'Unexpected artifact name')
    _need(Path(art.get('path', '')).name == art['filename'], 'Artifact path/name mismatch')
    _verify_file({k: art.get(k) for k in ('path', 'sizeBytes', 'sha256')})
    if 'releaseNotes' in state:
        _verify_file(state['releaseNotes'])
    for f in state.get('assets', []):
        _verify_file(f)
    automatic = state.get('automatic', {})
    for kind in ('tests', 'distribution'):
        group = automatic.get(kind, {})
        _need(group.get('passed') is True and group.get('sourceCommit') == state['sourceCommit'], f'{kind} has not passed for this source')
        files = group.get('files')
        _need(isinstance(files, list) and bool(files), f'Missing {kind} evidence files')
        for f in files:
            _verify_file(f)
    commands = automatic['tests'].get('commands', [])
    _need({c.get('kind') for c in commands} >= {'swift', 'python_release'} and all(type(c.get('exitCode')) is int and c['exitCode'] == 0 for c in commands), 'Swift and Python release tests must pass')
    ci = automatic['tests'].get('ci', {})
    _need(type(ci.get('id')) is int and ci['id'] > 0 and ci.get('headCommit') == state['sourceCommit'] and ci.get('conclusion') == 'success', 'Missing successful exact-source GitHub CI')
    _need(ci.get('url') == f'https://github.com/{state["repository"]}/actions/runs/{ci["id"]}', 'Unexpected CI URL')
    dist = automatic['distribution']
    _need(re.fullmatch(r'[A-Z0-9]{10}', str(dist.get('teamID', ''))), 'Invalid signing team')
    for kind in ('app', 'dmg'):
        s = dist.get('submissions', {}).get(kind, {})
        _need(s.get('status') == 'Accepted' and s.get('statusCode') == 0 and JOB.fullmatch(str(s.get('jobID', ''))), f'Missing {kind} Apple acceptance')


def manual_template(state):
    _validate_base(state)
    return {'binding': binding(state), 'artifactSHA256': state['artifact']['sha256'], 'instructions': 'Perform the described checks on this exact downloaded candidate. Fill actual observations; do not infer audibility from logs. Never include credentials. Submit with confirm --from.', 'results': [{'binding': binding(state), 'check': check, 'description': CHECKS[check]['description'], 'result': None, 'tester': None, 'note': None, 'environment': None, 'observed': {k: None for k in CHECKS[check]['observed']}, 'evidence': []} for check in state['plan']['requiredChecks']]}


def _text(value, field, minimum=1):
    _need(isinstance(value, str) and minimum <= len(value.strip()) <= 4000, f'Missing or invalid {field}')


def _validate_confirmation(state, record):
    check = record.get('check')
    _need(check in state['plan']['requiredChecks'], 'Unknown or unrequired acceptance check')
    _need(record.get('binding') == binding(state), 'Confirmation belongs to a different source, plan or artifact')
    _need(record.get('result') in ('pass', 'fail'), 'Confirmation result must be pass or fail')
    for field in ('tester', 'note', 'environment'):
        _text(record.get(field), field)
    _need(isinstance(record.get('observed'), dict), 'Missing actual observations')
    stamp = datetime.fromisoformat(record.get('confirmedAtUTC', ''))
    _need(stamp.tzinfo is not None, 'Confirmation timestamp must include timezone')
    if record['result'] == 'pass':
        for key, expected in CHECKS[check]['observed'].items():
            actual = record['observed'].get(key)
            if expected == '$NONEMPTY':
                _text(actual, key)
                if key == 'previousVersion':
                    _need(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', actual), 'Previous version must be x.y.z')
                    _need(tuple(map(int, actual.split('.'))) < tuple(map(int, state['version'].split('.'))), 'Upgrade must start with an earlier version')
                    base = state['plan']['baseline']['ref']
                    if re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+', base):
                        _need(actual == base.removeprefix('v'), 'Upgrade must start with the declared baseline version')
            else:
                expected = state['artifact']['sha256'] if expected == '$ARTIFACT_SHA256' else state['version'] if expected == '$VERSION' else state['build'] if expected == '$BUILD' else expected
                _need(type(actual) is type(expected) and actual == expected, f'{check}: observation {key} has not passed')
    _need(isinstance(record.get('evidenceFiles'), list), 'Missing evidence file list')
    for f in record['evidenceFiles']:
        _verify_file(f)


def confirm(state, record):
    _validate_base(state)
    r = copy.deepcopy(record)
    paths = r.pop('evidence', [])
    _need(isinstance(paths, list) and all(isinstance(p, str) for p in paths), 'Evidence must list local file paths')
    r['evidenceFiles'] = [file_record(p) for p in paths]
    r['confirmedAtUTC'] = _now()
    _validate_confirmation(state, r)
    updated = copy.deepcopy(state)
    updated['confirmations'][r['check']] = r
    updated['approval'] = None
    return updated


def readiness(state):
    errors, pending = [], []
    try:
        _validate_base(state)
    except (EvidenceError, OSError, KeyError, TypeError, ValueError) as exc:
        errors.append(str(exc))
    if not errors:
        for check in state['plan']['requiredChecks']:
            record = state.get('confirmations', {}).get(check)
            if record is None:
                pending.append(check)
                continue
            try:
                _need(record.get('check') == check, 'Confirmation is stored under a different check')
                _validate_confirmation(state, record)
                if record['result'] != 'pass':
                    pending.append(check)
            except (EvidenceError, OSError, KeyError, TypeError, ValueError) as exc:
                pending.append(check)
                errors.append(f'{check}: {exc}')
    return {'ready': not errors and not pending, 'pending': pending, 'errors': errors, 'binding': binding(state)}


def _approval_binding(state):
    return digest({'candidate': binding(state), 'confirmations': state['confirmations']})


def approve(state, artifact_sha, approver):
    r = readiness(state)
    _need(r['ready'], f'Acceptance is incomplete: {r["pending"]}; {r["errors"]}')
    _need(state.get('releaseID') is not None, 'Candidate must be bound to a draft Release')
    _need(artifact_sha == state['artifact']['sha256'], 'Explicit approval must name the complete current DMG SHA-256')
    _text(approver, 'approver')
    updated = copy.deepcopy(state)
    updated['approval'] = {'binding': _approval_binding(state), 'artifactSHA256': artifact_sha, 'approver': approver, 'approvedAtUTC': _now()}
    return updated


def require_approval(state):
    _need(readiness(state)['ready'], 'Acceptance or evidence is no longer valid')
    a = state.get('approval') or {}
    _need(a.get('binding') == _approval_binding(state) and a.get('artifactSHA256') == state['artifact']['sha256'], 'Final publication approval is missing or stale')
    _text(a.get('approver'), 'approver')


def public_verification(state):
    r = readiness(state)
    _need(not r['errors'], 'Cannot export invalid candidate evidence')
    # Only fixed fields and digests leave the machine. Notes, operator names,
    # environment labels, paths and arbitrary command output remain local.
    submissions = {kind: {k: state['automatic']['distribution']['submissions'][kind][k] for k in ('jobID', 'status', 'statusCode')} for kind in ('app', 'dmg')}
    automatic_checks = {'localTestsPassed': state['automatic']['tests']['passed'], 'ci': {k: state['automatic']['tests']['ci'][k] for k in ('id', 'headCommit', 'url', 'conclusion')}}
    publication = state.get('publication', {})
    public_publication = {}
    for key in ('published', 'publicDownloadsVerified'):
        if key in publication:
            _need(type(publication[key]) is bool, 'Invalid publication status')
            public_publication[key] = publication[key]
    if 'url' in publication:
        _need(publication['url'] == f'https://github.com/{state["repository"]}/releases/tag/{state["tag"]}', 'Unexpected public release URL')
        public_publication['url'] = publication['url']
    if 'publishedAtUTC' in publication:
        stamp = datetime.fromisoformat(publication['publishedAtUTC'].replace('Z', '+00:00'))
        _need(stamp.tzinfo is not None, 'Invalid publication timestamp')
        public_publication['publishedAtUTC'] = publication['publishedAtUTC']
    return {'schemaVersion': 1, 'repository': state['repository'], 'version': state['version'], 'build': state['build'], 'tag': state['tag'], 'sourceCommit': state['sourceCommit'], 'baselineCommit': state['plan']['baseline']['commit'], 'tier': state['plan']['tier'], 'artifact': {k: state['artifact'][k] for k in ('filename', 'sha256', 'sizeBytes')}, 'teamID': state['automatic']['distribution']['teamID'], 'automaticChecks': automatic_checks, 'appleSubmissions': submissions, 'acceptance': {check: {'passed': check not in r['pending'] and not r['errors'], 'scope': CHECKS[check]['description'], 'confirmedAtUTC': state['confirmations'].get(check, {}).get('confirmedAtUTC')} for check in state['plan']['requiredChecks']}, 'allAcceptancePassed': r['ready'], 'publicationApproved': bool(state.get('approval')) and state['approval'].get('binding') == _approval_binding(state), 'scope': 'Fresh-environment installation and real physical audio are distinct checks. Manual system voice; shortcut stop/replay only. Does not claim natural-speech interruption or automated listening.', 'publication': public_publication}
