"""Remove obsolete local-server key and signatures from a cloud-mode build."""
from pathlib import Path
import argparse
import os
import plistlib
import tempfile
import zipfile
from cloud_sign import inspect_package

def prepare(path):
    path=Path(path)
    fd,temporary=tempfile.mkstemp(suffix='.ipa',dir=path.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(path) as source:
            info=plistlib.loads(source.read('Payload/Feather.app/Info.plist'))
            if info.get('CFBundleIdentifier')!='click.uuxp.signer' or not info.get('UUCloudDelivery'):
                raise ValueError('Only UU cloud builds may remove the legacy TLS key')
            with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED) as target:
                for entry in source.infolist():
                    if entry.filename=='Payload/Feather.app/server.pem' or '/_CodeSignature/' in entry.filename:continue
                    target.writestr(entry,source.read(entry))
        inspect_package(temporary)
        os.replace(temporary,path)
    finally:
        if Path(temporary).exists():Path(temporary).unlink()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('ipa');prepare(p.parse_args().ipa)
