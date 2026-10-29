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
def packet(src=0x35,dst=0x21,dsrc=1,ddst=1,cmd=0x89,seq=0,version=3,payload=b'\x07',bad=None,cmdset=0x35,control=0x0d):
    b=bytearray([0xAA,version])+bytearray(len(payload).to_bytes(2,'little'))
    b+=bytes([crc8(b),control])+seq.to_bytes(4,'little')+b'\0\0'+bytes([src,dst,dsrc,ddst,cmdset,cmd])+payload
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
        telemetry=bytes.fromhex('a235050d000020c2')  # Public synthetic -40W USB-C1.
        access_cases=[]
        for name,params,kind,action,mode in [
            ('normal-check',{'payload':b'\x01\0'},1,2,1),
            ('response-control-differs',{'payload':b'\x01\0','control':0x08},1,2,1),
            ('normal-set',{'payload':b'\0\0'},1,1,1),
            ('omos-check',{'payload':b'\x01\x01'},1,2,2),
            ('unknown-action',{'payload':b'\x02\0'},1,0,1),
            ('unknown-mode',{'payload':b'\x01\x02'},1,2,0),
            ('short-status',{'payload':b'\x01'},1,0,0),
            ('long-status',{'payload':b'\x01\0\0'},1,0,0),
            ('request-reply',dict(src=2,cmdset=0xFE,cmd=0x11,seq=1,payload=b'\xb8\x04\x01'),2,0,0),
            ('wrong-reply-command',dict(src=2,cmdset=0xFE,cmd=0x12,seq=1,payload=b''),0,0,0),
            ('wrong-reply-sequence',dict(src=2,cmdset=0xFE,cmd=0x11,seq=0,payload=b''),0,0,0),
            ('display-active',dict(src=2,cmdset=0xFE,cmd=0x15,dsrc=0,ddst=0,seq=7,payload=telemetry),3,0,0),
            ('display-reply',dict(src=2,cmdset=0xFE,cmd=0x15,payload=telemetry),3,0,0),
            ('wrong-display-source',dict(src=3,cmdset=0xFE,cmd=0x15,payload=telemetry),0,0,0),
            ('mixed-route-v3-excluded',dict(src=2,dsrc=1,ddst=0,cmdset=0xFE,cmd=0x15,payload=telemetry),0,0,0),
            ('wrong-display-destination',dict(src=2,dst=0x20,cmdset=0xFE,cmd=0x15,payload=telemetry),0,0,0),
            ('wrong-display-routing',dict(src=2,dsrc=2,cmdset=0xFE,cmd=0x15,payload=telemetry),0,0,0),
            ('wrong-display-command',dict(src=2,cmdset=0xFE,cmd=0x16,payload=telemetry),0,0,0),
            ('provisioning-reply',dict(cmd=0x85,payload=b'\0'),0,0,0),
            ('credential-check-reply',dict(cmd=0x86,payload=b'\0'),0,0,0),
            ('unbind-reply',dict(cmd=0x84,payload=b'\0'),0,0,0),
            ('bad-display-crc',dict(src=2,cmdset=0xFE,cmd=0x15,payload=telemetry,bad='crc'),-1,0,0),
            ('unsupported-display-version',dict(src=2,cmdset=0xFE,cmd=0x15,payload=telemetry,version=19),-1,0,0),
        ]:
            access_cases.append(dict(name=name,ciphertext=session_encrypt(packet(**params)),kind=kind,action=action,mode=mode,
                telemetry=telemetry.hex() if kind==3 else ''))
        display_request=session_encrypt(packet(src=0x21,dst=2,cmdset=0xFE,cmd=0x11,seq=1,payload=b'\xb8\x04\x01'))
        # Public synthetic identity only; independent hashlib/OpenSSL reference.
        identity='123456789'; serial='P512000000000000'
        token=hashlib.md5((identity+serial).encode('ascii')).hexdigest().upper().encode('ascii')
        credential_request=session_encrypt(packet(src=0x21,dst=0x35,cmd=0x86,seq=2,payload=token))
        credential_cases=[]
        for name,params,kind,accepted in [
            ('accepted',dict(payload=b'\0'),4,1),
            ('accepted-different-control',dict(payload=b'\0',control=8),4,1),
            ('accepted-app-first-byte',dict(payload=b'\0\x01'),4,1),
            ('rejected',dict(payload=b'\x01'),4,0),
            ('unknown-result-rejected',dict(payload=b'\xff'),4,0),
            ('empty-reply',dict(payload=b''),-1,0),
            ('wrong-sequence',dict(seq=1,payload=b'\0'),0,0),
            ('wrong-source',dict(src=0x36,payload=b'\0'),0,0),
            ('wrong-destination',dict(dst=0x22,payload=b'\0'),0,0),
            ('wrong-device-source',dict(dsrc=0,payload=b'\0'),0,0),
            ('wrong-device-destination',dict(ddst=0,payload=b'\0'),0,0),
            ('wrong-command-set',dict(cmdset=0x34,payload=b'\0'),0,0),
            ('provisioning-not-check',dict(cmd=0x85,payload=b'\0'),0,0),
            ('bad-crc',dict(payload=b'\0',bad='crc'),-1,0),
            ('bad-header',dict(payload=b'\0',bad='header'),-1,0),
            ('bad-length',dict(payload=b'\0',bad='length'),-1,0),
            ('wrong-version',dict(payload=b'\0',version=19),-1,0),
        ]:
            args=dict(cmd=0x86,seq=2);args.update(params)
            credential_cases.append(dict(name=name,ciphertext=session_encrypt(packet(**args)),kind=kind,accepted=accepted))
        credential_cases.append(dict(name='bad-padding',ciphertext=session_encrypt(bytes(32),True),kind=-1,accepted=0))
        credential_cases.append(dict(name='short-inner',ciphertext=session_encrypt(b'\xaa\x03'),kind=-1,accepted=0))
        credential_cases.append(dict(name='other-inner-version',ciphertext=session_encrypt(packet(cmd=0x86,seq=2,payload=b'\0',version=4)),kind=-1,accepted=0))
        credential_plain=packet(cmd=0x86,seq=2,payload=b'\0')
        credential_cases.append(dict(name='zero-padding-valid-prefix',ciphertext=session_encrypt(credential_plain+b'\x0b'*10+b'\0',True),kind=-1,accepted=0))
        credential_cases.append(dict(name='inconsistent-padding',ciphertext=session_encrypt(credential_plain+b'\0'+b'\x0b'*10,True),kind=-1,accepted=0))
        def v19_packet(payload=telemetry,seq=73,src=2,dst=0x21,dsrc=0,ddst=0,cmdset=0xFE,cmd=0x15,bad=None,control=0x2d):
            # Independent native-derived wire layout: length excludes trailer.
            wire=bytes(b^(seq&255) for b in payload) if (control>>5)&3==1 else payload
            raw=bytearray(packet(src=src,dst=dst,dsrc=dsrc,ddst=ddst,cmdset=cmdset,cmd=cmd,
                                 seq=seq,version=19,payload=wire,control=control))
            check=(control>>2)&7
            if check<2:raw[-2:]=b'\xbb\xbb'  # Native checker ignores these bytes.
            if check==2:raw[-2:]=bytes([crc8(raw[:-2]),0])
            if bad=='length':raw[2]+=1;raw[4]=crc8(raw[:4])
            if bad=='header':raw[4]^=1
            if bad=='checksum':raw[-1]^=1
            if bad=='old-layout':raw[2]+=2;raw[4]=crc8(raw[:4])
            if bad=='truncated':raw=raw[:-1]
            if bad=='trailing':raw+=b'\0'
            return bytes(raw)
        v19_cases=[]
        for name,args,kind,failure in [
            ('display-xor',{},3,0),('display-key-zero',dict(seq=0),3,0),
            ('display-key-255',dict(seq=255),3,0),
            ('display-plain',dict(control=0x0d),3,0),
            ('observed-bank-route',dict(dsrc=1,ddst=0),3,0),
            ('reverse-mixed-route-excluded',dict(dsrc=0,ddst=1),0,0),
            ('display-no-check',dict(control=0x21),3,0),
            ('display-no-check-one',dict(control=0x25),3,0),
            ('display-crc8',dict(control=0x29),3,0),
            ('report-reply',dict(cmd=0x11,seq=1,dsrc=1,ddst=1,payload=b'\xb8\x04\x01'),2,0),
            ('wrong-source',dict(src=3),0,0),('wrong-destination',dict(dst=0x20),0,0),
            ('wrong-route',dict(dsrc=2),0,0),('wrong-command',dict(cmd=0x16),0,0),
            ('observed-fe12-remains-unclassified',dict(cmd=0x12,seq=1,dsrc=1,ddst=1,payload=bytes(7)),0,0),
            ('cannot-authenticate',dict(src=0x35,dsrc=1,ddst=1,cmdset=0x35,cmd=0x86,seq=2,payload=b'\0'),0,0),
            ('bad-header',dict(bad='header'),-1,3),
            ('bad-length',dict(bad='length'),-1,8),('truncated',dict(bad='truncated'),-1,8),
            ('trailing-data',dict(bad='trailing'),-1,8),
            ('bad-checksum',dict(bad='checksum'),-1,9),
            ('unsupported-encoding',dict(control=0x4d),-1,9),
            ('unsupported-check',dict(control=0x31),-1,9),
            ('old-incorrect-layout',dict(bad='old-layout'),-1,8),
            ('over-limit',dict(payload=bytes(985)),-1,8),
        ]:
            v19_cases.append(dict(name=name,ciphertext=session_encrypt(v19_packet(**args)),kind=kind,
                                  failure=failure,telemetry=telemetry.hex() if kind==3 else ''))
        healthy_cases=[]
        for mode,ceiling,floor,body in [(1,-1,-1,bytes.fromhex('e00b01')),(-1,80,0,bytes.fromhex('880250900200')),(2,100,20,bytes.fromhex('e00b02880264900214'))]:
            healthy_cases.append(dict(mode=mode,ceiling=ceiling,floor=floor,ciphertext=session_encrypt(packet(src=0x21,dst=2,cmdset=0xFE,cmd=0x11,seq=3,payload=body))))
        screen_cases=[]
        def vint(value):
            out=bytearray()
            while value>=128:out.append((value&127)|128);value>>=7
            out.append(value);return bytes(out)
        for field,value in [(12,30),(12,3600),(14,0),(14,100),(304,2),(305,60),(306,1),(554,4294967295)]:
            body=vint(field<<3)+vint(value)
            screen_cases.append(dict(field=field,value=value,ciphertext=session_encrypt(packet(src=0x21,dst=2,cmdset=0xFE,cmd=0x11,seq=3,payload=body))))
        clock_cases=[]
        for offset,zone in [(800,'Asia/Manila'),(-500,'America/New_York')]:
            body=vint(48)+vint(1800000000)+vint(56)+vint(offset & ((1<<64)-1))+vint(1082)+vint(len(zone))+zone.encode()+vint(1088)+vint(1)
            clock_cases.append(dict(offset=offset,zone=zone,ciphertext=session_encrypt(packet(src=0x21,dst=2,cmdset=0xFE,cmd=0x11,seq=3,payload=body))))
        vectors.append({'name':label,'local_private':local.to_bytes(21,'big').hex(),'peer_public':peer_public[-40:].hex(),'shared_secret':secret.hex(),
                        'valid_info':encrypt(bytes(range(18))),'wrong_length_info':encrypt(bytes(range(17))),
                        'invalid_padding_info':encrypt(bytes(32),True),'invalid_seed_info':encrypt(info[:16]+b'\xff\0'),'session_key':session_key,
                        'status_request':session_encrypt(packet(src=0x21,dst=0x35,payload=b'')), 'status_cases':status_cases,
                        'display_request':display_request,'access_cases':access_cases,
                        'clock_cases':clock_cases,'screen_cases':screen_cases,'healthy_cases':healthy_cases,'credential_request':credential_request,'credential_cases':credential_cases,'v19_cases':v19_cases})
out=Path(__file__).resolve().parents[1]/'SomnoireTests'/'ProbeVectors.json'
out.write_text(json.dumps({'provenance':'Public synthetic values generated independently with OpenSSL; no device or capture material.', 'vectors':vectors},indent=2)+'\n')
print('Generated two synthetic ECDH/AES vector sets, including a leading-zero shared secret.')
