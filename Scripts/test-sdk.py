"""Fresh-install check: build-helper.sh, download all three release manifests (and optionally their archives,
to skip slow downloads) into ../plugin-template/dist,
then run python3 Scripts/test-sdk.py. Fetches and verifies archives as requested, evicts them after import,
uses a test signing key and blocked exit, and keeps logs and a GUI frame. Requires gh and Swift on macOS.
"""
import hashlib, json, os, pathlib, shutil, socket, struct, subprocess, sys, tempfile, threading, time, zlib

workspace = pathlib.Path(__file__).resolve().parents[2]
manifests = [json.loads((workspace/'plugin-template/dist'/f'{name}.json').read_text()) for name in ['template', 'hello-pty', 'hello-gui']]
root = pathlib.Path(tempfile.mkdtemp(prefix='v2mac-sdk-', dir='/private/tmp'))
print('Isolated runtime:', root, flush=True)
app = root / 'V2Mac Sandbox.app'
subprocess.run(['cp', '-cR', str(workspace/'sandbox/out/V2Mac Sandbox.app'), str(app)], check=True)
allowed=json.loads((app/'Contents/Resources/bases.json').read_text())['allowed']
assert all(m['from'] in allowed for m in manifests), 'helper does not bundle the released bases'
cache=root/'cache'; cache.mkdir()
downloads={}
for m in manifests:
    for layer in m['layers']:
        downloads[layer['sha256']]={**layer,'repo':m['source']['repo']}
        layer['url']='http://127.0.0.1:8765/'+layer['url'].rsplit('/',1)[1]
