"""Build a self-contained Windows converter and the installable RBZ."""
from pathlib import Path
import subprocess,sys,shutil,zipfile,json,hashlib,re
R=Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(R/'tools/collect_licenses.py')],cwd=R,check=True)
subprocess.run([sys.executable,str(R/'tools/build_native.py')],cwd=R,check=True)
subprocess.run([sys.executable,'-m','unittest','discover','-s','tests','-v'],cwd=R,check=True)
subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onefile','--windowed',
                '--name','share_cloud_convert','--paths',str(R),'--collect-all','laspy',
                '--collect-all','lazrs',str(R/'converter/main.py')],cwd=R,check=True)
binfolder=R/'extension/share_pointcloud/bin';binfolder.mkdir(parents=True,exist_ok=True)
shutil.copy2(R/'dist/share_cloud_convert.exe',binfolder/'share_cloud_engine_080.exe')
release=R/'release';release.mkdir(exist_ok=True)
version=re.search(r"extension.version = '([^']+)'",(R/'extension/share_pointcloud.rb').read_text('utf-8'))[1]
rbz=release/f'赛尔点云绘图助手_赛尔电商中心_安装包_{version}.rbz'
with zipfile.ZipFile(rbz,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted((R/'extension').rglob('*')):
        if p.is_file() and p.name not in ('share_cloud_convert.exe','share_cloud_engine.exe','share_cloud_engine_070.exe','share_cloud_resident.dll','share_cloud_resident_050.dll','share_cloud_resident_080.dll','share_cloud_resident_081.dll','share_cloud_resident_095.dll'):z.write(p,p.relative_to(R/'extension').as_posix())
with zipfile.ZipFile(rbz) as z:assert z.testzip() is None
(release/'安装包校验.json').write_text(json.dumps({'file':rbz.name,'bytes':rbz.stat().st_size,'sha256':hashlib.sha256(rbz.read_bytes()).hexdigest()},ensure_ascii=False,indent=2),encoding='utf-8')
print('RBZ BUILT',str(rbz),rbz.stat().st_size,flush=True)
