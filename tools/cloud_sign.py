"""Private macOS signing and store delivery. Never embeds the signing private key.

Requires UU_P12_PASSWORD, INSTALLATION_ADMIN_TOKEN and a single-device Apple
profile for the requested bundle. Run only on a trusted private signing host.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import sys
import subprocess
import tempfile
import urllib.request
import zipfile
from cryptography.hazmat.primitives.serialization import pkcs12, Encoding, PrivateFormat, NoEncryption
from personalize import validate

ORIGIN = 'https://uuxp.click'
APPS = {'click.uuxp.signer', 'com.garena.game.kgtwtw'}

def run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError('Signing/verification failed; no package delivered')
    return result.stdout

def inspect_package(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip():
            raise ValueError('Damaged or duplicate archive')
        for name in names:
            if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts or '\\' in name:
                raise ValueError('Unsafe archive path')
            if '/UUDevice/' in name or name.lower().endswith(('.p12', '.pfx', '.pem', '.key')):
                raise ValueError('Signing credentials must not be distributed')
        infos = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(infos) != 1:
            raise ValueError('Expected one app')
        info = plistlib.loads(archive.read(infos[0]))
        if info.get('CFBundleIdentifier') not in APPS:
            raise ValueError('Unsupported app')
        if info['CFBundleIdentifier'] == 'click.uuxp.signer' and not info.get('UUCloudDelivery'):
            raise ValueError('Cloud delivery build required')
        return info, infos[0].removesuffix('Info.plist')

def api(path, token, data=b'{}', method='POST', extra=None):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    headers = {'Authorization': 'Bearer '+token, 'Content-Type': 'application/json', **(extra or {})}
    req = urllib.request.Request(ORIGIN+path, data=data, method=method, headers=headers)
    with urllib.request.build_opener(NoRedirect).open(req, timeout=180) as response:
        return json.load(response)

def deliver(path, info, args, expiry, token):
    path = Path(path)
    with path.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    metadata = dict(email=args.email, providerOrder=args.delivery_id,
        deviceHash=hashlib.sha256(args.udid.upper().encode()).hexdigest(),
        sha256=checksum, size=path.stat().st_size, version=info['CFBundleVersion'],
        bundleId=info['CFBundleIdentifier'], expires=int(expiry))
    delivery = api('/api/admin/installations', token, json.dumps(metadata).encode())
    base = '/api/admin/installations/'+delivery['id']
    if delivery['status'] == 'staging':
        upload = api(base+'/begin', token)
        with path.open('rb') as stream:
            number = 0
            while part := stream.read(upload['partSize']):
                number += 1
                api(base+'/part-'+str(number), token, part, 'PUT',
                    {'Content-Type': 'application/octet-stream', 'X-Part-SHA256': hashlib.sha256(part).hexdigest()})
        delivery = api(base+'/complete', token)
    if delivery['status'] != 'ready':
        raise ValueError('Delivery not available')
    return dict(id=delivery['id'], status='ready_for_device_test', device_install_verified=False)

def fulfill(args):
    if sys.platform != 'darwin':
        raise ValueError('Private macOS signing host required')
    password, token = os.environ['UU_P12_PASSWORD'], os.environ['INSTALLATION_ADMIN_TOKEN']
    info, _ = inspect_package(args.ipa)
    profile_bytes = Path(args.profile).read_bytes()
    profile = plistlib.loads(run([args.openssl, 'cms', '-verify', '-inform', 'DER', '-in', args.profile, '-noverify']))
    p12 = Path(args.p12).read_bytes()
    validate(profile, p12, password, args.udid, info['CFBundleIdentifier'])
    key, cert, _ = pkcs12.load_key_and_certificates(p12, password.encode() or None)
    with tempfile.TemporaryDirectory(prefix='uu-cloud-sign-') as folder:
        root = Path(folder)
        os.chmod(root, 0o700)
        key_path, cert_path = root/'key.pem', root/'cert.pem'
        key_path.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        os.chmod(key_path, 0o600)
        cert_path.write_bytes(cert.public_bytes(Encoding.PEM))
        signed = root/'signed.ipa'
        run([args.zsign, '-f', '-k', str(key_path), '-c', str(cert_path), '-m', str(Path(args.profile).resolve()),
             '-o', str(signed), '-t', str(root/'scratch'), str(Path(args.ipa).resolve())])
        signed_info, base = inspect_package(signed)
        if signed_info['CFBundleIdentifier'] != info['CFBundleIdentifier'] or signed_info['CFBundleVersion'] != info['CFBundleVersion']:
            raise ValueError('Signed identity/version mismatch')
        with zipfile.ZipFile(signed) as archive:
            if archive.read(base+'embedded.mobileprovision') != profile_bytes:
                raise ValueError('Device profile changed')
        extracted = root/'verify'
        run(['/usr/bin/ditto', '-x', '-k', str(signed), str(extracted)])
        apps = list((extracted/'Payload').glob('*.app'))
        if len(apps) != 1:
            raise ValueError('Expected one signed app')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(apps[0])])
        expiry = min(profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc).timestamp(), cert.not_valid_after_utc.timestamp())
        return deliver(signed, signed_info, args, expiry, token)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['ipa', 'p12', 'profile', 'udid', 'email', 'delivery-id', 'zsign']:
        parser.add_argument('--'+name, required=True)
    parser.add_argument('--openssl', default='openssl')
    try:
        print(json.dumps(fulfill(parser.parse_args())))
    except Exception:
        raise SystemExit('Signing/delivery failed; no installation success claimed. Credentials not logged.')