index={'version':1,'expires':'2099-01-01T00:00:00Z','minApi':1,'plugins':manifests,'templates':[{'id':'sdk-check','name':'SDK Check','plugins':[m['id'] for m in manifests]}],'revoked':[]}
(root/'index.json').write_text(json.dumps(index))
sign=root/'sign.swift'
sign.write_text('''import Foundation
import CryptoKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let signature = try key.signature(for: Data(SHA256.hash(data: Data(contentsOf: url))))
try signature.base64EncodedString().write(to: url.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
key=subprocess.check_output(['swift',str(sign),str(root/'index.json')],text=True).strip()
generated=[pathlib.Path.home()/'Applications/V2Mac Sandbox'/f"{m['name']} — SDK Check.app" for m in manifests]
shared=pathlib.Path.home()/'V2Mac Sandbox/SDK Check'
assert all(not p.exists() for p in generated+[shared]), 'SDK test name already in use'
host, child=socket.socketpair()
lock=threading.Lock()
errors=[]
def send(message):
    body=json.dumps(message).encode()
    with lock: host.sendall(struct.pack('>I',len(body))+body)
def exact(n):
    data=b''
    while len(data)<n:
        chunk=host.recv(n-len(data))
        if not chunk: raise EOFError
        data+=chunk
    return data
def link():
    try:
        while True:
            message=json.loads(exact(struct.unpack('>I',exact(4))[0]))
            if 'hello' in message:
                send({'hello':{'version':3,'ramCapMB':2048,'core':str(workspace/'app/Vendor/core/xray')}})
                send({'servers':{'_0':[{'id':'sdk-check','name':'SDK test (blocked)'}],'active':'sdk-check'}})
            elif 'outbound' in message:
                send({'outbound':{'id':message['outbound']['id'],'json':json.dumps({'protocol':'blackhole','settings':{}})}})
            elif 'fetch' in message:
                request=message['fetch']; path=root/request['url'].rsplit('/',1)[1]
                send({'downloaded':{'request':request['request'],'path':str(path)}})
            elif 'download' in message:
                request=message['download']; path=cache/request['sha256']
                if not path.exists():
                    layer=downloads[request['sha256']]
                    tag,filename=layer['url'].split('/releases/download/',1)[1].split('/',1)
                    archive=cache/filename
                    # A copy already in dist (checked below like a download) skips the slow fetch.
                    if (local:=workspace/'plugin-template/dist'/filename).exists(): subprocess.run(['cp','-c',str(local),str(archive)],check=True)
                    else: subprocess.run(['gh','release','download',tag,'--repo',layer['repo'],'--pattern',filename,'--dir',str(cache),'--clobber'],check=True)
                    digest=hashlib.sha256()
                    with archive.open('rb') as f:
                        while chunk:=f.read(1<<20): digest.update(chunk)
                    assert archive.stat().st_size==layer['size'] and digest.hexdigest()==layer['sha256'],archive
                    archive.rename(path)
                send({'downloaded':{'request':request['request'],'path':str(path)}})
    except EOFError: pass
    except Exception as error: errors.append(repr(error))
env={**os.environ,'V2MAC_SANDBOX_STORE':'http://127.0.0.1:8765/','V2MAC_SANDBOX_STORE_KEY':key,'V2MAC_SANDBOX_TEMPLATE':'sdk-check'}
log=open(root/'helper.log','w')
wrapper='import os,sys; fd=int(sys.argv[1]); os.dup2(fd,3); os.set_inheritable(3,True); os.execv(sys.argv[2],[sys.argv[2]])'
proc=subprocess.Popen([sys.executable,'-c',wrapper,str(child.fileno()),str(app/'Contents/MacOS/V2Mac Sandbox')],pass_fds=(child.fileno(),),env=env,stdout=log,stderr=subprocess.STDOUT)
child.close(); threading.Thread(target=link,daemon=True).start()
try:
    deadline=time.monotonic()+3600
    while time.monotonic()<deadline:
        try:
            vms=json.loads((root/'vms.json').read_text())
            for mini in vms:
                for installed in mini['apps']:
                    for layer in installed['layers']: (cache/layer['sha256']).unlink(missing_ok=True)
            if vms and len(vms[0]['apps'])==len(manifests): break
        except (OSError,json.JSONDecodeError): pass
        assert proc.poll() is None, 'helper exited before install'
        assert not errors,errors
        time.sleep(.5)
    else: raise AssertionError('SDK installation timed out; '+str(root/'helper.log'))
    mini=vms[0]
    assert all(a.get('image') and not a['unverified'] for a in mini['apps']),mini
    for bundle in generated:
        subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True,capture_output=True)
    (shared/'Shared/SDK_SHARED.txt').write_text('SDK Shared folder fixture\n')
    for appid,expected in [('my-plugin',b'My plugin is running'),('hello-pty',b'Hello from a V2Mac mini VM')]:
        pty=socket.socket(socket.AF_UNIX); pty.settimeout(90); pty.connect(str(root/'pty.sock'))
        pty.sendall(f"{mini['id']} {appid}\n".encode())
        output=b''
        while expected not in output:
            chunk=pty.recv(65536)
            assert chunk,output
            output+=chunk
        command=b'printf "SDK%s\\n" _COMMAND_OK; exit\n'
        pty.sendall(b'\0'+struct.pack('>H',len(command))+command)
        while b'SDK_COMMAND_OK' not in output:
            chunk=pty.recv(65536)
            assert chunk,output
            output+=chunk
        pty.close()
        print(appid+': imported image, launch and pty command passed',flush=True)
    print('Installed:',', '.join(a['id'] for a in mini['apps']),flush=True)
    if any(a['id']=='hello-gui' for a in mini['apps']):
        gui=socket.socket(socket.AF_UNIX); gui.settimeout(90); gui.connect(str(root/'pty.sock'))
        gui.sendall(f"gui {mini['id']} hello-gui 800 600 1\n".encode())
        def grecv(n):
            data=b''
            while len(data)<n:
                chunk=gui.recv(n-len(data))
                assert chunk,'GUI closed: '+repr(data)
                data+=chunk
            return data
        header=b''
        while not header.endswith(b'\n'): header+=grecv(1)
        assert header.startswith(b'ok '),header
        version=grecv(12); assert version==b'RFB 003.008\n',version
        gui.sendall(version)
        types=grecv(grecv(1)[0]); assert 1 in types,types
        gui.sendall(b'\1'); assert grecv(4)==b'\0'*4
        gui.sendall(b'\1'); info=grecv(24)
        width,height=struct.unpack('>HH',info[:4]); grecv(struct.unpack('>I',info[20:24])[0])
        assert (width,height)==(800,600),(width,height)
        gui.sendall(b'\0\0\0\0'+struct.pack('>BBBBHHHBBB3x',32,24,0,1,255,255,255,16,8,0))
        gui.sendall(b'\2\0\0\2'+struct.pack('>ii',0,-223))
        pixels=bytearray(width*height*4)
        def next_message():
            global width,height,pixels
            kind=grecv(1)[0]
            if kind==3:
                header=grecv(7)
                return grecv(struct.unpack('>I',header[3:])[0]).decode('utf-8')
            if kind==2: return None
            assert kind==0,kind
            update=grecv(3)
            for _ in range(struct.unpack('>H',update[1:])[0]):
                x,y,w,h,encoding=struct.unpack('>HHHHi',grecv(12))
                if encoding==-223:
                    assert (w,h) in [(800,600),(640,480)],(w,h)
                    width,height=w,h; pixels=bytearray(w*h*4)
                    continue
                assert encoding==0,encoding
                raw=grecv(w*h*4)
                if x+w>width or y+h>height: continue  # an old-size rectangle after a resize, dropped like RFBClient does
                for row in range(h):
                    offset=((y+row)*width+x)*4
                    pixels[offset:offset+w*4]=raw[row*w*4:(row+1)*w*4]
            return None
        for _ in range(300):
            gui.sendall(b'\3\0'+struct.pack('>HHHH',0,0,width,height))
            next_message()
            # hello-gui's light GTK window covers most of the screen; sway's background and a cursor don't.
            if sum(min(pixels[i:i+3])>200 for i in range(0,len(pixels),4))>width*height//2: break
            time.sleep(.1)
        else: raise AssertionError('hello-gui never drew its window')
        rgb=bytearray()
        for i in range(0,len(pixels),4): rgb.extend((pixels[i+2],pixels[i+1],pixels[i]))
        def png_chunk(kind,data):
            return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        rows=b''.join(b'\0'+rgb[y*width*3:(y+1)*width*3] for y in range(height))
        (root/'hello-gui.png').write_bytes(b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+png_chunk(b'IDAT',zlib.compress(rows))+png_chunk(b'IEND',b''))
        def key(sym,down): gui.sendall(struct.pack('>BBHI',4,int(down),0,sym))
        def ctrl(sym):
            key(0xffe3,True); key(ord(sym),True); key(ord(sym),False); key(0xffe3,False)
        def clipboard_contains(expected):
            for _ in range(30):
                text=next_message()
                if text is not None and expected in text: return text
            raise AssertionError('GUI clipboard did not contain '+expected)
        gui.sendall(struct.pack('>BBHH',5,1,80,80)+struct.pack('>BBHH',5,0,80,80))
        ctrl('a'); ctrl('c')
        text=clipboard_contains('SDK_SHARED.txt')
        assert 'Exit:' in text and 'Time zone:' in text,text
        typed='SDK سلام'.encode()
        gui.sendall(b'\xfa'+struct.pack('>I',len(typed))+typed)
        time.sleep(.5)
        ctrl('a'); ctrl('c'); clipboard_contains('SDK سلام')
        pasted=b'SDK pasted text'
        gui.sendall(b'\6\0\0\0'+struct.pack('>I',len(pasted))+pasted)
        time.sleep(.2)
        ctrl('v'); time.sleep(.2); ctrl('a'); ctrl('c'); clipboard_contains(pasted.decode())
        gui.sendall(b'\xfc'+struct.pack('>HHB',640,480,1))
        for _ in range(30):
            gui.sendall(b'\3\0'+struct.pack('>HHHH',0,0,640,480)); next_message()
            if (width,height)==(640,480): break
            time.sleep(.1)
        assert (width,height)==(640,480),(width,height)
        gui.close()
        print('hello-gui: imported image, frame, Shared, Unicode input, clipboard both ways and 800x600 → 640x480 resize passed',flush=True)
finally:
    try: send({'quit':{}})
    except OSError: pass
    try: proc.wait(timeout=20)
    except subprocess.TimeoutExpired: proc.terminate(); proc.wait(timeout=10)
    host.close(); log.close()
    for path in generated+[shared]:
        if path.exists(): shutil.rmtree(path)
    (root/'data.img').unlink(missing_ok=True)
    shutil.rmtree(app)
    shutil.rmtree(cache)
    print('Helper stopped. Evidence:',root/'helper.log',flush=True)
