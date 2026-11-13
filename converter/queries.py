"""Bounded viewport LOD and exact full-index spatial queries."""
import itertools
import math
import os
from pathlib import Path
import numpy as np
from converter.full_index import RECORD


def finite_array(value,shape):
    a=np.asarray(value,dtype='f8')
    if a.shape!=shape or not np.isfinite(a).all(): raise ValueError('查询参数不是有效有限数值')
    return a


class Pose:
    def __init__(self,options):
        values=finite_array([options.get(k,0.) for k in ('x','y','z','angle')],(4,))
        if np.abs(values).max()>1e6: raise ValueError('位姿参数过大')
        self.offset=values[:3];a=math.radians(values[3]);c=math.cos(a);s=math.sin(a)
        self.rotation=np.array([[c,-s,0],[s,c,0],[0,0,1]])
        self.clip=None if options.get('clip') is None else finite_array(options['clip'],(6,)).reshape(2,3)
        if self.clip is not None and np.any(self.clip[0]>self.clip[1]): raise ValueError('裁剪范围倒置')
        self.slice=None
        if options.get('slice'):
            z,width=finite_array([options['slice_z'],options['slice_width']],(2,))
            if width<=0: raise ValueError('切片厚度须大于0')
            self.slice=(z-width/2,z+width/2)

    def world(self,xyz):
        # Three-column operations avoid spawning a BLAS thread team per tiny tile.
        c=self.rotation[0,0];s=self.rotation[1,0]
        return np.column_stack((xyz[:,0]*c-xyz[:,1]*s+self.offset[0],
                                xyz[:,0]*s+xyz[:,1]*c+self.offset[1],xyz[:,2]+self.offset[2]))

    def mask(self,world):
        keep=np.ones(len(world),dtype=bool)
        if self.clip is not None: keep&=((world>=self.clip[0])&(world<=self.clip[1])).all(axis=1)
        if self.slice is not None: keep&=(world[:,2]>=self.slice[0])&(world[:,2]<=self.slice[1])
        return keep

    def corners(self,tile):
        low,high=tile['bounds']
        return self.world(np.array(list(itertools.product(*zip(low,high)))))

    def intersects(self,corners):
        low=corners.min(axis=0);high=corners.max(axis=0)
        if self.clip is not None and (np.any(high<self.clip[0]) or np.any(low>self.clip[1])): return False
        return self.slice is None or (high[2]>=self.slice[0] and low[2]<=self.slice[1])


class Camera:
    def __init__(self,data):
        self.eye=finite_array(data['eye'],(3,))
        self.basis=finite_array([data['right'],data['up'],data['forward']],(3,3))
        if not np.allclose(self.basis@self.basis.T,np.eye(3),atol=1e-6): raise ValueError('相机方向不是正交单位向量')
        self.cx,self.cy,self.fx,self.fy,self.width,self.height=finite_array(
            [data[k] for k in ('cx','cy','fx','fy','width','height')],(6,))
        if min(self.fx,self.fy,self.width,self.height)<=0: raise ValueError('相机尺寸不正确')
        self.perspective=bool(data['perspective'])

    def project(self,world):
        delta=world-self.eye
        local=np.column_stack([delta[:,0]*row[0]+delta[:,1]*row[1]+delta[:,2]*row[2] for row in self.basis])
        depth=local[:,2]
        denominator=np.maximum(depth,1e-9) if self.perspective else 1.
        return np.column_stack((self.cx+local[:,0]*self.fx/denominator,
                                self.cy-local[:,1]*self.fy/denominator)),depth

    def tile_screen(self,corners):
        screen,depth=self.project(corners)
        if depth.max()<=1e-9: return None
        if self.perspective and depth.min()<=1e-9: return np.array([[-np.inf,-np.inf],[np.inf,np.inf]])
        return np.array([screen.min(axis=0),screen.max(axis=0)])


def display_keys(ids):
    # Stable spatially unbiased priority; changing viewpoint does not randomly flicker.
    with np.errstate(over='ignore'):
        z=ids.astype('u8')+np.uint64(0x9e3779b97f4a7c15)
        z=(z^(z>>30))*np.uint64(0xbf58476d1ce4e5b9)
        z=(z^(z>>27))*np.uint64(0x94d049bb133111eb)
        return z^(z>>31)


