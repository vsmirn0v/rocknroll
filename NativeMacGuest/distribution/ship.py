#!/usr/bin/env python3
"""One-command local release runner for direct Mac builds (and changelog prep)."""
import argparse
import json
import pathlib
import subprocess
import sys
import urllib.request

from build_support import APP_BUNDLE_NAME, KEYCHAIN_ACCOUNT, pinned_sparkle
import changelog as changelog_lib
from release import ORIGIN, ROOT, read_json

DIST_DIR = pathlib.Path(__file__).resolve().parent


def run_step(command):
    subprocess.run([str(x) for x in command], check=True)


def fetch_url_bytes(url, limit=262144):
    request = urllib.request.Request(
        url,
        headers={'Cache-Control': 'no-cache', 'User-Agent': 'RockNRoll-ship/1'},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError(f'Unexpected HTTP {response.status} fetching {url}')
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f'Remote metadata exceeds {limit} bytes: {url}')
    return data


def fetch_live_metadata(live_dir, root=ROOT):
    live_dir = pathlib.Path(live_dir)
    live_dir.mkdir(parents=True, exist_ok=True)
    feed_path = live_dir / 'appcast.xml'
    inventory_path = live_dir / 'latest.json'
    feed_path.write_bytes(fetch_url_bytes(ORIGIN + '/mac/appcast.xml', limit=262144))
    inventory_path.write_bytes(fetch_url_bytes(ORIGIN + '/mac/latest.json', limit=65536))
    pinned_sparkle(root)
    tools = root / '.build/native-dmg/Sparkle/bin'
    run_step([tools / 'sign_update', '--account', KEYCHAIN_ACCOUNT, '--verify', feed_path])
    inventory = read_json(inventory_path)
    return feed_path, inventory_path, inventory


def compute_next_build(inventory, changelog_data):
    candidates = [int(inventory[c]['build']) for c in ('stable', 'beta') if c in inventory]
    candidates.extend(int(entry['build']) for entry in changelog_data.get('mac', []))
    return (max(candidates) if candidates else 0) + 1


def prepare_release_notes(
    root,
    changelog_path,
    version,
    build_number,
    channel,
    explicit_notes=None,
    auto_yes=False,
    input_fn=input,
):
    data = changelog_lib.load_changelog(changelog_path)
    existing = changelog_lib.entry_for_build(data, 'mac', build_number)
    notes = [item.strip() for item in (explicit_notes or []) if item.strip()]
    if not notes:
        if existing is not None:
            notes = list(existing['items'])
        else:
            latest = changelog_lib.latest_entry(data, 'mac')
            since_commit = latest['commit'] if latest else None
            notes = changelog_lib.extract_changes(root, 'mac', since_commit=since_commit)
    if not notes:
        raise ValueError('No changelog entries found since the previous build; pass --note "..."')
    entry = {
        'build': int(build_number),
        'version': version,
        'channel': channel,
        'date': changelog_lib.today_iso(),
        'commit': changelog_lib.head_commit(root),
        'items': notes,
    }
    print('\n' + changelog_lib.format_section(entry) + '\n', flush=True)
    if not auto_yes:
        answer = input_fn('Record this changelog and continue build? [Y/n] ').strip().lower()
        if answer not in ('', 'y', 'yes'):
            raise ValueError('Aborted by user before build')
    updated = changelog_lib.upsert_entry(data, 'mac', entry)
    changelog_lib.save_changelog(changelog_path, updated)
    return entry


def tag_release(root, version, build_number):
    tag = f'mac-{version}-{build_number}'
    exists = subprocess.run(
        ['git', '-C', str(root), 'rev-parse', '-q', '--verify', f'refs/tags/{tag}'],
        capture_output=True, text=True, check=False,
    )
    if exists.returncode != 0:
        run_step(['git', '-C', str(root), 'tag', tag, 'HEAD'])
        print(f'Created local git tag {tag}', flush=True)


