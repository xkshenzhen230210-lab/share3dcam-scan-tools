"""Package only native arm64 binaries; never create a falsely usable RBZ."""
from pathlib import Path
import hashlib
import json
import re
import stat
import struct
import zipfile

def require_arm64(path, filetype):
    path=Path(path)
    with path.open('rb') as f: header=f.read(32)
    if len(header)!=32: raise ValueError(f'Incomplete Mach-O: {path.name}')
    magic,cpu,_,kind,*_=struct.unpack('<8I',header)
    if (magic,cpu,kind)!=(0xFEEDFACF,0x0100000C,filetype):
        raise ValueError(f'Expected native arm64 Mach-O ({filetype}): {path.name}')

def package(root, output):
    root=Path(root);output=Path(output);ext=root/'extension';binaries=ext/'share_pointcloud/bin/macos-arm64'
    for name,kind in [('share_cloud_engine',2),('libshare_cloud_resident.dylib',6)]:require_arm64(binaries/name,kind)
    version=re.search(r"extension.version = '([^']+)'",(ext/'share_pointcloud.rb').read_text('utf-8'))[1]
    output.mkdir(parents=True,exist_ok=True)
    result=output/f'赛尔点云绘图助手_M系列Mac_中英双语_测试版_{version}.rbz'
    validation=root/'build/macos-arm64/native-validation.json'
    native_validation=json.loads(validation.read_text('utf-8')) if validation.is_file() else {'gpu_status':'not run','gpu_runtime_tests_passed':False}
    info=dict(platform='macOS',architecture='arm64',version=version,sketchup_mac_acceptance_passed=False,native_validation=native_validation,
              signing='ad-hoc developer test build; not notarized',
              native_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries.iterdir() if p.is_file()})
    with zipfile.ZipFile(result,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(ext.rglob('*')):
            if not p.is_file() or '__pycache__' in p.parts:continue
            rel=p.relative_to(ext)
            if 'bin' in rel.parts and (not p.is_relative_to(binaries) or p.name not in ['share_cloud_engine','libshare_cloud_resident.dylib']):continue
            if p.suffix.lower() in ('.exe','.dll','.pdb','.lib','.exp','.pyc'):continue
            entry=zipfile.ZipInfo(rel.as_posix());entry.create_system=3;entry.compress_type=zipfile.ZIP_DEFLATED
            mode=0o755 if p.parent==binaries else 0o644
            entry.external_attr=(stat.S_IFREG|mode)<<16
            z.writestr(entry,p.read_bytes())
        z.writestr('share_pointcloud/bin/macos-arm64/build.json',json.dumps(info,ensure_ascii=False,indent=2))
    with zipfile.ZipFile(result) as z:
        if z.testzip():raise ValueError('RBZ integrity check failed')
    (output/'Mac安装包校验.json').write_text(json.dumps(dict(file=result.name,sha256=hashlib.sha256(result.read_bytes()).hexdigest(),**info),ensure_ascii=False,indent=2),encoding='utf-8')
    return result

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    print(package(root,root/'release/macos-arm64'))
