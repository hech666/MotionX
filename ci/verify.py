from pathlib import Path
import subprocess,tempfile,struct,json,hashlib,plistlib
packages=list(Path('packages').glob('*.deb'));assert len(packages)==1,packages
pkg=packages[0]
control=subprocess.check_output(['dpkg-deb','-f',str(pkg)],text=True)
keys=[line.split(':',1)[0].lower() for line in control.splitlines() if line and not line[0].isspace()]
assert len(keys)==len(set(keys)), 'duplicate control field'
assert keys.count('installed-size')==1, 'Installed-Size must occur exactly once'
subprocess.run(['dpkg-deb','--info',str(pkg)],check=True)
with tempfile.TemporaryDirectory() as td:
 root=Path(td)
 subprocess.run(['dpkg-deb','-x',str(pkg),str(root)],check=True)
 libs=list(root.rglob('MotionX.dylib'));assert len(libs)==1,libs
 data=libs[0].read_bytes()
 magic,cpu,sub=struct.unpack_from('<III',data)
 assert magic==0xfeedfacf and cpu==0x100000c and sub==0x80000002,(hex(magic),cpu,hex(sub))
 macho=[]
 for p in root.rglob('*'):
  if p.is_file() and p.read_bytes()[:4] in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):macho.append(str(p.relative_to(root)))
 assert len(macho)==1,macho
 filters=list(root.rglob('MotionX.plist'));assert len(filters)==1
 f=plistlib.loads(filters[0].read_bytes())
 assert f['Filter']['Mode']=='Any'
 assert f['Filter']['Executables']==['SpringBoard','backboardd','replayd']
 o=32;signed=False
 for _ in range(struct.unpack_from('<I',data,16)[0]):
  cmd,size=struct.unpack_from('<II',data,o)
  if cmd==0x1d:signed=True
  o+=size
 assert signed,'missing code signature'
 report={'package':str(pkg),'sha256':hashlib.sha256(pkg.read_bytes()).hexdigest(),'bytes':pkg.stat().st_size,'architectures':['arm64e'],'cpu_subtype':hex(sub),'macho_files':macho,'filter':f,'runtime_tested':False}
 Path('verification.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
