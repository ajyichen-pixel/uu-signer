import datetime as dt
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12, pkcs7
from cryptography.x509.oid import NameOID
from personalize import personalize, validate


class PersonalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.now = dt.datetime.now(dt.timezone.utc)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "TEST ONLY - NOT APPLE")])
        cls.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                    .serial_number(x509.random_serial_number()).not_valid_before(cls.now-dt.timedelta(days=1))
                    .not_valid_after(cls.now+dt.timedelta(days=10)).sign(key, hashes.SHA256()))
        cls.key = key
        cls.p12 = pkcs12.serialize_key_and_certificates(b"test", key, cls.cert, None, serialization.BestAvailableEncryption(b"test-only"))
        cls.udid = "00000000-0000000000000001"

    def profile(self):
        return {"UUID": "test-profile", "ProvisionedDevices": [self.udid],
                "ExpirationDate": (self.now+dt.timedelta(days=5)).replace(tzinfo=None),
                "DeveloperCertificates": [self.cert.public_bytes(serialization.Encoding.DER)],
                "TeamIdentifier": ["TESTTEAM"], "Entitlements": {"application-identifier": "TESTTEAM.*"}}

    def check(self, p):
        validate(p, self.p12, "test-only", self.udid, "click.uuxp.signer", self.now)

    def test_valid_device(self):
        self.check(self.profile())

    def test_wrong_device(self):
        p = self.profile(); p["ProvisionedDevices"] = ["00000000-0000000000000002"]
        with self.assertRaises(ValueError): self.check(p)

    def test_shared_device_profile(self):
        p = self.profile(); p["ProvisionedDevices"].append("00000000-0000000000000002")
        with self.assertRaises(ValueError): self.check(p)

    def test_expired_profile(self):
        p = self.profile(); p["ExpirationDate"] = (self.now-dt.timedelta(seconds=1)).replace(tzinfo=None)
        with self.assertRaises(ValueError): self.check(p)

    def test_wrong_certificate(self):
        p = self.profile(); p["DeveloperCertificates"] = []
        with self.assertRaises(ValueError): self.check(p)

    def test_wrong_password(self):
        with self.assertRaises(ValueError): validate(self.profile(), self.p12, "wrong", self.udid, "click.uuxp.signer")

    def test_wrong_app(self):
        p = self.profile(); p["Entitlements"]["application-identifier"] = "TESTTEAM.other.app"
        with self.assertRaises(ValueError): self.check(p)

    def test_package_and_refuse_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            ipa = folder/"input.ipa"; provision = folder/"cert.mobileprovision"; key = folder/"cert.p12"; out = folder/"private.ipa"
            with zipfile.ZipFile(ipa, "w") as z:
                z.writestr("Payload/Feather.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "click.uuxp.signer"}))
                z.writestr("Payload/Feather.app/_CodeSignature/CodeResources", "old")
                z.writestr("Payload/Feather.app/UUDevice/old.txt", "stale")
            cms = (pkcs7.PKCS7SignatureBuilder().set_data(plistlib.dumps(self.profile())).add_signer(self.cert, self.key, hashes.SHA256())
                   .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary]))
            provision.write_bytes(cms); key.write_bytes(self.p12)
            result = personalize(ipa, key, provision, "test-only", self.udid, out)
            self.assertEqual(result["status"], "personalized_requires_signing")
            with zipfile.ZipFile(out) as z:
                self.assertIsNone(z.testzip())
                self.assertNotIn("Payload/Feather.app/UUDevice/old.txt", z.namelist())
                self.assertNotIn("Payload/Feather.app/_CodeSignature/CodeResources", z.namelist())
                m = json.loads(z.read("Payload/Feather.app/UUDevice/device.json"))
                self.assertEqual(m["deviceUDID"], self.udid)
            with self.assertRaises(ValueError): personalize(ipa, key, provision, "test-only", self.udid, out)


if __name__ == "__main__": unittest.main()

