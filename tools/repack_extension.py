"""Repackage Ruby/HTML-only changes using the already-tested frozen backend."""
from pathlib import Path
import hashlib
import json
import re
import zipfile
root=Path(__file__).resolve().parents[1]
version=re.search(r"extension.version = '([^']+)'",(root/'extension/share_pointcloud.rb').read_text('utf-8'))[1]
exe=root/'extension/share_pointcloud/bin/share_cloud_engine_080.exe'
assert exe.is_file() and exe.stat().st_size>1_000_000
release=root/'release';release.mkdir(exist_ok=True)
package=release/f'赛尔点云绘图助手_赛尔电商中心_安装包_{version}.rbz'
with zipfile.ZipFile(package,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for path in sorted((root/'extension').rglob('*')):
        if path.is_file() and path.name not in ('share_cloud_convert.exe','share_cloud_engine.exe','share_cloud_engine_070.exe','share_cloud_resident.dll','share_cloud_resident_050.dll','share_cloud_resident_080.dll','share_cloud_resident_081.dll','share_cloud_resident_095.dll'):z.write(path,path.relative_to(root/'extension').as_posix())
with zipfile.ZipFile(package) as z:assert z.testzip() is None
(release/f'安装包校验_{version}.json').write_text(json.dumps({'file':package.name,'bytes':package.stat().st_size,
    'sha256':hashlib.sha256(package.read_bytes()).hexdigest(),'backend_sha256':hashlib.sha256(exe.read_bytes()).hexdigest()},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'version':version,'bytes':package.stat().st_size},ensure_ascii=False))
