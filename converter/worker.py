"""Private local-file IPC worker. No network listener or executable requests."""
import ctypes
import json
import os
from pathlib import Path
import re
import time
import traceback
import numpy as np
from converter.full_index import FullIndex,atomic_json
from converter.queries import CloudQuery,Camera,Pose
from converter.gpu_visibility import GpuVisibility

REQUEST=re.compile(r'req_([0-9a-f]{32})\.json\Z')


class Parent:
    def __init__(self,pid):
        self.pid=int(pid);self.handle=None
        if self.pid<=0: raise ValueError('父进程ID不正确')
        if os.name=='nt':
            from ctypes import wintypes
            self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            self.kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
            self.kernel.OpenProcess.restype=wintypes.HANDLE
            self.kernel.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
            self.kernel.CloseHandle.argtypes=[wintypes.HANDLE]
            self.handle=self.kernel.OpenProcess(0x100000,False,self.pid)
    def alive(self):
        if os.name=='nt': return bool(self.handle) and self.kernel.WaitForSingleObject(self.handle,0)==0x102
        try: os.kill(self.pid,0);return True
        except ProcessLookupError: return False
    def close(self):
        if self.handle:self.kernel.CloseHandle(self.handle);self.handle=None


def execute(query,request,folder,token):
    action=request.get('action');options=request.get('options',{})
    if not isinstance(options,dict):raise ValueError('查询选项无效')
    if action in ('view','full_view'):
        started=time.perf_counter()
        gpu=getattr(query,'gpu',None)
        if action=='full_view' and gpu:rows,info=gpu.full_view(request['camera'],options)
        elif action=='full_view':
            rows,info=query.full_view(request['camera'],options)
            info.update(engine='cpu',gpu_fallback=getattr(query,'gpu_error','GPU未初始化'))
        else:rows,info=query.view(request['camera'],options,request.get('limit',50_000))
        full=action=='full_view'
        colors=np.rint(rows['rgb']/query.index.meta['color_divisor']).astype('u1')
        if full:
            # Sort a frame by display color off the SU UI thread. Coordinates
            # are explicit world inches, ready for SketchUp's Point3d API.
            world=Pose(options).world(rows['xyz'])
            if options.get('color')=='gray':colors[:]=[65,68,72]
            elif options.get('color')=='height':
                low,high=np.asarray(query.index.meta['bounds_local_m'])[:,2]
                t=np.clip((rows['xyz'][:,2]-low)/max(high-low,.001),0,1)
                colors=np.column_stack((t*255,255*(1-np.abs(2*t-1)),(1-t)*255)).astype('u1')
            keys=(colors[:,0]//64).astype('u2')*64+(colors[:,1]//64).astype('u2')*8+colors[:,2]//64
            order=np.argsort(keys,kind='stable');groups=[];sorted_keys=keys[order]
            cuts=np.r_[0,np.flatnonzero(sorted_keys[1:]!=sorted_keys[:-1])+1,len(rows)]
            for a,b in zip(cuts[:-1],cuts[1:]):
                if b>a:groups.append({'color':np.rint(colors[order[a:b]].mean(axis=0)).astype(int).tolist(),'count':int(b-a)})
            if gpu:grid=gpu.last_grid.copy()
            else:
                cam=Camera(request['camera']);screen,_=cam.project(world)
                w=info['render_width'];h=info['render_height'];screen*=np.array([w/cam.width,h/cam.height])
                pixels=np.floor(screen+.5).astype('i8');grid=np.full(w*h,-1,dtype='<i4')
                grid[pixels[:,1]*w+pixels[:,0]]=np.arange(len(rows),dtype='i4')
            inverse=np.empty(len(order),dtype='i4');inverse[order]=np.arange(len(order),dtype='i4')
            valid=grid>=0;grid[valid]=inverse[grid[valid]]
            rows=rows[order];world=world[order];colors=colors[order]
            info.update(native_groups=groups,xyz_space='world_inches')
            cam=Camera(request['camera'])
            _,depth=cam.project(world)
            scale=info['render_width']/cam.width
            half=(depth if cam.perspective else np.ones(len(rows)))/(2*cam.fx*scale)
            delta=half[:,None]*cam.basis[0]
            vertices=np.stack((world-delta,world+delta),axis=1)/.0254
            vertex_file=f'frame_{token}.v64';vertices.astype('<f8').tofile(folder/vertex_file)
            info.update(vertices=vertex_file,primitive='lines')
        xyz=f'frame_{token}.f64' if full else f'frame_{token}.f32';rgb=f'frame_{token}.u8'
        (world/0.0254 if full else rows['xyz'].astype('<f4')).tofile(folder/xyz)
        colors.tofile(folder/rgb)
        if full:
            grid_file=f'frame_{token}.i32';grid.tofile(folder/grid_file);info['grid']=grid_file
            ids=f'frame_{token}.ids';rows['id'].astype('<u8').tofile(folder/ids);info['ids']=ids
        return dict(info,xyz=xyz,rgb=rgb,xyz_type='float64' if full else 'float32',compute_seconds=round(time.perf_counter()-started,3))
    if action=='pick':return {'pick':query.pick(request['camera'],request['x'],request['y'],options,
                                               request.get('radius',10),request.get('max_depth'))}
    if action=='stats':return query.stats(options)
    if action=='export':return query.export(request['path'],options)
    if action=='stop':return {'stopped':True}
    raise ValueError('未知点云查询')


def serve(cache,session,parent_pid):
    cache=Path(cache).resolve();folder=Path(session).resolve()
    if folder==cache or folder.is_relative_to(cache):raise ValueError('会话目录不能位于只读索引内')
    folder.mkdir(parents=True,exist_ok=True);parent=Parent(parent_pid)
    try:
        query=CloudQuery(FullIndex(cache));query.gpu=None
        try:query.gpu=GpuVisibility(query.index)
        except Exception as error:query.gpu_error=str(error)
        atomic_json(folder/'ready.json',{'state':'ready','pid':os.getpid(),
                    'engine':'opencl_gpu' if query.gpu else 'cpu','gpu_fallback':getattr(query,'gpu_error',None)})
        while parent.alive():
            requests=[p for p in folder.glob('req_*.json') if REQUEST.fullmatch(p.name)]
            # Small pick requests have priority over another viewport refresh.
            requests.sort(key=lambda p:(0 if '"pick"' in p.read_text(encoding='utf-8')[:120] else 1,p.stat().st_mtime_ns))
            if not requests:time.sleep(.04);continue
            path=requests[0];token=REQUEST.fullmatch(path.name)[1]
            request={}
            try:
                if path.stat().st_size>100_000:raise ValueError('查询请求过大')
                request=json.loads(path.read_text(encoding='utf-8'))
                result=execute(query,request,folder,token)
                response={'ok':True,'action':request.get('action'),'generation':request.get('generation'),'result':result}
            except Exception as e:
                response={'ok':False,'action':request.get('action'),'generation':request.get('generation'),'error':str(e)}
                (folder/'worker_error.log').write_text(traceback.format_exc(),encoding='utf-8')
            atomic_json(folder/f'res_{token}.json',response);path.unlink(missing_ok=True)
            if request.get('action')=='stop':break
    finally:
        if 'query' in locals() and getattr(query,'gpu',None):query.gpu.close()
        parent.close()
