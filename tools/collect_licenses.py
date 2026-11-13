from pathlib import Path
from importlib import metadata
import shutil,sys,json
R=Path(__file__).resolve().parents[1]
out=R/'extension/share_pointcloud/第三方许可'
out.mkdir(parents=True,exist_ok=True)
records=[]
for name in ['numpy','laspy','lazrs','pyinstaller','altgraph','packaging','pefile','pywin32-ctypes','pillow','pycollada','python-dateutil','trimesh','tzdata']:
    dist=metadata.distribution(name)
    files=[]
    for item in dist.files or []:
        text=str(item).lower()
        if any(term in text for term in ['license','copying','notice']) and not text.endswith(('.pyc','.py')):
            source=Path(dist.locate_file(item))
            if source.is_file():
                target=out/name/source.name
                target.parent.mkdir(exist_ok=True)
                if target.exists():target=target.with_name(str(len(files))+'_'+target.name)
                shutil.copy2(source,target);files.append(str(target.relative_to(out)))
    records.append({'软件包':name,'版本':dist.version,'原始许可文件':files})
license_file=Path(sys.base_prefix)/'LICENSE.txt'
if license_file.exists():shutil.copy2(license_file,out/'Python原始许可.txt')
(out/'第三方组件清单.json').write_text(json.dumps(records,ensure_ascii=False,indent=2),encoding='utf-8')
print('License originals preserved',len(records),'packages')
