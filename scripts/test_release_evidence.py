#!/usr/bin/env python3
"""Fail-closed gates using disposable files, never a real release or credentials."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import release_evidence as e


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.artifact = self.root / 'XiaoPen-2.0.0.dmg'
        self.artifact.write_bytes(b'disposable artifact fixture')
        self.log = self.root / 'test.log'
        self.log.write_text('Fixture: subprocess returned zero, not a real signed build.\n')
        self.commit = 'a' * 40

    def state(self, tier='standard', release_id=123):
        plan = {'sourceCommit': self.commit, 'baseline': {'ref': 'v1.9.0', 'commit': 'b' * 40}, 'tier': tier, 'detectedTier': tier, 'binaryReleaseAllowed': True, 'requiredChecks': list(e.CORE if tier == 'standard' else e.FULL)}
        automatic = {'tests': {'passed': True, 'sourceCommit': self.commit, 'commands': [{'kind': 'swift', 'exitCode': 0}, {'kind': 'python_release', 'exitCode': 0}], 'files': [e.file_record(self.log)]}, 'distribution': {'passed': True, 'sourceCommit': self.commit, 'teamID': 'TESTTEAM01', 'submissions': {k: {'jobID': j, 'status': 'Accepted', 'statusCode': 0} for k, j in [('app', '11111111-1111-1111-1111-111111111111'), ('dmg', '22222222-2222-2222-2222-222222222222')]}, 'files': [e.file_record(self.log)]}}
        automatic['tests']['ci'] = {'id': 123, 'headCommit': self.commit, 'conclusion': 'success', 'url': 'https://github.com/example/xiaopen/actions/runs/123'}
        return e.new_state(repository='example/xiaopen', version='2.0.0', build_number='20', plan=plan, artifact=self.artifact, automatic=automatic, release_id=release_id)

    def confirmation(self, state, check):
        observed = {}
        for key, expected in e.CHECKS[check]['observed'].items():
            observed[key] = state['artifact']['sha256'] if expected == '$ARTIFACT_SHA256' else state['version'] if expected == '$VERSION' else state['build'] if expected == '$BUILD' else '1.9.0' if expected == '$NONEMPTY' else expected
        return {'binding': e.binding(state), 'check': check, 'result': 'pass', 'tester': 'Fixture operator', 'note': 'Explicit fixture observations, not a real acceptance result', 'environment': 'Disposable fixture environment', 'observed': observed, 'evidence': []}

    def accepted(self, state=None):
        state = state or self.state()
        for check in state['plan']['requiredChecks']:
            state = e.confirm(state, self.confirmation(state, check))
        return state

    def test_new_candidate_never_autoconfirms(self):
        s = self.state('full')
        self.assertEqual(e.readiness(s)['pending'], list(e.FULL))
        template = e.manual_template(s)
        self.assertTrue(all(r['result'] is None for r in template['results']))
        self.assertTrue(all(v is None for r in template['results'] for v in r['observed'].values()))
        with self.assertRaises(e.EvidenceError):
            e.approve(s, s['artifact']['sha256'], 'operator')

    def test_complete_candidate_requires_explicit_full_sha_and_approval(self):
        s = self.accepted()
        self.assertTrue(e.readiness(s)['ready'])
        with self.assertRaises(e.EvidenceError):
            e.require_approval(s)
        with self.assertRaises(e.EvidenceError):
            e.approve(s, s['artifact']['sha256'][:8], 'operator')
        e.require_approval(e.approve(s, s['artifact']['sha256'], 'operator'))

    def test_full_acceptance_needs_each_distinct_check_and_can_be_approved(self):
        s = self.accepted(self.state('full'))
        self.assertEqual(len(s['confirmations']), 10)
        e.require_approval(e.approve(s, s['artifact']['sha256'], 'operator'))

    def test_cannot_approve_before_draft_binding(self):
        s = self.accepted(self.state(release_id=None))
        with self.assertRaises(e.EvidenceError):
            e.approve(s, s['artifact']['sha256'], 'operator')

    def test_other_candidate_confirmation_is_stale_even_same_bytes(self):
        first, second = self.state(), self.state()
        with self.assertRaisesRegex(e.EvidenceError, 'different source'):
            e.confirm(second, self.confirmation(first, 'clean_install'))

    def test_context_not_inferred_from_note(self):
        s = self.state()
        for key, value in [('freshEnvironment', False), ('gatekeeperEnabled', 1), ('usedOpenAnyway', True), ('downloadedSHA256', 'f' * 64)]:
            with self.subTest(key=key):
                r = self.confirmation(s, 'clean_install')
                r['note'] = 'Everything passed'
                r['observed'][key] = value
                with self.assertRaises(e.EvidenceError):
                    e.confirm(s, r)

    def test_audio_vm_cannot_satisfy_physical_playback(self):
        s = self.state()
        r = self.confirmation(s, 'voice_smoke')
        r['observed']['physicalMachine'] = False
        with self.assertRaises(e.EvidenceError):
            e.confirm(s, r)

    def test_upgrade_needs_actual_different_old_version(self):
        s = self.state()
        r = self.confirmation(s, 'upgrade_retention')
        r['observed']['previousVersion'] = s['version']
        with self.assertRaises(e.EvidenceError):
            e.confirm(s, r)

    def test_failed_check_blocks_release_and_can_be_repeated(self):
        s = self.accepted()
        r = self.confirmation(s, 'voice_smoke')
        r['result'] = 'fail'
        r['observed'] = {}
        s = e.confirm(s, r)
        self.assertIn('voice_smoke', e.readiness(s)['pending'])
        s = e.confirm(s, self.confirmation(s, 'voice_smoke'))
        self.assertTrue(e.readiness(s)['ready'])

    def test_reconfirmation_revokes_final_approval(self):
        s = self.accepted()
        s = e.approve(s, s['artifact']['sha256'], 'operator')
        s = e.confirm(s, self.confirmation(s, 'voice_smoke'))
        self.assertIsNone(s['approval'])

    def test_artifact_changed_after_approval_blocks_publish(self):
        s = self.accepted()
        s = e.approve(s, s['artifact']['sha256'], 'operator')
        self.artifact.write_bytes(b'different file after acceptance')
        self.assertFalse(e.readiness(s)['ready'])
        with self.assertRaises(e.EvidenceError):
            e.require_approval(s)

    def test_machine_log_changed_blocks_existing_acceptance(self):
        s = self.accepted()
        self.log.write_text('Changed after tests')
        self.assertFalse(e.readiness(s)['ready'])

    def test_linked_human_evidence_changed_blocks_publish(self):
        screenshot = self.root / 'fixture.png'
        screenshot.write_bytes(b'old frame')
        s = self.accepted()
        r = self.confirmation(s, 'clean_install')
        r['evidence'] = [str(screenshot)]
        s = e.confirm(s, r)
        screenshot.write_bytes(b'new frame')
        self.assertFalse(e.readiness(s)['ready'])

    def test_manual_record_tampering_invalidates_approval(self):
        s = self.accepted()
        s = e.approve(s, s['artifact']['sha256'], 'operator')
        s['confirmations']['clean_install']['note'] = 'Edited after publication approval'
        with self.assertRaises(e.EvidenceError):
            e.require_approval(s)

    def test_policy_downgrade_and_removed_checks_rejected(self):
        s = self.state('full')
        s['plan']['tier'] = 'standard'
        s['plan']['requiredChecks'] = list(e.CORE)
        self.assertFalse(e.readiness(s)['ready'])

    def test_same_record_cannot_satisfy_multiple_different_checks(self):
        s = self.state()
        s = e.confirm(s, self.confirmation(s, 'voice_smoke'))
        s['confirmations']['clean_install'] = copy.deepcopy(s['confirmations']['voice_smoke'])
        s['confirmations']['upgrade_retention'] = copy.deepcopy(s['confirmations']['voice_smoke'])
        self.assertFalse(e.readiness(s)['ready'])
        s = self.state()
        s['plan']['requiredChecks'].remove('upgrade_retention')
        self.assertFalse(e.readiness(s)['ready'])

    def test_wrong_source_or_nonzero_test_exit_blocks_candidate(self):
        for key, value in [('sourceCommit', 'b' * 40), ('passed', False)]:
            s = self.state()
            s['automatic']['tests'][key] = value
            self.assertFalse(e.readiness(s)['ready'])
        s = self.state()
        s['automatic']['tests']['commands'][0]['exitCode'] = 1
        self.assertFalse(e.readiness(s)['ready'])

    def test_public_manifest_omits_local_paths_and_free_form_data(self):
        s = self.accepted()
        s['confirmations']['voice_smoke']['note'] = '/Users/private secret-note'
        s['confirmations']['voice_smoke']['tester'] = 'private-operator'
        text = json.dumps(e.public_verification(s))
        self.assertNotIn('/Users/', text)
        self.assertNotIn('secret-note', text)
        self.assertNotIn('private-operator', text)
        s = self.state()
        s['automatic']['distribution']['submissions']['app']['privatePath'] = '/Users/private'
        s = self.accepted(s)
        text = json.dumps(e.public_verification(s))
        self.assertNotIn('/Users/private', text)

    def test_upgrade_rejects_unknown_or_newer_versions(self):
        s = self.state()
        for version in ('unknown', '3.0.0', '1.8.0'):
            with self.subTest(version=version):
                r = self.confirmation(s, 'upgrade_retention')
                r['observed']['previousVersion'] = version
                with self.assertRaises(e.EvidenceError):
                    e.confirm(s, r)

    def test_symlink_evidence_is_rejected(self):
        link = self.root / 'link'
        link.symlink_to(self.log)
        with self.assertRaises(e.EvidenceError):
            e.file_record(link)


class BuildProofTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.artifact = self.root / 'XiaoPen-2.0.0.dmg'
        self.artifact.write_bytes(b'fixture')
        self.commit = 'a' * 40
        names = ('gatekeeper-status.log', 'signatures.log', 'app-entitlements.plist', 'app-entitlements-lint.log', 'app-codesign-stapled.log', 'app-stapler-validate.log', 'app-gatekeeper.log', 'dmg-codesign-stapled.log', 'dmg-stapler-validate.log', 'dmg-gatekeeper.log', 'dmg-integrity.log', 'mounted-app-codesign.log', 'mounted-app-stapler.log', 'mounted-app-gatekeeper.log')
        for name in names:
            (self.root / name).write_text('fixture log\n')
        (self.root / 'signatures.log').write_text('Executable=/stage/XiaoPen.app/Contents/MacOS/XiaoPen\nCDHash=' + '1' * 40 + '\nTeamIdentifier=TESTTEAM01\nExecutable=/stage/' + self.artifact.name + '\nCDHash=' + '2' * 40 + '\nTeamIdentifier=TESTTEAM01\n')
        (self.root / 'gatekeeper-status.log').write_text('assessments enabled\n')
        (self.root / 'release-summary.txt').write_text(f'Version: 2.0.0 (20)\nIdentity: Developer ID Application: Fixture (TESTTEAM01)\nTeam: TESTTEAM01\nSource commit: {self.commit}\n')
        (self.root / 'SHA256SUMS').write_text(e.file_record(self.artifact)['sha256'] + '  XiaoPen-2.0.0.dmg\n')
        for kind, digit, suffix in [('app', '1', 'XiaoPen.app'), ('dmg', '2', self.artifact.name)]:
            job = f'{digit * 8}-{digit * 4}-{digit * 4}-{digit * 4}-{digit * 12}'
            ticket_path = f'XiaoPen.zip/XiaoPen.app/Contents/Resources/Distribution/{suffix}' if kind == 'dmg' else f'XiaoPen.zip/{suffix}'
            (self.root / f'{kind}-notary-log.json').write_text(json.dumps({'jobId': job, 'status': 'Accepted', 'statusCode': 0, 'issues': None, 'ticketContents': [{'path': ticket_path, 'cdhash': digit * 40, 'digestAlgorithm': 'SHA-256'}], 'localPrivateField': '/Users/private'}))

    def collect(self):
        return e.collect_distribution_evidence(self.root, self.artifact, self.commit, '2.0.0', '20')

    def test_complete_build_proof_and_public_log_excerpt(self):
        self.assertTrue(self.collect()['passed'])
        public = e.public_notary_log(self.root / 'app-notary-log.json')
        self.assertNotIn('localPrivateField', public)

    def test_incomplete_build_or_wrong_source_rejected(self):
        (self.root / 'mounted-app-stapler.log').unlink()
        with self.assertRaises(e.EvidenceError):
            self.collect()
        with self.assertRaises(e.EvidenceError):
            e.collect_distribution_evidence(self.root, self.artifact, 'b' * 40, '2.0.0', '20')

    def test_wrong_container_ticket_rejected(self):
        p = self.root / 'dmg-notary-log.json'
        d = json.loads(p.read_text())
        d['ticketContents'][0]['path'] = 'XiaoPen.zip/XiaoPen-1.9.0.dmg'
        p.write_text(json.dumps(d))
        with self.assertRaises(e.EvidenceError):
            self.collect()

    def test_root_notarytool_tickets_are_supported(self):
        for kind, name in [('app', 'XiaoPen.app'), ('dmg', self.artifact.name)]:
            p = self.root / f'{kind}-notary-log.json'
            d = json.loads(p.read_text())
            d['ticketContents'][0]['path'] = name
            p.write_text(json.dumps(d))
        self.assertTrue(self.collect()['passed'])

    def test_unrelated_nested_same_named_dmg_is_not_our_carrier(self):
        p = self.root / 'dmg-notary-log.json'
        d = json.loads(p.read_text())
        d['ticketContents'][0]['path'] = 'Other.app/Unrelated/' + self.artifact.name
        p.write_text(json.dumps(d))
        with self.assertRaises(e.EvidenceError):
            self.collect()

    def test_same_filename_other_signature_ticket_is_rejected(self):
        p = self.root / 'dmg-notary-log.json'
        d = json.loads(p.read_text())
        d['ticketContents'][0]['cdhash'] = 'f' * 40
        p.write_text(json.dumps(d))
        with self.assertRaises(e.EvidenceError):
            self.collect()

    def test_notarization_rejection_and_warning_block(self):
        p = self.root / 'app-notary-log.json'
        d = json.loads(p.read_text())
        for changes in ({'status': 'Invalid'}, {'statusCode': 1}, {'issues': [{'severity': 'warning', 'message': 'review required'}]}):
            p.write_text(json.dumps({**d, **changes}))
            with self.assertRaises(e.EvidenceError):
                self.collect()


if __name__ == '__main__':
    unittest.main()
