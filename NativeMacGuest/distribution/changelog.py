#!/usr/bin/env python3
"""Changelog ledger, Git commit extractor, and Sparkle/TestFlight formatters."""
import datetime
import json
import pathlib
import re
import subprocess

SCHEMA_VERSION = 1
PLATFORMS = ('mac', 'ios')
CHANNELS = ('beta', 'stable')
PLATFORM_PATHS = {
    'mac': ('NativeMacGuest', 'ConferenceCore', 'MeetingEngine', 'Shared', 'Dependencies'),
    'ios': ('RockNRoll', 'RockBroadcast', 'MeetingActivity', 'ConferenceCore', 'MeetingEngine', 'Shared', 'Dependencies'),
}

DEFAULT_CHANGELOG_PATH = pathlib.Path(__file__).with_name('changelog.json')

_HOUSEKEEPING_RE = re.compile(
    r'^(?:'
    r'Set (?:iOS|Mac|native).*?\bbuild\s+\d+\b'
    r'|Record (?:native Mac|iOS|build)\b'
    r'|Bump (?:iOS |Mac )?build\b'
    r'|Merge (?:branch|pull request)\b'
    r')',
    re.IGNORECASE,
)
_TRAILING_BUMP_RE = re.compile(
    r'(?:,\s*|\s+)and\s+bump\s+(?:iOS\s+|Mac\s+)?build(?:\s+number)?(?:\s+to)?\s+\d+\s*$',
    re.IGNORECASE,
)
_TRAILING_BUILD_PARENS_RE = re.compile(
    r'\s*\((?:\d+\.\d+\.\d+\s+)?build\s+\d+\)\s*$',
    re.IGNORECASE,
)
_MAC_EXCLUDE_RE = re.compile(
    r'^(?:Fix|Add|Show|Keep|Guard|Polish|Enable|Use|Update|Improve|Gate|Stream|Catch|Localize|Complete|Suppress)\s+iOS\b'
    r'|\bon\s+iOS\s*$',
    re.IGNORECASE,
)
_IOS_EXCLUDE_RE = re.compile(
    r'^(?:Fix|Add|Show|Make|Polish|Clarify|Stabilize|Redesign|Update|Improve)\s+(?:macOS(?:\s+\d+)?|Mac|native\s+Mac|direct\s+Mac)\b'
    r'|\bon\s+macOS\s*$',
    re.IGNORECASE,
)
_DATE_RE = re.compile(r'\d{4}-\d{2}-\d{2}')
_COMMIT_RE = re.compile(r'[0-9a-fA-F]{7,40}')
_VERSION_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*')


def validate_entry(entry, platform='mac'):
    if not isinstance(entry, dict):
        raise ValueError(f'{platform} changelog entry must be an object')
    expected_keys = {'build', 'version', 'channel', 'date', 'commit', 'items'}
    extra = set(entry) - expected_keys
    missing = expected_keys - set(entry)
    if missing or extra:
        raise ValueError(f'{platform} changelog entry has invalid keys (missing={sorted(missing)}, extra={sorted(extra)})')
    build = entry['build']
    if not isinstance(build, int) or isinstance(build, bool) or build < 1:
        raise ValueError(f'{platform} changelog entry build must be a positive integer')
    version = entry['version']
    if not isinstance(version, str) or not _VERSION_RE.fullmatch(version):
        raise ValueError(f'{platform} build {build} has invalid version')
    if entry['channel'] not in CHANNELS:
        raise ValueError(f'{platform} build {build} has invalid channel')
    if not isinstance(entry['date'], str) or not _DATE_RE.fullmatch(entry['date']):
        raise ValueError(f'{platform} build {build} has invalid YYYY-MM-DD date')
    if not isinstance(entry['commit'], str) or not _COMMIT_RE.fullmatch(entry['commit']):
        raise ValueError(f'{platform} build {build} has invalid commit hash')
    items = entry['items']
    if not isinstance(items, list) or not items or any(not isinstance(x, str) or not x.strip() for x in items):
        raise ValueError(f'{platform} build {build} must have at least one non-empty changelog item')


def validate_changelog(data):
    if not isinstance(data, dict) or data.get('schemaVersion') != SCHEMA_VERSION:
        raise ValueError('Changelog must have schemaVersion == 1')
    if set(data) != {'schemaVersion', *PLATFORMS}:
        raise ValueError('Changelog must contain only schemaVersion, mac, and ios keys')
    for platform in PLATFORMS:
        entries = data[platform]
        if not isinstance(entries, list):
            raise ValueError(f'{platform} changelog must be a list')
        seen = set()
        for entry in entries:
            validate_entry(entry, platform)
            if entry['build'] in seen:
                raise ValueError(f'Duplicate {platform} changelog entry for build {entry["build"]}')
            seen.add(entry['build'])
    return data


def load_changelog(path=DEFAULT_CHANGELOG_PATH):
    path = pathlib.Path(path)
    if not path.is_file():
        raise ValueError(f'Changelog file does not exist: {path}')
    data = json.loads(path.read_text(encoding='utf-8'))
    return validate_changelog(data)


