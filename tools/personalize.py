"""Private fulfillment step: inject ONE device's signing assets before final signing.

This does not purchase certificates, verify payments, or sign the output IPA.
Call only from a trusted paid-order fulfillment worker after provider delivery.
Never publish output in public Releases, software sources, or Actions artifacts.
Requires cryptography and OpenSSL; pass the P12 password via an environment variable.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tempfile
import zipfile
from cryptography.hazmat.primitives.serialization import pkcs12, Encoding


def validate(profile, p12, password, udid, bundle_id, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if not re.fullmatch(r"(?:[a-fA-F0-9]{8}-[a-fA-F0-9]{16}|[a-fA-F0-9]{40})", udid):
        raise ValueError("Invalid device identifier")
    if profile.get("ProvisionedDevices") != [udid] or profile.get("ProvisionsAllDevices"):
        raise ValueError("A profile restricted to exactly this one device is required")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime) or expiration.replace(tzinfo=dt.timezone.utc) <= now:
        raise ValueError("Profile expired")
    key, cert, _ = pkcs12.load_key_and_certificates(p12, password.encode() or None)
    if key is None or cert is None:
        raise ValueError("Certificate/private key missing")
    if cert.not_valid_after_utc <= now or cert.not_valid_before_utc > now:
        raise ValueError("Certificate is not currently valid")
    if cert.public_bytes(Encoding.DER) not in profile.get("DeveloperCertificates", []):
        raise ValueError("P12 does not match the profile")
    app_id = profile.get("Entitlements", {}).get("application-identifier", "")
    team = profile.get("TeamIdentifier", [])
    if len(team) != 1 or not app_id.startswith(team[0] + "."):
        raise ValueError("Invalid team/application identifier")
    pattern = app_id[len(team[0]) + 1:]
    if not (pattern == bundle_id or (pattern.endswith("*") and bundle_id.startswith(pattern[:-1]))):
        raise ValueError("Profile cannot sign UU Signer")
    if not profile.get("UUID"):
        raise ValueError("Missing profile identity")


def personalize(ipa, p12_path, profile_path, password, udid, output, openssl="openssl"):
    ipa, output = Path(ipa).resolve(), Path(output).resolve()
    if output.exists() or output == ipa:
        raise ValueError("Output must be a new private file")
    # Verify CMS content signature. Apple trust/device eligibility is checked by final signing/iOS,
    # not claimed by this packaging check. Do not accept an unsigned XML plist as a provider profile.
    result = subprocess.run([openssl, "cms", "-verify", "-inform", "DER", "-in", str(profile_path), "-noverify"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError("Provisioning profile CMS signature failed")
    profile = plistlib.loads(result.stdout)
    p12 = Path(p12_path).read_bytes()
    provision = Path(profile_path).read_bytes()
    with zipfile.ZipFile(ipa) as source:
        if source.testzip() is not None:
            raise ValueError("Damaged IPA")
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive entries")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("Unsafe archive path")
        infos = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(infos) != 1:
            raise ValueError("Expected exactly one app")
        info = plistlib.loads(source.read(infos[0]))
        if info.get("CFBundleIdentifier") != "click.uuxp.signer":
            raise ValueError("Input is not UU Signer")
        validate(profile, p12, password, udid, info["CFBundleIdentifier"])
        base = infos[0].removesuffix("Info.plist")
        manifest = {"profileUUID": profile["UUID"], "deviceUDID": udid, "password": password,
                    "p12SHA256": hashlib.sha256(p12).hexdigest(), "profileSHA256": hashlib.sha256(provision).hexdigest()}
        output.parent.mkdir(parents=True, exist_ok=True)
        fd, scratch = tempfile.mkstemp(prefix="uu-private-", suffix=".ipa", dir=output.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(scratch, "w", zipfile.ZIP_DEFLATED) as dest:
                for entry in source.infolist():
                    if entry.filename.startswith((base + "UUDevice/", base + "signing-assets/", base + "_CodeSignature/")):
                        continue
                    dest.writestr(entry, source.read(entry))
                dest.writestr(base + "UUDevice/cert.p12", p12)
                dest.writestr(base + "UUDevice/cert.mobileprovision", provision)
                dest.writestr(base + "UUDevice/device.json", json.dumps(manifest))
            os.replace(scratch, output)
        finally:
            if Path(scratch).exists():
                Path(scratch).unlink()
    return {"status": "personalized_requires_signing", "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for option in ["ipa", "p12", "profile", "udid", "output"]:
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--password-env", default="UU_P12_PASSWORD")
    args = parser.parse_args()
    if args.password_env not in os.environ:
        parser.error("Certificate password environment variable is missing")
    try:
        print(json.dumps(personalize(args.ipa, args.p12, args.profile, os.environ[args.password_env], args.udid, args.output, args.openssl)))
    except Exception as error:
        # Avoid printing credential contents or subprocess output.
        raise SystemExit("Personalization failed: " + str(error))

