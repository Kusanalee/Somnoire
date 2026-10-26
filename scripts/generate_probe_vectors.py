#!/usr/bin/env python3
"""Generate PUBLIC, SYNTHETIC test vectors with OpenSSL; never reads device captures.
Development only. Runtime Somnoire has no OpenSSL or Python dependency.
"""
from pathlib import Path
import hashlib,json,subprocess,tempfile

def openssl(*args, data=None):
    p=subprocess.run(['openssl',*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
    return p.stdout

def private_der(scalar):
    content=b'\x02\x01\x01\x04\x15'+scalar.to_bytes(21,'big')+bytes.fromhex('a00706052b81040008')
    return b'\x30'+bytes([len(content)])+content

def public_der(scalar):return openssl('ec','-inform','DER','-pubout','-outform','DER',data=private_der(scalar))

vectors=[]
table=(Path(__file__).resolve().parents[1]/'Vendor/EcoFlowProtocol/session_table.bin').read_bytes()
assert len(table)==65280 and hashlib.sha256(table).hexdigest()=='3d1ba59b40c46bc86ba35fa231a3db196b448bbdfb1635c88ddd42f24abd4b2a'
def crc16(data):
    value=0
    for b in data:
        value ^= b
        for _ in range(8): value=(value>>1)^0xA001 if value&1 else value>>1
    return value.to_bytes(2,'little')
def crc8(data):
    value=0
    for b in data:
        value ^= b
        for _ in range(8): value=((value<<1)^7)&255 if value&128 else (value<<1)&255
    return value
assert crc8(b'123456789')==0xF4
def packet(src=0x35,dst=0x21,dsrc=1,ddst=1,cmd=0x89,seq=0,version=3,payload=b'\x07',bad=None):
    b=bytearray([0xAA,version])+bytearray(len(payload).to_bytes(2,'little'))
    b+=bytes([crc8(b),0x0D])+seq.to_bytes(4,'little')+b'\0\0'+bytes([src,dst,dsrc,ddst,0x35,cmd])+payload
    if bad=='length': b[2]+=1; b[4]=crc8(b[:4])
    if bad=='header': b[4]^=1
    b+=crc16(b)
    if bad=='crc': b[-1]^=1
    return bytes(b)
# The shared point is (local * peer)G. Find a public synthetic peer that
# produces a leading-zero X coordinate with local scalar seven.
leading=next(n for n in range(2,4096) if public_der(7*n)[-40]==0)
with tempfile.TemporaryDirectory() as directory:
    folder=Path(directory)
    for label,local,peer in [('ordinary',7,11),('leading-zero',7,leading)]:
        local_file=folder/'local.der';peer_file=folder/'peer.der'
        local_file.write_bytes(private_der(local));peer_public=public_der(peer);peer_file.write_bytes(peer_public)
        secret=openssl('pkeyutl','-derive','-inkey',str(local_file),'-keyform','DER','-peerkey',str(peer_file),'-peerform','DER')
        assert len(secret)==20
        key=secret[:16].hex();iv=hashlib.md5(secret).hexdigest()
        def encrypt(data,nopad=False):return openssl('enc','-aes-128-cbc','-K',key,'-iv',iv,*(['-nopad'] if nopad else []),data=data).hex()
        info=bytes(range(18));offset=info[16]*16+((info[17]-1)&255)*256
        session_key=hashlib.md5(table[offset:offset+16]+info[:16]).hexdigest()
        def session_encrypt(data,nopad=False):return openssl('enc','-aes-128-cbc','-K',session_key,'-iv',iv,*(['-nopad'] if nopad else []),data=data).hex()
        cases=[('matching',packet(),1),('wrong-source',packet(src=0x36),0),('wrong-destination',packet(dst=0x22),0),
               ('wrong-device-routing',packet(ddst=0),0),('login-not-status',packet(cmd=0x86),0),('wrong-sequence',packet(seq=1),0),
               ('bad-header-crc',packet(bad='header'),-1),('bad-packet-crc',packet(bad='crc'),-1),
               ('bad-length',packet(bad='length'),-1),('unsupported-version',packet(version=0x13),-1)]
        status_cases=[{'name':n,'ciphertext':session_encrypt(p),'result':r} for n,p,r in cases]
        status_cases += [{'name':'bad-padding','ciphertext':session_encrypt(bytes(32),True),'result':-1},
                         {'name':'too-short-inner','ciphertext':session_encrypt(b'\xAA\x03'),'result':-1}]
        vectors.append({'name':label,'local_private':local.to_bytes(21,'big').hex(),'peer_public':peer_public[-40:].hex(),'shared_secret':secret.hex(),
                        'valid_info':encrypt(bytes(range(18))),'wrong_length_info':encrypt(bytes(range(17))),
                        'invalid_padding_info':encrypt(bytes(32),True),'invalid_seed_info':encrypt(info[:16]+b'\xff\0'),'session_key':session_key,
                        'status_request':session_encrypt(packet(src=0x21,dst=0x35,payload=b'')), 'status_cases':status_cases})
out=Path(__file__).resolve().parents[1]/'SomnoireTests'/'ProbeVectors.json'
out.write_text(json.dumps({'provenance':'Public synthetic values generated independently with OpenSSL; no device or capture material.', 'vectors':vectors},indent=2)+'\n')
print('Generated two synthetic ECDH/AES vector sets, including a leading-zero shared secret.')
