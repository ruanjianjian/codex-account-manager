#!/usr/bin/env python3
"""Explicit, resumable Apple notarization. Credentials stay in a Keychain profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

os.umask(0o077)

def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)

def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)

def fingerprint(app):
    parts = ['Contents/MacOS/CodexAccounts', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources']
    return {p: hashlib.sha256((app / p).read_bytes()).hexdigest() for p in parts}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'submit', 'finish'])
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Fresh local directory, never commit it')
    parser.add_argument('--profile', default=os.environ.get('NOTARY_PROFILE'), help='notarytool Keychain profile (not a password)')
    args = parser.parse_args()
    app, out = args.app.resolve(), args.output.resolve()
    if app == out or app in out.parents:
        raise RuntimeError('Output must be outside the app bundle.')
    state_path = out / 'state.json'
    if args.phase == 'prepare':
        run(['codesign', '--verify', '--deep', '--strict', str(app)])
        details = run(['codesign', '-d', '--verbose=4', str(app)]).stderr
        if '\nAuthority=Developer ID Application:' not in '\n' + details:
            raise RuntimeError('A Developer ID Application signature is required. No submission made.')
        if '(runtime)' not in details or '\nTimestamp=' not in '\n' + details:
            raise RuntimeError('Hardened Runtime and secure timestamp are required.')
        if out.exists():
            raise RuntimeError('Output already exists. Resume it or choose a fresh directory; do not blindly resubmit.')
        out.mkdir(parents=True)
        run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(app), str(out / 'upload.zip')])
        save(state_path, {'app': str(app), 'fingerprint': fingerprint(app), 'phase': 'prepared', 'uploadSHA256': hashlib.sha256((out / 'upload.zip').read_bytes()).hexdigest()})
        print('Prepared. Run submit with a matching personal Keychain profile.')
        return
    if not args.profile:
        raise RuntimeError('Set NOTARY_PROFILE or --profile. Do not pass passwords to this script.')
    state = json.loads(state_path.read_text())
    if state['app'] != str(app) or state['fingerprint'] != fingerprint(app):
        raise RuntimeError('App changed since preparation; do not submit or staple a different build.')
    if args.phase == 'submit':
        if hashlib.sha256((out / 'upload.zip').read_bytes()).hexdigest() != state['uploadSHA256']:
            raise RuntimeError('Upload archive changed since preparation.')
        if state['phase'] != 'prepared':
            raise RuntimeError('Submission already attempted. Use finish; if its ID was lost, inspect notarytool history before any retry.')
        # Persist intent before uploading so a crash or ambiguous result never silently resubmits.
        state['phase'] = 'submission-attempted'
        save(state_path, state)
        result = run(['xcrun', 'notarytool', 'submit', str(out / 'upload.zip'), '--keychain-profile', args.profile, '--no-wait', '--output-format', 'json'])
        (out / 'submission.json').write_text(result.stdout)
        submission = json.loads(result.stdout)
        state['id'] = submission['id']
        state['phase'] = 'submitted'
        save(state_path, state)
        print('Submitted:', state['id'], '\nRun finish later; do not submit again.')
        return
    if state.get('phase') == 'ready':
        archive = out / 'Codex-Accounts-notarized.zip'
        if hashlib.sha256(archive.read_bytes()).hexdigest() != state['archiveSHA256']:
            raise RuntimeError('Finished archive no longer matches its checksum.')
        print('Already ready:', archive)
        return
    submission_id = state.get('id')
    if not submission_id and (out / 'submission.json').exists():
        submission_id = json.loads((out / 'submission.json').read_text()).get('id')
    if not submission_id:
        raise RuntimeError('No confirmed submission ID. Inspect notarytool history; do not blindly retry the upload.')
    result = run(['xcrun', 'notarytool', 'info', submission_id, '--keychain-profile', args.profile, '--output-format', 'json'])
    info = json.loads(result.stdout)
    save(out / 'status.json', info)
    status = info['status']
    if status == 'In Progress':
        print('Still processing. Run finish again later.'); sys.exit(2)
    run(['xcrun', 'notarytool', 'log', submission_id, '--keychain-profile', args.profile, str(out / 'notary-log.json')])
    if status != 'Accepted':
        raise RuntimeError('Not accepted: ' + status + '. Review the local notarization log.')
    run(['xcrun', 'stapler', 'staple', str(app)])
    run(['xcrun', 'stapler', 'validate', str(app)])
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    assessment = run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)])
    (out / 'gatekeeper.txt').write_text(assessment.stdout + assessment.stderr)
    run(['xcrun', 'syspolicy_check', 'distribution', str(app)])
    archive = out / 'Codex-Accounts-notarized.zip'
    run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(app), str(archive)])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / 'SHA256SUMS.txt').write_text(digest + '  ' + archive.name + '\n')
    state.update(phase='ready', archiveSHA256=digest)
    save(state_path, state)
    print('Accepted, stapled and Gatekeeper verified:', archive)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        # Never echo raw Apple authentication errors or command arguments containing secrets.
        if isinstance(exc, subprocess.CalledProcessError):
            print('Apple/tool command failed (exit %d). Do not retry an uncertain upload; inspect local state and notarytool history.' % exc.returncode, file=sys.stderr)
        else:
            print(str(exc), file=sys.stderr)
        sys.exit(1)
