"""Run the packaged converter without relying on the developer Python path."""
from pathlib import Path
import json,math,os,struct,subprocess,tempfile
import laspy
import numpy as np
from PIL import Image
import trimesh
ROOT=Path(__file__).resolve().parents[1]
ENGINE=ROOT/'extension/share_pointcloud/bin/macos-arm64/share_cloud_engine'

def main():
    env=os.environ.copy();env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None)
    results=[]
    with tempfile.TemporaryDirectory(prefix='赛尔 Mac 测试 ') as tmp:
        root=Path(tmp)
        def run(source,mode):
            out=root/(source.stem+'_'+source.suffix[1:]+'_索引')
            p=subprocess.run([str(ENGINE),mode,'--source',str(source),'--out',str(out),'--unit','m','--limit','10'],cwd=root,env=env,capture_output=True,text=True,timeout=120)
            status=json.loads((out/'status.json').read_text('utf-8')) if (out/'status.json').is_file() else {}
            if p.returncode or status.get('state')!='complete':raise RuntimeError({'file':source.name,'status':status,'stderr':p.stderr[-1500:]})
            results.append({'format':source.suffix,'mode':mode,'state':'passed','result':status})
            return out,status
        header=laspy.LasHeader(point_format=3,version='1.2');cloud=laspy.LasData(header)
        cloud.x=[0,1];cloud.y=[0,1];cloud.z=[0,1];cloud.red=[65535,0];cloud.green=[0,65535];cloud.blue=[0,0]
        for ext in ['las','laz']:
            source=root/('室内 点云.'+ext);cloud.write(source);run(source,'--index')
        for ext in ['xyz','txt','pts']:
            source=root/('室内 点云.'+ext);source.write_text(('2\n' if ext=='pts' else '')+'0 0 0 255 0 0\n1 1 1 0 255 0\n');run(source,'--index')
        source=root/'彩色 点云.ply';source.write_text('ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n0 0 0 255 0 0\n1 1 1 0 255 0\n');run(source,'--index')
        source=root/'室内 高斯.ply';fields=['x','y','z']+[f'f_dc_{i}' for i in range(3)]+[f'scale_{i}' for i in range(3)]+[f'rot_{i}' for i in range(4)]+['opacity']
        source.write_bytes(('ply\nformat binary_little_endian 1.0\nelement vertex 1\n'+''.join('property float '+f+'\n' for f in fields)+'end_header\n').encode()+struct.pack('<14f',0,0,0,0,0,0,*([math.log(.1)]*3),1,0,0,0,0))
        out,_=run(source,'--gaussian');assert json.loads((out/'cloud.json').read_text())['kind']=='gaussian'
        for ext in ['glb','obj']:
            source=root/('贴图 网格.'+ext);mesh=trimesh.creation.box()
            mesh.visual=trimesh.visual.TextureVisuals(uv=mesh.vertices[:,:2]+.5,image=Image.new('RGB',(8,8),(210,120,80)))
            mesh.export(source);out,status=run(source,'--mesh')
            assert status['triangles']==12 and status['textures']>=1 and (out/'mesh.dae').is_file(),status
    folder=ROOT/'build/macos-arm64';folder.mkdir(parents=True,exist_ok=True)
    (folder/'frozen-validation.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'frozen_formats_passed':len(results),'results':results},ensure_ascii=False))

if __name__=='__main__':main()