def save_changelog(path, data):
    validate_changelog(data)
    normalized = {'schemaVersion': SCHEMA_VERSION}
    for platform in PLATFORMS:
        entries = sorted(
            [
                {
                    'build': int(e['build']),
                    'version': e['version'],
                    'channel': e['channel'],
                    'date': e['date'],
                    'commit': e['commit'],
                    'items': [item.strip() for item in e['items'] if item.strip()],
                }
                for e in data[platform]
            ],
            key=lambda e: e['build'],
            reverse=True,
        )
        normalized[platform] = entries
    pathlib.Path(path).write_text(json.dumps(normalized, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def upsert_entry(data, platform, entry):
    if platform not in PLATFORMS:
        raise ValueError(f'Unsupported platform: {platform}')
    validate_entry(entry, platform)
    filtered = [e for e in data[platform] if e['build'] != entry['build']]
    filtered.append(dict(entry, items=[item.strip() for item in entry['items'] if item.strip()]))
    filtered.sort(key=lambda e: e['build'], reverse=True)
    updated = dict(data)
    updated[platform] = filtered
    return validate_changelog(updated)


def latest_entry(data, platform):
    entries = sorted(data[platform], key=lambda e: e['build'], reverse=True)
    return entries[0] if entries else None


def entry_for_build(data, platform, build):
    target = int(build)
    for entry in data[platform]:
        if entry['build'] == target:
            return entry
    return None


def _clean_subject(subject, platform):
    text = subject.strip()
    if not text or _HOUSEKEEPING_RE.match(text):
        return None
    text = _TRAILING_BUMP_RE.sub('', text)
    text = _TRAILING_BUILD_PARENS_RE.sub('', text).strip().rstrip(',')
    if not text:
        return None
    lower = text.lower()
    if platform == 'mac' and _MAC_EXCLUDE_RE.search(text) and 'mac' not in lower:
        return None
    if platform == 'ios' and _IOS_EXCLUDE_RE.search(text) and 'ios' not in lower:
        return None
    return text


def _parse_trailers(body):
    notes = []
    for line in body.splitlines():
        match = re.match(r'^\s*Changelog:\s*(.+?)\s*$', line, re.IGNORECASE)
        if match and match.group(1):
            notes.append(match.group(1).strip())
    return notes


def extract_changes(root, platform, since_commit=None, until_commit='HEAD', limit=40):
    if platform not in PLATFORM_PATHS:
        raise ValueError(f'Unsupported platform: {platform}')
    rev_range = f'{since_commit}..{until_commit}' if since_commit else until_commit
    cmd = [
        'git', '-C', str(root), 'log', rev_range,
        '--no-merges', f'-n{limit}',
        '--pretty=format:%H%x1f%s%x1f%b%x1e',
        '--', *PLATFORM_PATHS[platform],
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    bullets = []
    seen = set()
    for record in result.stdout.split('\x1e'):
        record = record.strip('\r\n ')
        if not record:
            continue
        parts = record.split('\x1f', 2)
        if len(parts) < 2:
            continue
        subject = parts[1].strip()
        body = parts[2] if len(parts) > 2 else ''
        trailers = _parse_trailers(body)
        candidates = trailers if trailers else [c for c in [_clean_subject(subject, platform)] if c]
        for item in candidates:
            key = item.lower()
            if key not in seen:
                seen.add(key)
                bullets.append(item)
    return bullets


def head_commit(root, ref='HEAD'):
    return subprocess.run(
        ['git', '-C', str(root), 'rev-parse', '--short=8', ref],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def format_section(entry):
    lines = [f"### {entry['version']} ({entry['build']}) — {entry['date']}"]
    for item in entry['items']:
        lines.append(f'- {item}')
    return '\n'.join(lines)


def render_appcast_markdown(entries, target_build, max_builds=120, max_bytes=80_000, single_build=False):
    target_build = int(target_build)
    ordered = sorted((e for e in entries if e['build'] <= target_build), key=lambda e: e['build'], reverse=True)
    if single_build:
        ordered = [e for e in ordered if e['build'] == target_build]
    else:
        ordered = ordered[:max_builds]
    if not ordered or ordered[0]['build'] != target_build:
        raise ValueError(f'Missing changelog entry for build {target_build}')
    sections = [format_section(entry) for entry in ordered]
    while len(sections) > 1 and len('\n\n'.join(sections).encode('utf-8')) > max_bytes:
        sections.pop()
    return '\n\n'.join(sections)


def render_testflight_notes(entries, since_build=None, max_builds=10):
    ordered = sorted(entries, key=lambda e: e['build'], reverse=True)
    if since_build is not None:
        selected = [e for e in ordered if e['build'] > int(since_build)]
    else:
        selected = ordered[:1]
    selected = selected[:max_builds]
    if not selected:
        return ''
    bullets = []
    seen = set()
    for entry in selected:
        for item in entry['items']:
            key = item.lower()
            if key not in seen:
                seen.add(key)
                bullets.append(f'- {item}')
    if len(selected) == 1:
        header = f"What's new in {selected[0]['version']} ({selected[0]['build']}):"
    else:
        oldest, newest = selected[-1], selected[0]
        header = f"What's new in {newest['version']} ({oldest['build']}–{newest['build']}):"
    return header + '\n' + '\n'.join(bullets)


def today_iso():
    return datetime.date.today().isoformat()
