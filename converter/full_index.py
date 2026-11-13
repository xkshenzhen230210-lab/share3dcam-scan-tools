"""Lossless XYZ/RGB spatial index. Display LOD never replaces indexed records."""
import json
import os
from pathlib import Path
import numpy as np
from converter.cloud import BLOCK, UNITS, las_chunks, ply_chunks, text_chunks

RECORD = np.dtype([('xyz','<f8',(3,)),('rgb','<u2',(3,)),('id','<u8')])


def reader_for(source):
    suffix = source.suffix.lower()
    if suffix in ('.las','.laz'): return las_chunks
    if suffix == '.ply': return ply_chunks
    if suffix in ('.xyz','.txt','.pts'): return text_chunks
    raise ValueError('支持LAS、LAZ、PLY、XYZ、TXT、PTS；其他格式请先转换')


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name+'.tmp')
    temp.write_text(json.dumps(value,ensure_ascii=False,allow_nan=False),encoding='utf-8')
    os.replace(temp,path)


def snapshot(path):
    stat = path.stat()
    return stat.st_size,stat.st_mtime_ns


def blocks(source, unit):
    offset = 0
    for xyz,rgb in reader_for(source)(source):
        xyz = np.asarray(xyz,dtype='f8')
        ids = np.arange(offset,offset+len(xyz),dtype='u8'); offset += len(xyz)
        good = np.isfinite(xyz).all(axis=1)
        invalid = int((~good).sum())
        xyz = xyz[good]*UNITS[unit]
        if not np.isfinite(xyz).all(): raise ValueError('单位换算后坐标溢出')
        color = rgb is not None
        if rgb is None: rgb = np.full(xyz.shape,190,dtype='u2')
        else:
            rgb = np.asarray(rgb)[good]
            rgb = np.rint(np.clip(np.nan_to_num(rgb,nan=190,posinf=65535,neginf=0),0,65535)).astype('u2')
        rows = np.empty(len(xyz),dtype=RECORD)
        rows['xyz']=xyz;rows['rgb']=rgb;rows['id']=ids[good]
        yield rows,invalid,color,offset


