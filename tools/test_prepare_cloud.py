import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile
from prepare_cloud import prepare

class PrepareTests(unittest.TestCase):
    def test_cloud_removes_only_obsolete_key_and_signatures(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'test.ipa'
            with zipfile.ZipFile(p,'w') as z:
                z.writestr('Payload/Feather.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'click.uuxp.signer','UUCloudDelivery':True}))
                z.writestr('Payload/Feather.app/server.pem',b'fixture')
                z.writestr('Payload/Feather.app/_CodeSignature/CodeResources',b'old')
                z.writestr('Payload/Feather.app/Feather',b'executable-preserved')
            prepare(p)
            with zipfile.ZipFile(p) as z:
                self.assertEqual(z.read('Payload/Feather.app/Feather'),b'executable-preserved')
                self.assertFalse(any(n.endswith('.pem') or '/_CodeSignature/' in n for n in z.namelist()))

    def test_does_not_silently_remove_unknown_private_key(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'test.ipa'
            with zipfile.ZipFile(p,'w') as z:
                z.writestr('Payload/Feather.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'click.uuxp.signer','UUCloudDelivery':True}))
                z.writestr('Payload/Feather.app/unexpected.p12',b'fixture')
            original=p.read_bytes()
            with self.assertRaises(ValueError):prepare(p)
            self.assertEqual(p.read_bytes(),original)
