"""Read source data without modifying it; publish a bounded display cache."""
import json
import math
import os
from pathlib import Path
import numpy as np

BLOCK=100_000
UNITS={'m':1.0,'mm':.001,'cm':.01,'ft':.3048}
TYPES={'char':'i1','int8':'i1','uchar':'u1','uint8':'u1','short':'i2','int16':'i2',
       'ushort':'u2','uint16':'u2','int':'i4','int32':'i4','uint':'u4','uint32':'u4',
       'float':'f4','float32':'f4','double':'f8','float64':'f8'}

def ply_chunks(path):
    with path.open('rb') as f:
        if f.readline().strip()!=b'ply':raise ValueError('不是有效的PLY文件')
        fmt=None;count=None;props=[];element=None;before=[]
        for _ in range(20000):
            line=f.readline()
            if not line:raise ValueError('PLY文件头不完整')
            words=line.decode('ascii').strip().split()
            if not words:continue
            if words[0]=='format':fmt=words[1]
            elif words[0]=='element':
                element=words[1]
                if element=='vertex':count=int(words[2])
                elif count is None and int(words[2]):before.append(element)
            elif words[0]=='property' and element=='vertex':
                if words[1]=='list':raise ValueError('暂不支持带列表属性的PLY顶点，请先转标准XYZ/RGB点云')
                if words[1] not in TYPES:raise ValueError('PLY属性类型不支持：'+words[1])
                props.append((words[2],TYPES[words[1]]))
            elif words[0]=='end_header':break
        else:raise ValueError('PLY文件头过长')
        names=[p[0] for p in props]
        if before or count is None or count<1 or len(set(names))!=len(names):raise ValueError('PLY顶点布局不支持或为空')
        if not all(n in names for n in ['x','y','z']):raise ValueError('PLY缺少x/y/z坐标')
        rgb_names=next((n for n in [('red','green','blue'),('r','g','b')] if all(c in names for c in n)),None)
        if fmt not in ['ascii','binary_little_endian','binary_big_endian']:raise ValueError('未知PLY编码')
        endian='<' if fmt=='binary_little_endian' else '>'
        dtype=np.dtype([(n,endian+t) for n,t in props])
        for offset in range(0,count,BLOCK):
            n=min(BLOCK,count-offset)
            if fmt=='ascii':
                lines=[f.readline() for _ in range(n)]
                if any(not l for l in lines):raise ValueError('PLY顶点数据截断')
                try:
                    values=np.loadtxt(lines,dtype='f8',ndmin=2)
                    if values.shape!=(n,len(props)):raise ValueError()
                    xyz=values[:,[names.index(c) for c in ['x','y','z']]]
                    rgb=values[:,[names.index(c) for c in rgb_names]] if rgb_names else None
                except Exception as e:raise ValueError('PLY顶点行或属性数不正确') from e
            else:
                raw=f.read(n*dtype.itemsize)
                if len(raw)!=n*dtype.itemsize:raise ValueError('PLY二进制顶点数据截断')
                values=np.frombuffer(raw,dtype=dtype)
                xyz=np.column_stack([values[c] for c in ['x','y','z']]).astype('f8')
                rgb=np.column_stack([values[c] for c in rgb_names]) if rgb_names else None
            yield xyz,rgb

def text_chunks(path):
    rows=[];columns=None;declared=None;seen=0
    def unpack(block):
        a=np.asarray(block,dtype='f8')
        return a[:,:3], a[:,3:6] if columns==6 else a[:,4:7] if columns==7 else None
    with path.open('r',encoding='utf-8-sig') as f:
        for number,line in enumerate(f,1):
            line=line.strip()
            if not line or line.startswith(('#','//')):continue
            parts=line.replace(',',' ').replace(';',' ').split()
            if seen==0 and declared is None and len(parts)==1:
                try:declared=int(parts[0]);continue
                except ValueError:pass
            if len(parts) not in [3,4,6,7]:raise ValueError(f'第{number}行列数不明确；需XYZ、XYZ强度、XYZRGB或XYZ强度RGB')
            if columns is None:columns=len(parts)
            if columns!=len(parts):raise ValueError(f'第{number}行列数与前文不同')
            try:rows.append([float(p) for p in parts])
            except ValueError as e:raise ValueError(f'第{number}行不是数字坐标') from e
            seen+=1
            if len(rows)>=BLOCK:yield unpack(rows);rows=[]
        if rows:yield unpack(rows)
    if declared is not None and seen!=declared:raise ValueError('PTS声明点数与实际行数不同')