def build_index(source,out,preview_limit=50_000,lod_limit=512,unit='m',progress=None):
    source=Path(source);out=Path(out)
    if unit not in UNITS: raise ValueError('单位不正确')
    if not 1<=preview_limit<=100_000 or not 1<=lod_limit<=4096: raise ValueError('概览或分块LOD点数不正确')
    if out.exists() and any(out.glob('cloud.json')): raise ValueError('索引已存在，请使用新的目录')
    # An interrupted build may contain append-only tiles: never append to that data.
    if (out/'tiles').exists(): raise ValueError('此目录含未完成索引，请另选空目录')
    before=snapshot(source);valid=invalid=0;has_color=False;color_max=0
    low=np.full(3,np.inf);high=-low
    preview=np.empty(0,dtype=RECORD);keys=np.empty(0);rng=np.random.default_rng(83471)
    for rows,bad,color,read in blocks(source,unit):
        valid+=len(rows);invalid+=bad;has_color|=color
        if len(rows):
            low=np.minimum(low,rows['xyz'].min(axis=0));high=np.maximum(high,rows['xyz'].max(axis=0))
            color_max=max(color_max,int(rows['rgb'].max()))
            preview=np.concatenate((preview,rows));keys=np.concatenate((keys,rng.random(len(rows))))
            if len(preview)>preview_limit:
                keep=np.argpartition(keys,preview_limit-1)[:preview_limit];preview=preview[keep];keys=keys[keep]
        if progress: progress({'phase':'scan','read_points':read,'valid_points':valid})
    if not valid: raise ValueError('文件中没有有效三维点')
    if snapshot(source)!=before: raise ValueError('源文件读取期间发生变化，请重新导入')
    origin=np.floor(low);span=high-low
    if float(span.max())>1e7: raise ValueError('点云跨度超过10000公里，请先按区域拆分')
    divisions=min(32,max(1,int(np.ceil((valid/1024.)**(1./3.)))))
    tile_size=max(1.,float(span.max())/divisions)
    (out/'tiles').mkdir(parents=True);(out/'lod').mkdir()
    tiles={};written=second_invalid=0
    for rows,bad,_color,read in blocks(source,unit):
        rows['xyz']-=origin;second_invalid+=bad;written+=len(rows)
        if len(rows):
            grid=np.floor(rows['xyz']/tile_size).astype('i8')
            order=np.lexsort((grid[:,2],grid[:,1],grid[:,0]));grid=grid[order];rows=rows[order]
            cuts=np.r_[0,np.flatnonzero(np.any(grid[1:]!=grid[:-1],axis=1))+1,len(grid)]
            for a,b in zip(cuts[:-1],cuts[1:]):
                key='_'.join(str(int(v)) for v in grid[a]);part=rows[a:b]
                tile=tiles.setdefault(key,{'file':'tiles/'+key+'.bin','lod':'lod/'+key+'.bin','count':0,
                                          'min':np.full(3,np.inf),'max':np.full(3,-np.inf)})
                with (out/tile['file']).open('ab') as f: part.tofile(f)
                tile['count']+=len(part)
                tile['min']=np.minimum(tile['min'],part['xyz'].min(axis=0))
                tile['max']=np.maximum(tile['max'],part['xyz'].max(axis=0))
        if progress: progress({'phase':'index','read_points':read,'indexed_points':written})
    if snapshot(source)!=before or written!=valid or second_invalid!=invalid:
        raise ValueError('源文件在两次读取之间发生变化，索引未发布')
    manifest=[]
    for key in sorted(tiles):
        tile=tiles[key];n=tile['count']
        if (out/tile['file']).stat().st_size!=n*RECORD.itemsize: raise ValueError('分块写入不完整')
        mapped=np.memmap(out/tile['file'],dtype=RECORD,mode='r',shape=(n,))
        take=rng.choice(n,min(n,lod_limit),replace=False);mapped[take].tofile(out/tile['lod']);del mapped
        tile['lod_count']=len(take);tile['bounds']=[tile.pop('min').tolist(),tile.pop('max').tolist()]
        manifest.append(tile)
    preview=preview[np.argsort(preview['id'])];preview['xyz']-=origin
    preview['xyz'].astype('<f4').tofile(out/'xyz.f32')
    divisor=257 if color_max>255 else 1
    np.rint(preview['rgb']/divisor).astype('u1').tofile(out/'rgb.u8')
    meta={'schema':2,'source_name':source.name,'source_path':str(source.resolve()),'source_bytes':before[0],
          'source_mtime_ns':before[1],'unit':unit,'origin_m':origin.tolist(),'bounds_m':[low.tolist(),high.tolist()],
          'bounds_local_m':[(low-origin).tolist(),(high-origin).tolist()],
          'valid_points':valid,'invalid_points':invalid,'indexed_points':written,'display_points':len(preview),
          'has_color':has_color,'color_divisor':divisor,'tile_size_m':tile_size,'tiles':manifest,
          'xyz':'xyz.f32','rgb':'rgb.u8','record_bytes':RECORD.itemsize,
          'precision':'float64 local metres; uint16 RGB; original record ID; other source attributes remain in source',
          'sampling':'full_index_with_view_lod'}
    if sum(t['count'] for t in manifest)!=valid: raise ValueError('索引点数校验失败')
    atomic_json(out/'cloud.json',meta)
    return meta


class FullIndex:
    def __init__(self,root):
        self.root=Path(root).resolve()
        self.meta=json.loads((self.root/'cloud.json').read_text(encoding='utf-8'))
        if self.meta.get('schema')!=2 or self.meta.get('record_bytes')!=RECORD.itemsize:
            raise ValueError('需要全量索引版本2，请重新导入源文件')
        self.tiles=self.meta['tiles']
        if sum(t['count'] for t in self.tiles)!=self.meta['indexed_points']: raise ValueError('索引点数不匹配')
        for tile in self.tiles:
            for key,count in (('file',tile['count']),('lod',tile['lod_count'])):
                path=self.path(tile[key])
                if count<1 or path.stat().st_size!=count*RECORD.itemsize: raise ValueError('点云分块不完整')

    def path(self,name):
        path=(self.root/name).resolve()
        if not path.is_relative_to(self.root): raise ValueError('索引文件路径越界')
        return path

    def records(self,tile,lod=False):
        key='lod' if lod else 'file'
        with self.path(tile[key]).open('rb') as f:
            while True:
                rows=np.fromfile(f,dtype=RECORD,count=BLOCK)
                if not len(rows): break
                yield rows

    def all_records(self):
        for tile in self.tiles: yield from self.records(tile)