def run_ship(args):
    changelog_path = pathlib.Path(args.changelog).resolve()
    if args.resume:
        work_dir = args.resume.resolve()
        state_path = work_dir / 'ship-state.json'
        if not state_path.is_file():
            raise ValueError(f'Missing ship-state.json in {work_dir}')
        state = json.loads(state_path.read_text(encoding='utf-8'))
        channel = args.channel or state['channel']
        version = args.version or state['version']
        build_number = args.build_number or int(state['build'])
        live_feed = work_dir / 'live/appcast.xml'
        live_inventory = work_dir / 'live/latest.json'
        archive = work_dir / f'build/RockNRollNativeGuest-{version}-{build_number}.xcarchive'
        export_dir = work_dir / 'export'
        if not (export_dir / 'export-evidence.json').is_file():
            run_step([
                sys.executable, DIST_DIR / 'release.py', 'finalize',
                '--archive', archive, '--output', export_dir,
                '--wait-seconds', str(args.wait_seconds),
            ])
    else:
        if not args.channel:
            raise ValueError('--channel is required when starting a new release')
        if not args.identity:
            raise ValueError('--identity is required when building a new release')
        channel = args.channel
        data = changelog_lib.load_changelog(changelog_path)
        latest = changelog_lib.latest_entry(data, 'mac')
        version = args.version or (latest['version'] if latest else '0.3.0')
        # Reserve a provisional directory only after determining build_number from live + ledger.
        import tempfile
        with tempfile.TemporaryDirectory(prefix='rock-live-meta-') as temp_dir:
            temp_feed, temp_inv, inventory = fetch_live_metadata(temp_dir, ROOT)
            build_number = args.build_number or compute_next_build(inventory, data)
            work_dir = (args.work_dir or (ROOT / f'.build/native-{channel}-{build_number}')).resolve()
            live_dir = work_dir / 'live'
            live_dir.mkdir(parents=True, exist_ok=True)
            live_feed = live_dir / 'appcast.xml'
            live_inventory = live_dir / 'latest.json'
            live_feed.write_bytes(temp_feed.read_bytes())
            live_inventory.write_bytes(temp_inv.read_bytes())
        prepare_release_notes(
            ROOT, changelog_path, version, build_number, channel,
            explicit_notes=args.note, auto_yes=args.yes,
        )
        (work_dir / 'ship-state.json').write_text(
            json.dumps({'channel': channel, 'version': version, 'build': build_number}, indent=2) + '\n',
            encoding='utf-8',
        )
        build_cmd = [
            sys.executable, ROOT / 'NativeMacGuest/build.py',
            '--distribution', 'direct', '--configuration', 'Release',
            '--reuse-cache', '--identity', args.identity,
            '--version', version, '--build-number', str(build_number),
            '--archive', '--allow-provisioning-updates',
            '--output-dir', work_dir / 'build',
        ]
        if args.framework_root:
            build_cmd.extend(['--framework-root', args.framework_root])
        run_step(build_cmd)
        archive = work_dir / f'build/RockNRollNativeGuest-{version}-{build_number}.xcarchive'
        export_dir = work_dir / 'export'
        run_step([
            sys.executable, DIST_DIR / 'release.py', 'export',
            '--archive', archive, '--output', export_dir,
            '--wait-seconds', str(args.wait_seconds),
        ])

    package_dir = work_dir / 'package'
    if not (package_dir / 'release.json').is_file():
        run_step([
            sys.executable, DIST_DIR / 'release.py', 'package',
            '--app', export_dir / 'App' / APP_BUNDLE_NAME,
            '--output', package_dir,
        ])

    feed_dir = work_dir / 'feed'
    if not (feed_dir / 'appcast.xml').is_file():
        run_step([
            sys.executable, DIST_DIR / 'release.py', 'feed',
            '--release', package_dir / 'release.json',
            '--channel', channel,
            '--output', feed_dir,
            '--previous-feed', live_feed,
            '--previous-inventory', live_inventory,
            '--changelog', changelog_path,
        ])

    publish_cmd = [
        sys.executable, DIST_DIR / 'publish.py',
        '--feed', feed_dir / 'appcast.xml',
        '--inventory', feed_dir / 'latest.json',
        '--package', package_dir,
    ]
    if args.apply:
        evidence_path = work_dir / 'publish-evidence.json'
        if not evidence_path.exists():
            publish_cmd.extend(['--apply', '--evidence', evidence_path])
        else:
            publish_cmd.append('--apply')
    run_step(publish_cmd)
    if args.apply and not args.no_tag:
        tag_release(ROOT, version, build_number)
    return work_dir


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', choices=changelog_lib.CHANNELS)
    parser.add_argument('--identity', help='Apple Development signing identity for build.py')
    parser.add_argument('--version', help='Marketing version (defaults to latest recorded version)')
    parser.add_argument('--build-number', type=int, help='Numeric build number (defaults to max(live, changelog) + 1)')
    parser.add_argument('--changelog', type=pathlib.Path, default=changelog_lib.DEFAULT_CHANGELOG_PATH)
    parser.add_argument('--note', action='append', help='Explicit changelog bullet (repeatable)')
    parser.add_argument('--yes', action='store_true', help='Accept extracted changelog bullets without prompting')
    parser.add_argument('--apply', action='store_true', help='Publish verified release artifacts to production')
    parser.add_argument('--no-tag', action='store_true', help='Do not create a local git tag after --apply')
    parser.add_argument('--resume', type=pathlib.Path, help='Resume an existing .build/native-<channel>-<build> run')
    parser.add_argument('--work-dir', type=pathlib.Path, help='Override output directory (defaults to .build/native-<channel>-<build>)')
    parser.add_argument('--framework-root', type=pathlib.Path, help='Optional LiveKitWebRTC framework root passed to build.py')
    parser.add_argument('--wait-seconds', type=int, default=1800)
    args = parser.parse_args()
    try:
        run_ship(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