def las_chunks(path):
    import laspy
    with laspy.open(path) as reader:
        color=all(n in reader.header.point_format.dimension_names for n in ['red','green','blue'])
        read_count=0
        for block in reader.chunk_iterator(BLOCK):
            read_count+=len(block)
            xyz=np.column_stack([block.x,block.y,block.z])
            rgb=np.column_stack([block.red,block.green,block.blue]) if color else None
            yield xyz,rgb
        if read_count!=reader.header.point_count:raise ValueError('LAS/LAZ文件点记录截断，未生成不完整缓存')

def convert(source,out,limit=100_000,unit='m',progress=None):
    source=Path(source);out=Path(out)
    if unit not in UNITS:raise ValueError('请选择米、毫米、厘米或英尺')
    if not 1<=limit<=100_000:raise ValueError('显示点数上限须在1到100000之间')
    suffix=source.suffix.lower()
    reader=las_chunks if suffix in ['.las','.laz'] else ply_chunks if suffix=='.ply' else text_chunks if suffix in ['.xyz','.txt','.pts'] else None
    if reader is None:raise ValueError('暂不支持该格式；首版支持LAS/LAZ/PLY/XYZ/TXT/PTS，其他格式请先转换')
    rng=np.random.default_rng(83471)
    points=np.empty((0,3));colors=np.empty((0,3));keys=np.empty(0);ids=np.empty(0,dtype='i8')
    valid=invalid=0;low=np.full(3,np.inf);high=-low;has_color=False;source_color_max=0
    for xyz,rgb in reader(source):
        mask=np.isfinite(xyz).all(axis=1);invalid+=int((~mask).sum())
        xyz=np.asarray(xyz[mask],dtype='f8')*UNITS[unit]
        if not len(xyz):continue
        if not np.isfinite(xyz).all():raise ValueError('单位换算后坐标溢出')
        low=np.minimum(low,xyz.min(axis=0));high=np.maximum(high,xyz.max(axis=0))
        if rgb is None:rgb=np.full(xyz.shape,190.0)
        else:
            rgb=np.nan_to_num(np.asarray(rgb[mask],dtype='f8'),nan=190,posinf=255,neginf=0);has_color=True
            source_color_max=max(source_color_max,float(rgb.max()))
        newids=np.arange(valid,valid+len(xyz),dtype='i8');valid+=len(xyz)
        points=np.concatenate([points,xyz]);colors=np.concatenate([colors,rgb]);keys=np.concatenate([keys,rng.random(len(xyz))]);ids=np.concatenate([ids,newids])
        if len(points)>limit:
            keep=np.argpartition(keys,limit-1)[:limit]
            points=points[keep];colors=colors[keep];keys=keys[keep];ids=ids[keep]
        if progress:progress(valid+invalid)
    if not valid:raise ValueError('文件中没有有效的三维点')
    order=np.argsort(ids);points=points[order];colors=colors[order]
    origin=np.floor(low)
    if np.max(np.abs(points-origin))>1e7:raise ValueError('点云跨度过大，请先按区域裁剪；源文件未修改')
    if source_color_max>255:colors=colors/257.0
    rgb=np.rint(np.clip(colors,0,255)).astype('u1')
    out.mkdir(parents=True,exist_ok=True)
    local=(points-origin).astype('<f4')
    meta={'schema':1,'source_name':source.name,'source_path':str(source.resolve()),'source_bytes':source.stat().st_size,
          'source_mtime_ns':source.stat().st_mtime_ns,'unit':unit,'origin_m':origin.tolist(),
          'bounds_m':[low.tolist(),high.tolist()],'bounds_local_m':[(low-origin).tolist(),(high-origin).tolist()],
          'valid_points':valid,'invalid_points':invalid,'display_points':len(points),'has_color':has_color,
          'sampling':'deterministic_uniform_sample','precision':'float32 local metres; source preserved',
          'xyz':'xyz.f32','rgb':'rgb.u8'}
    local.tofile(out/'xyz.f32.tmp');rgb.tofile(out/'rgb.u8.tmp')
    os.replace(out/'xyz.f32.tmp',out/'xyz.f32');os.replace(out/'rgb.u8.tmp',out/'rgb.u8')
    (out/'cloud.json.tmp').write_text(json.dumps(meta,ensure_ascii=False,allow_nan=False),encoding='utf-8')
    os.replace(out/'cloud.json.tmp',out/'cloud.json')
    return meta
