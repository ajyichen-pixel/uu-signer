"""Offline integrity checks; iOS installation remains the final compatibility test.

Verifies Mach-O page hashes and CMS signatures against the expected certificate,
plus sealed resource hashes. Does not claim to replace Apple's trust/policy checks.
"""
import hashlib
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import zipfile
from cryptography import x509
from cryptography.hazmat.primitives import hashes

def slices(data):
    magic=data[:4]
    if magic in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
        count=struct.unpack_from('>I',data,4)[0]
        if count>16: raise ValueError('Too many architectures')
        wide=magic[-1]==0xbf
        for i in range(count):
            at=8+i*(32 if wide else 20)
            off,size=struct.unpack_from('>QQ' if wide else '>II',data,at+8)
            yield data[off:off+size]
    else: yield data

def verify_binary(data, expected, openssl='openssl', sealed=None):
    for part in slices(data):
        if part[:4] not in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe'):
            raise ValueError('Unsupported Mach-O')
        at=32 if part[0]==0xcf else 28
        count=struct.unpack_from('<I',part,16)[0]
        signature=None
        for _ in range(count):
            cmd,size=struct.unpack_from('<II',part,at)
            if size<8 or at+size>len(part): raise ValueError('Bad load command')
            if cmd==0x1d:
                off,length=struct.unpack_from('<II',part,at+8)
                signature=part[off:off+length]
            at+=size
        if signature is None: raise ValueError('Unsigned binary')
        magic,length,count=struct.unpack_from('>III',signature)
        if magic!=0xfade0cc0 or length>len(signature) or count>100: raise ValueError('Bad signature')
        blobs={}
        for i in range(count):
            kind,off=struct.unpack_from('>II',signature,12+8*i)
            _,size=struct.unpack_from('>II',signature,off)
            blobs[kind]=signature[off:off+size]
        cd=blobs[0]
        _,length,version,flags,hashoff,identoff,special,slots,limit=struct.unpack_from('>9I',cd)
        hs,ht,platform,shift=struct.unpack_from('4B',cd,36)
        if version>=0x20300 and limit==0xffffffff: limit=struct.unpack_from('>Q',cd,56)[0]
        if flags&2 or limit>len(part) or shift>20: raise ValueError('Invalid/ad-hoc signature')
        algorithm={1:'sha1',2:'sha256',3:'sha256',4:'sha384'}.get(ht)
        if not algorithm: raise ValueError('Unsupported hash')
        page=1<<shift
        if slots!=(limit+page-1)//page: raise ValueError('Code slot count mismatch')
        for i in range(slots):
            actual=hashlib.new(algorithm,part[i*page:min((i+1)*page,limit)]).digest()[:hs]
            if cd[hashoff+i*hs:hashoff+(i+1)*hs]!=actual: raise ValueError('Code page changed')
        for slot,kind in [(5,5),(7,7)]:
            if kind in blobs and special>=slot:
                if cd[hashoff-slot*hs:hashoff-(slot-1)*hs]!=hashlib.new(algorithm,blobs[kind]).digest()[:hs]:
                    raise ValueError('Entitlements changed')
        for slot,content in (sealed or {}).items():
            if special<slot or cd[hashoff-slot*hs:hashoff-(slot-1)*hs]!=hashlib.new(algorithm,content).digest()[:hs]:
                raise ValueError('Bundle metadata seal mismatch')
        with tempfile.TemporaryDirectory(prefix='uu-verify-') as folder:
            root=Path(folder);(root/'cd').write_bytes(cd);(root/'cms').write_bytes(blobs[0x10000][8:])
            result=subprocess.run([openssl,'cms','-verify','-binary','-inform','DER','-in',str(root/'cms'),
                '-content',str(root/'cd'),'-noverify','-signer',str(root/'signer.pem'),'-out',str(root/'verified')],capture_output=True)
            if result.returncode: raise ValueError('CMS signature invalid')
            signer=x509.load_pem_x509_certificate((root/'signer.pem').read_bytes())
            if signer.fingerprint(hashes.SHA256())!=expected.fingerprint(hashes.SHA256()): raise ValueError('Wrong signer')

def verify_ipa(path, certificate, openssl='openssl'):
    expected=x509.load_der_x509_certificate(Path(certificate).read_bytes())
    verified=0
    with zipfile.ZipFile(path) as archive:
        if archive.testzip(): raise ValueError('Damaged archive')
        names=set(archive.namelist())
        for name in names:
            if name.endswith('/'): continue
            with archive.open(name) as stream: magic=stream.read(4)
            if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
                base=name.rsplit('/',1)[0]+'/'
                sealed={slot:archive.read(base+rel) for slot,rel in [(1,'Info.plist'),(3,'_CodeSignature/CodeResources')] if base+rel in names}
                verify_binary(archive.read(name),expected,openssl,sealed);verified+=1
            if name.endswith('/_CodeSignature/CodeResources'):
                root=name.removesuffix('_CodeSignature/CodeResources')
                resources=plistlib.loads(archive.read(name))
                for rel,seal in resources.get('files2',resources.get('files',{})).items():
                    target=root+rel
                    if isinstance(seal,bytes): checks=[('sha1',seal)]
                    else: checks=[(alg,seal[key]) for key,alg in [('hash','sha1'),('hash2','sha256')] if key in seal]
                    if checks and target not in names:
                        if isinstance(seal,dict) and seal.get('optional'): continue
                        raise ValueError('Sealed resource missing')
                    for algorithm,checksum in checks:
                        if hashlib.new(algorithm,archive.read(target)).digest()!=checksum: raise ValueError('Resource changed: '+target)
    if not verified: raise ValueError('No executable found')
    return verified