class CloudQuery:
    def __init__(self,index): self.index=index

    def selected(self,options):
        pose=Pose(options)
        for tile in self.index.tiles:
            if not pose.intersects(pose.corners(tile)): continue
            for rows in self.index.records(tile):
                world=pose.world(rows['xyz']);keep=pose.mask(world)
                if keep.any(): yield rows[keep],world[keep]

    def stats(self,options):
        count=0;low=np.full(3,np.inf);high=-low
        for rows,world in self.selected(options):
            count+=len(rows);low=np.minimum(low,world.min(axis=0));high=np.maximum(high,world.max(axis=0))
        return {'count':count,'bounds':None if not count else [low.tolist(),high.tolist()],
                'indexed_points':self.index.meta['indexed_points']}

    def view(self,camera,options,limit=50_000):
        limit=int(limit)
        if not 1<=limit<=100_000: raise ValueError('显示预算须为1至100000点')
        cam=Camera(camera);pose=Pose(options);result=np.empty(0,dtype=RECORD);keys=np.empty(0,dtype='u8')
        full=coarse=candidates=0
        for tile in self.index.tiles:
            corners=pose.corners(tile)
            if not pose.intersects(corners): continue
            rect=cam.tile_screen(corners)
            if rect is None or np.any(rect[1]<[-12,-12]) or np.any(rect[0]>[cam.width+12,cam.height+12]): continue
            # Thin slices and local clipping must not become sparse by filtering an
            # already-coarse tile sample. Query their intersecting tiles in full.
            lod=bool(pose.clip is None and pose.slice is None and
                     np.max(rect[1]-rect[0])<200 and tile['lod_count']<tile['count'])
            if lod: coarse+=1
            else: full+=1
            for rows in self.index.records(tile,lod=lod):
                world=pose.world(rows['xyz']);screen,depth=cam.project(world)
                keep=pose.mask(world)&(depth>1e-9)&(screen[:,0]>=-12)&(screen[:,0]<=cam.width+12)&(screen[:,1]>=-12)&(screen[:,1]<=cam.height+12)
                rows=rows[keep];candidates+=len(rows)
                result=np.concatenate((result,rows));keys=np.concatenate((keys,display_keys(rows['id'])))
                if len(result)>limit:
                    take=np.argpartition(keys,limit-1)[:limit];result=result[take];keys=keys[take]
        return result,{'indexed_points':self.index.meta['indexed_points'],'display_points':len(result),
                       'candidate_points':candidates,'full_tiles':full,'lod_tiles':coarse}

    def pick(self,camera,x,y,options,radius=10.,max_depth=None):
        x,y,radius=finite_array([x,y,radius],(3,))
        if not 0<radius<=32: raise ValueError('捕捉半径不正确')
        if max_depth is not None:
            max_depth=float(max_depth)
            if not math.isfinite(max_depth): raise ValueError('遮挡深度无效')
        cam=Camera(camera);pose=Pose(options);best=None;score=None;scanned=0
        for tile in self.index.tiles:
            corners=pose.corners(tile)
            if not pose.intersects(corners): continue
            rect=cam.tile_screen(corners)
            if rect is None or np.any(rect[1]<[x-radius,y-radius]) or np.any(rect[0]>[x+radius,y+radius]): continue
            # Always full-resolution; a point need not have appeared in any display LOD.
            for rows in self.index.records(tile):
                scanned+=len(rows);world=pose.world(rows['xyz']);screen,depth=cam.project(world)
                distance=((screen-[x,y])**2).sum(axis=1)
                keep=pose.mask(world)&(depth>1e-9)&(distance<=radius*radius)
                if max_depth is not None: keep&=depth<=max_depth
                chosen=np.flatnonzero(keep)
                if not len(chosen): continue
                order=np.lexsort((rows['id'][chosen],depth[chosen],distance[chosen]));i=chosen[order[0]]
                value=(float(distance[i]),float(depth[i]),int(rows['id'][i]))
                if score is None or value<score:
                    score=value;best={'source_id':int(rows['id'][i]),'local_m':rows['xyz'][i].tolist(),
                                     'world_m':world[i].tolist(),'rgb16':rows['rgb'][i].tolist(),
                                     'screen':screen[i].tolist(),'depth_m':float(depth[i])}
        if best is not None: best['scanned_points']=scanned
        return best

    def full_view(self,camera,options):
        """Resolve EVERY in-view source point against the actual viewport pixels.

        No sample, LOD or point budget is consulted. Nearest-depth visibility is
        the same necessary removal of overlapping fragments a z-buffer performs.
        Return actual source records, not a screen image, for SU's 3D depth test.
        """
        cam=Camera(camera);pose=Pose(options)
        width=int(camera.get('render_width',cam.width));height=int(camera.get('render_height',cam.height))
        if not 1<=width<=16384 or not 1<=height<=16384 or width*height>67_108_864:
            raise ValueError('视窗像素尺寸无效或超出支持的8K范围')
        size=width*height;depth_buffer=np.full(size,np.inf)
        winners=np.empty(size,dtype=RECORD);winners['id']=np.iinfo('u8').max
        scanned=in_view=full=0
        for tile in self.index.tiles:
            corners=pose.corners(tile)
            if not pose.intersects(corners):continue
            rect=cam.tile_screen(corners)
            if rect is None or np.any(rect[1]<[-.5,-.5]) or np.any(rect[0]>[cam.width,cam.height]):continue
            full+=1
            for rows in self.index.records(tile):
                scanned+=len(rows);world=pose.world(rows['xyz']);screen,depth=cam.project(world)
                screen*=np.array([width/cam.width,height/cam.height])
                keep=pose.mask(world)&(depth>1e-9)&(screen[:,0]>=-.5)&(screen[:,0]<width-.5)&(screen[:,1]>=-.5)&(screen[:,1]<height-.5)
                take=np.flatnonzero(keep);in_view+=len(take)
                if not len(take):continue
                xy=np.floor(screen[take]+.5).astype('i8');pixels=xy[:,1]*width+xy[:,0]
                z=depth[take];ids=rows['id'][take];old_depth=depth_buffer[pixels]
                improve=(z<old_depth)|((z==old_depth)&(ids<winners['id'][pixels]))
                take=take[improve];pixels=pixels[improve]
                if not len(take):continue
                # Resolve collisions within this input block before updating the
                # frame buffer; assignment order must not select a farther point.
                order=np.lexsort((rows['id'][take],depth[take],pixels))
                ordered_pixels=pixels[order]
                first=np.r_[True,ordered_pixels[1:]!=ordered_pixels[:-1]]
                chosen=take[order[first]];target=ordered_pixels[first]
                depth_buffer[target]=depth[chosen];winners[target]=rows[chosen]
        visible=winners[np.isfinite(depth_buffer)].copy()
        return visible,{'indexed_points':self.index.meta['indexed_points'],'scanned_points':scanned,
                        'in_view_points':in_view,'display_points':len(visible),'visible_pixel_points':len(visible),
                        'full_tiles':full,'lod_tiles':0,'render_mode':'full_visibility',
                        'render_width':width,'render_height':height,'point_budget':None}

    def export(self,path,options):
        path=Path(path).resolve()
        source=Path(self.index.meta['source_path']).resolve()
        if path==source or path.is_relative_to(self.index.root): raise ValueError('不能覆盖源文件或索引内部文件')
        if path.suffix.lower()!='.ply': raise ValueError('全量裁剪导出使用PLY格式')
        count=self.stats(options)['count'];temp=path.with_name(path.name+'.tmp')
        dtype=np.dtype([('x','<f8'),('y','<f8'),('z','<f8'),('red','<u2'),('green','<u2'),('blue','<u2')])
        header=('ply\nformat binary_little_endian 1.0\ncomment SHARE3DCAM full-index crop; original source coordinates in metres\n'
                f'element vertex {count}\nproperty double x\nproperty double y\nproperty double z\n'
                'property ushort red\nproperty ushort green\nproperty ushort blue\nend_header\n')
        written=0
        try:
            with temp.open('wb') as f:
                f.write(header.encode('ascii'))
                for rows,_world in self.selected(options):
                    a=np.empty(len(rows),dtype=dtype);original=rows['xyz']+self.index.meta['origin_m']
                    for i,k in enumerate(('x','y','z')): a[k]=original[:,i]
                    for i,k in enumerate(('red','green','blue')): a[k]=rows['rgb'][:,i]
                    a.tofile(f);written+=len(rows)
            if written!=count: raise ValueError('裁剪输出点数不一致')
            os.replace(temp,path)
        finally:
            if temp.exists():temp.unlink()
        return {'count':count,'path':str(path),'coordinates':'original source metres','rgb':'uint16'}
