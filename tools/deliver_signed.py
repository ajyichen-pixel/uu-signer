"""Verify a privately signed IPA before delivering it. Never embeds credentials.

For Windows zsign output, independently verify code/CMS/resource seals and the
single-device provisioning profile. Real iOS installation is still required.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import plistlib
import subprocess
import zipfile
from cryptography import x509
from cryptography.hazmat.primitives.serialization import load_pem_private_key, pkcs12, NoEncryption
from cloud_sign import inspect_package, deliver
from personalize import validate
from verify_ipa_signature import verify_ipa

def verify(args):
    info, base = inspect_package(args.ipa)
    raw = Path(args.profile).read_bytes()
    result = subprocess.run([args.openssl,'cms','-verify','-inform','DER','-in',args.profile,'-noverify'],capture_output=True)
    if result.returncode: raise ValueError('Profile CMS verification failed')
    profile = plistlib.loads(result.stdout)
    cert = x509.load_der_x509_certificate(Path(args.certificate).read_bytes())
    key = load_pem_private_key(Path(args.key).read_bytes(),password=None)
    # Validate pairing entirely in memory, never write or upload a P12.
    p12 = pkcs12.serialize_key_and_certificates(b'private-validation',key,cert,None,NoEncryption())
    validate(profile,p12,'',args.udid,info['CFBundleIdentifier'])
    if profile['Entitlements'].get('get-task-allow'):
        raise ValueError('A distribution profile is required')
    with zipfile.ZipFile(args.ipa) as archive:
        if archive.read(base+'embedded.mobileprovision') != raw:
            raise ValueError('Embedded profile does not match')
    count = verify_ipa(args.ipa,args.certificate,args.openssl)
    expiry = min(profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc).timestamp(),cert.not_valid_after_utc.timestamp())
    return info,expiry,count

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ['ipa','profile','certificate','key','udid']:p.add_argument('--'+key,required=True)
    p.add_argument('--openssl',default='openssl')
    p.add_argument('--deliver',action='store_true')
    for key in ['email','delivery-id','token-file']:p.add_argument('--'+key)
    args=p.parse_args()
    info,expiry,count=verify(args)
    output=dict(bundleId=info['CFBundleIdentifier'],expires=int(expiry),verifiedExecutables=count,device_install_verified=False)
    if args.deliver:
        if not all([args.email,args.delivery_id,args.token_file]):p.error('Delivery requires email, delivery ID and private token file')
        output.update(deliver(args.ipa,info,args,expiry,Path(args.token_file).read_text().strip()))
    print(json.dumps(output))
