import json
import pathlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import changelog
import ship


class ShipTests(unittest.TestCase):
    def test_compute_next_build_takes_max_of_live_and_changelog(self):
        inventory = {'stable': {'build': '53'}, 'beta': {'build': '166'}}
        data = {'mac': [{'build': 168}, {'build': 166}]}
        self.assertEqual(ship.compute_next_build(inventory, data), 169)

    def test_prepare_release_notes_extracts_confirms_and_persists(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'changelog.json'
            path.write_text(json.dumps({
                'schemaVersion': 1,
                'mac': [{'build': 166, 'version': '0.3.0', 'channel': 'beta', 'date': '2026-11-26',
                         'commit': '116ce50c', 'items': ['Previous item']}],
                'ios': [],
            }))
            with mock.patch.object(changelog, 'extract_changes', return_value=['New Mac fix']) as extract, \
                 mock.patch.object(changelog, 'head_commit', return_value='deadbeef'), \
                 mock.patch.object(changelog, 'today_iso', return_value='2026-11-27'):
                entry = ship.prepare_release_notes(
                    pathlib.Path(temp), path, '0.3.0', 167, 'beta',
                    auto_yes=False, input_fn=lambda _: 'y',
                )
            extract.assert_called_once_with(pathlib.Path(temp), 'mac', since_commit='116ce50c')
            self.assertEqual(entry['build'], 167)
            self.assertEqual(entry['items'], ['New Mac fix'])
            loaded = changelog.load_changelog(path)
            self.assertEqual(loaded['mac'][0]['build'], 167)

    def test_run_ship_dry_run_orchestrates_build_export_package_feed_preflight(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            changelog_path = root / 'changelog.json'
            changelog_path.write_text(json.dumps({
                'schemaVersion': 1,
                'mac': [{'build': 166, 'version': '0.3.0', 'channel': 'beta', 'date': '2026-11-26',
                         'commit': '116ce50c', 'items': ['Existing']}],
                'ios': [],
            }))
            work_dir = root / 'work'

            def fake_fetch(live_dir, _root):
                live = pathlib.Path(live_dir)
                live.mkdir(parents=True, exist_ok=True)
                feed = live / 'appcast.xml'
                inv = live / 'latest.json'
                feed.write_text('<rss/>')
                inventory = {'schemaVersion': 1, 'stable': {'build': '53'}, 'beta': {'build': '166'}}
                inv.write_text(json.dumps(inventory))
                return feed, inv, inventory

            commands = []
            args = SimpleNamespace(
                channel='beta', identity='Apple Development: Fixture', version=None,
                build_number=None, changelog=changelog_path, note=['One fix'], yes=True,
                apply=False, no_tag=False, resume=None, work_dir=work_dir,
                framework_root=None, wait_seconds=60,
            )
            with mock.patch.object(ship, 'fetch_live_metadata', side_effect=fake_fetch), \
                 mock.patch.object(changelog, 'head_commit', return_value='cafebabe'), \
                 mock.patch.object(ship, 'run_step', side_effect=lambda cmd: commands.append([str(c) for c in cmd])), \
                 mock.patch.object(ship, 'tag_release') as tag:
                result_dir = ship.run_ship(args)
            self.assertEqual(result_dir, work_dir.resolve())
            tag.assert_not_called()
            joined = [' '.join(c) for c in commands]
            self.assertEqual(len(joined), 5)
            self.assertIn('build.py', joined[0])
            self.assertIn('--build-number 167', joined[0])
            self.assertIn('release.py export', joined[1])
            self.assertIn('release.py package', joined[2])
            self.assertIn('release.py feed', joined[3])
            self.assertIn('publish.py', joined[4])
            self.assertNotIn('--apply', joined[4])

    def test_resume_skips_build_and_runs_finalize_and_apply(self):
        with tempfile.TemporaryDirectory() as temp:
            work_dir = pathlib.Path(temp) / 'native-beta-168'
            (work_dir / 'live').mkdir(parents=True)
            (work_dir / 'ship-state.json').write_text(json.dumps({'channel': 'beta', 'version': '0.3.0', 'build': 168}))
            changelog_path = pathlib.Path(temp) / 'changelog.json'
            changelog_path.write_text(json.dumps({'schemaVersion': 1, 'mac': [], 'ios': []}))
            commands = []
            args = SimpleNamespace(
                channel=None, identity=None, version=None, build_number=None,
                changelog=changelog_path, note=None, yes=True, apply=True, no_tag=False,
                resume=work_dir, work_dir=None, framework_root=None, wait_seconds=120,
            )
            with mock.patch.object(ship, 'run_step', side_effect=lambda cmd: commands.append([str(c) for c in cmd])), \
                 mock.patch.object(ship, 'tag_release') as tag:
                ship.run_ship(args)
            joined = [' '.join(c) for c in commands]
            self.assertEqual(len(joined), 4)
            self.assertIn('release.py finalize', joined[0])
            self.assertIn('release.py package', joined[1])
            self.assertIn('release.py feed', joined[2])
            self.assertIn('publish.py', joined[3])
            self.assertIn('--apply', joined[3])
            tag.assert_called_once_with(ship.ROOT, '0.3.0', 168)


if __name__ == '__main__':
    unittest.main()
