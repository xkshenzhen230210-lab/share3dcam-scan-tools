"""Read standard 3DGS PLY into a local-metre render cache, preserving splats."""
from pathlib import Path
import os

import numpy as np

from converter.cloud import BLOCK, TYPES, UNITS
from converter.full_index import atomic_json, snapshot


MEAN = ['x', 'y', 'z']
DC = [f'f_dc_{i}' for i in range(3)]
SCALE = [f'scale_{i}' for i in range(3)]
ROT = [f'rot_{i}' for i in range(4)]
RECORD = np.dtype([('mean', '<f8', 3), ('covariance', '<f4', 6), ('dc', '<f4', 3), ('alpha', '<f4')])
MAX_SPLATS = 20_000_000


def read_layout(stream):
    if stream.readline(65536).strip() != b'ply':
        raise ValueError('请选择有效的高斯 PLY 文件。')
    count = 0
    layout = []
    first_element = None
    element = None
    encoding = None
    for _ in range(1024):
        line = stream.readline(65536)
        if not line or len(line) == 65536:
            raise ValueError('PLY 文件头不完整或过长。')
        words = line.decode('ascii', errors='replace').split()
        if not words:
            continue
        if words[0] == 'format' and len(words) == 3:
            encoding = words[1]
        elif words[0] == 'element' and len(words) == 3:
            element = words[1]
            first_element = first_element or element
            if element == 'vertex':
                count = int(words[2])
        elif words[0] == 'property' and element == 'vertex':
            if len(words) != 3 or words[1] not in TYPES:
                raise ValueError('高斯顶点含不支持的属性类型。')
            layout.append((words[2], TYPES[words[1]]))
        elif words[0] == 'end_header':
            break
    else:
        raise ValueError('PLY 文件头过长。')
    if first_element != 'vertex' or encoding not in {'binary_little_endian', 'binary_big_endian', 'ascii'}:
        raise ValueError('请选择标准 3DGS PLY。压缩高斯可尝试独立查看器。')
    if not 0 < count <= MAX_SPLATS:
        raise ValueError('主视窗高斯数量须为 1 至 2000 万。')
    names = {name for name, _ in layout}
    if not set(MEAN + DC + SCALE + ROT + ['opacity']).issubset(names):
        raise ValueError('缺少标准高斯颜色、尺度、旋转或透明度属性。压缩高斯可尝试独立查看器。')
    rest = [name for name in names if name.startswith('f_rest_')]
    if len(rest) not in {0, 9, 24, 45} or set(rest) != {f'f_rest_{i}' for i in range(len(rest))}:
        raise ValueError('高斯球谐系数不完整或阶数超出 3 阶。')
    prefix = '>' if encoding == 'binary_big_endian' else '<'
    return count, np.dtype([(name, prefix + kind) for name, kind in layout]), encoding, len(rest)


def read_blocks(stream, count, dtype, encoding):
    for start in range(0, count, BLOCK):
        n = min(BLOCK, count - start)
        if encoding == 'ascii':
            rows = [stream.readline() for _ in range(n)]
            if not all(rows):
                raise ValueError('高斯 PLY 数据截断。')
            values = np.loadtxt(rows, dtype=dtype, ndmin=1)
            if len(values) != n:
                raise ValueError('高斯 PLY 行数不匹配。')
        else:
            raw = stream.read(n * dtype.itemsize)
            if len(raw) != n * dtype.itemsize:
                raise ValueError('高斯 PLY 数据截断。')
            values = np.frombuffer(raw, dtype=dtype)
        yield values


def columns(rows, names):
    return np.column_stack([rows[name] for name in names]).astype('f8')


def covariance(rows, metres):
    # PLY stores log scale and quaternion in w,x,y,z order.
    scale = np.exp(columns(rows, SCALE)) * metres
    quaternion = columns(rows, ROT)
    length = np.linalg.norm(quaternion, axis=1)
    if np.any(length <= 1e-12) or not np.isfinite(scale).all():
        raise ValueError('高斯尺度或旋转无效。')
    w, x, y, z = (quaternion / length[:, None]).T
    rotation = np.stack((
        1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w),
        2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w),
        2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y),
    ), axis=1).reshape(-1, 3, 3)
    basis = rotation * scale[:, None, :]
    matrix = basis @ basis.transpose(0, 2, 1)
    return matrix[:, [0, 0, 0, 1, 1, 2], [0, 1, 2, 1, 2, 2]]


def prepare_gaussian(source, output, unit='m', progress=None):
    source, output = Path(source), Path(output)
    metres = UNITS[unit]
    original = snapshot(source)
    with source.open('rb') as stream:
        count, dtype, encoding, rest = read_layout(stream)
        start = stream.tell()
        low, high = np.full(3, np.inf), np.full(3, -np.inf)
        for rows in read_blocks(stream, count, dtype, encoding):
            xyz = columns(rows, MEAN) * metres
            if not np.isfinite(xyz).all():
                raise ValueError('高斯坐标包含无效数字。')
            low, high = np.minimum(low, xyz.min(axis=0)), np.maximum(high, xyz.max(axis=0))
        origin = np.floor(low)
        if np.max(high - origin) > 1e7:
            raise ValueError('高斯坐标跨度过大，请先按区域裁剪。')

        stream.seek(start)
        done = 0
        with (output/'gaussians.bin.tmp').open('wb') as geometry, (output/'harmonics.bin.tmp').open('wb') as harmonics:
            for rows in read_blocks(stream, count, dtype, encoding):
                splats = np.empty(len(rows), dtype=RECORD)
                splats['mean'] = columns(rows, MEAN) * metres - origin
                splats['covariance'] = covariance(rows, metres)
                splats['dc'] = columns(rows, DC)
                opacity = np.asarray(rows['opacity'], dtype='f8')
                if not np.isfinite(opacity).all() or any(not np.isfinite(splats[name]).all() for name in ('covariance', 'dc')):
                    raise ValueError('高斯颜色、尺度或透明度包含无效数字。')
                splats['alpha'] = 1 / (1 + np.exp(-np.clip(opacity, -80, 80)))
                splats.tofile(geometry)
                if rest:
                    sh = columns(rows, [f'f_rest_{i}' for i in range(rest)]).astype('<f2')
                    if not np.isfinite(sh).all():
                        raise ValueError('高斯球谐颜色包含无效数字。')
                    sh.tofile(harmonics)
                done += len(rows)
                if progress:
                    progress({'phase':'gaussian', 'read_points':done, 'total_points':count})
    if snapshot(source) != original:
        raise ValueError('读取时源文件发生变化，请重新导入。')
    os.replace(output/'gaussians.bin.tmp', output/'gaussians.bin')
    os.replace(output/'harmonics.bin.tmp', output/'harmonics.bin')
    metadata = {'schema':3, 'kind':'gaussian', 'source_name':source.name,
                'source_path':str(source.resolve()), 'source_bytes':original[0], 'source_mtime_ns':original[1],
                'valid_points':count, 'indexed_points':count, 'display_points':count, 'has_color':True,
                'origin_m':origin.tolist(), 'bounds_local_m':[(low-origin).tolist(), (high-origin).tolist()],
                'record_bytes':RECORD.itemsize, 'sh_coefficients':rest}
    atomic_json(output/'cloud.json', metadata)
    return metadata
