import json
import pathlib
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import changelog

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ChangelogTests(unittest.TestCase):
    def test_checked_in_changelog_is_valid_and_covers_stable_to_head(self):
        data = changelog.load_changelog(ROOT / 'NativeMacGuest/distribution/changelog.json')
        builds = {entry['build'] for entry in data['mac']}
        self.assertIn(53, builds)
        self.assertIn(166, builds)
        self.assertTrue(data['ios'])
        markdown = changelog.render_appcast_markdown(data['mac'], 166)
        self.assertIn('### 0.3.0 (166)', markdown)
        self.assertIn('### 0.3.0 (53)', markdown)
        self.assertLessEqual(len(markdown.encode('utf-8')), 80_000)

    def test_extract_changes_prefers_trailers_and_filters_noise_and_other_platform(self):
        git_output = '\x1e'.join([
            '11111111\x1fSet iOS TestFlight build 174\x1f',
            '22222222\x1fFix iOS background camera capture\x1f',
            '33333333\x1fFix macOS sidebar layout\x1f',
            '44444444\x1fHarden ICE recovery and bump build 167\x1fChangelog: Faster ICE relay recovery after network drops\nChangelog: Keep audio active across sleep\n',
            '55555555\x1fPolish audio handoff, and bump iOS build to 174\x1f',
        ])
        with mock.patch.object(changelog.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=git_output)):
            mac_notes = changelog.extract_changes(ROOT, 'mac', since_commit='abc1234')
            ios_notes = changelog.extract_changes(ROOT, 'ios', since_commit='abc1234')
        self.assertEqual(mac_notes, [
            'Fix macOS sidebar layout',
            'Faster ICE relay recovery after network drops',
            'Keep audio active across sleep',
            'Polish audio handoff',
        ])
        self.assertEqual(ios_notes, [
            'Fix iOS background camera capture',
            'Faster ICE relay recovery after network drops',
            'Keep audio active across sleep',
            'Polish audio handoff',
        ])

    def test_render_appcast_markdown_trims_oldest_when_exceeding_byte_budget(self):
        entries = [
            {'build': b, 'version': '0.3.0', 'channel': 'beta', 'date': '2026-11-27',
             'commit': f'{b:07x}', 'items': [f'Change {b} ' + ('x' * 120)]}
            for b in range(100, 120)
        ]
        rendered = changelog.render_appcast_markdown(entries, 119, max_bytes=900)
        self.assertIn('### 0.3.0 (119)', rendered)
        self.assertNotIn('### 0.3.0 (100)', rendered)
        self.assertLessEqual(len(rendered.encode('utf-8')), 900)

    def test_render_testflight_notes_deduplicates_across_builds(self):
        entries = [
            {'build': 175, 'version': '0.2.0', 'channel': 'beta', 'date': '2026-11-27', 'commit': 'aaaaaaa',
             'items': ['Fix crash on resume', 'Improve PiP stability']},
            {'build': 174, 'version': '0.2.0', 'channel': 'beta', 'date': '2026-11-27', 'commit': 'bbbbbbb',
             'items': ['Fix crash on resume', 'Add network diagnostics']},
            {'build': 173, 'version': '0.2.0', 'channel': 'beta', 'date': '2026-11-26', 'commit': 'ccccccc',
             'items': ['Old note']},
        ]
        notes = changelog.render_testflight_notes(entries, since_build=173)
        self.assertIn("What's new in 0.2.0 (174–175):", notes)
        self.assertEqual(notes.count('Fix crash on resume'), 1)
        self.assertIn('- Improve PiP stability', notes)
        self.assertNotIn('Old note', notes)

    def test_save_and_load_rejects_duplicate_builds(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'changelog.json'
            bad = {
                'schemaVersion': 1,
                'mac': [
                    {'build': 10, 'version': '0.3.0', 'channel': 'beta', 'date': '2026-11-27', 'commit': 'abcdef1', 'items': ['A']},
                    {'build': 10, 'version': '0.3.0', 'channel': 'beta', 'date': '2026-11-27', 'commit': 'abcdef2', 'items': ['B']},
                ],
                'ios': [],
            }
            with self.assertRaisesRegex(ValueError, 'Duplicate mac changelog entry'):
                changelog.save_changelog(path, bad)


if __name__ == '__main__':
    unittest.main()
