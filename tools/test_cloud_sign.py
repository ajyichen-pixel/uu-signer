import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from cloud_sign import inspect_package

class CloudPackageTests(unittest.TestCase):
    def package(self, entries=None, cloud=True):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name)/'app.ipa'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/UU.app/Info.plist', plistlib.dumps({
                'CFBundleIdentifier':'click.uuxp.signer', 'CFBundleVersion':'2.9.1', 'UUCloudDelivery':cloud}))
            for name, data in (entries or {}).items():
                archive.writestr(name, data)
        return path

    def test_cloud_package(self):
        self.assertEqual(inspect_package(self.package())[0]['CFBundleVersion'], '2.9.1')

    def test_reject_embedded_keys(self):
        for name in ['Payload/UU.app/UUDevice/device.json', 'Payload/UU.app/cert.p12', 'private.pem']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                inspect_package(self.package({name:b'not-a-real-secret'}))

    def test_reject_path_traversal(self):
        with self.assertRaises(ValueError):
            inspect_package(self.package({'../outside':b'x'}))

    def test_reject_local_certificate_mode(self):
        with self.assertRaises(ValueError):
            inspect_package(self.package(cloud=False))

if __name__ == '__main__':
    unittest.main()
