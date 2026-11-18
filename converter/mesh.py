"""Prepare editable SketchUp mesh input while preserving geometry and diffuse UVs."""

import os
import struct
import tempfile
from pathlib import Path

from converter.cloud import UNITS


def mesh_instances(source, unit, up):
    import numpy as np
    import trimesh

    source = Path(source)
    if source.suffix.lower() not in {'.obj', '.glb', '.stl'}:
        raise ValueError('请选择 GLB、OBJ 或 STL 网格。')
    if unit not in UNITS or up not in {'y', 'z'}:
        raise ValueError('网格单位或向上轴无效。')
    scene = trimesh.load_scene(source, process=False)

    is_glb = source.suffix.lower() == '.glb'
    scale = 1.0 if is_glb else UNITS[unit]
    for instance in scene.graph.nodes_geometry:
        transform, key = scene.graph[instance]
        mesh = scene.geometry[key]
        if not isinstance(mesh, trimesh.Trimesh) or not len(mesh.faces):
            raise ValueError('网格含不支持的非三角面图元，无法完整转换。')

        vertices = trimesh.transform_points(mesh.vertices, transform) * scale
        if is_glb or up == 'y':
            vertices = vertices[:, [0, 2, 1]].copy()
            vertices[:, 1] *= -1
        if not np.isfinite(vertices).all():
            raise ValueError('网格包含非有限坐标。')

        faces = mesh.faces if np.linalg.det(transform[:3, :3]) >= 0 else mesh.faces[:, ::-1]
        yield vertices, faces, mesh.visual


def write_stl(source, target, unit='m', up='z', output_unit='mm'):
    import numpy as np

    source, target = Path(source), Path(target)
    if target.suffix.lower() != '.stl' or output_unit not in UNITS:
        raise ValueError('STL 输出文件或单位无效。')
    if source.resolve() == target.resolve() or (target.exists() and source.samefile(target)):
        raise ValueError('不能覆盖源网格文件。')

    record = np.dtype([('normal', '<f4', (3,)), ('vertices', '<f4', (3, 3)), ('attribute', '<u2')])
    temporary = None
    total = 0
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.share3dcam-stl-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(b'SHARE3DCAM'.ljust(84, b'\0'))
            for vertices, faces, _visual in mesh_instances(source, unit, up):
                total += len(faces)
                if total > 0xFFFFFFFF:
                    raise ValueError('三角面数量超过二进制 STL 上限。')
                for start in range(0, len(faces), 65536):
                    triangles = vertices[faces[start:start + 65536]] / UNITS[output_unit]
                    if np.abs(triangles).max() > np.finfo(np.float32).max:
                        raise ValueError('坐标超过 STL 可表示范围。')
                    block = np.zeros(len(triangles), dtype=record)
                    block['vertices'] = triangles
                    points = block['vertices'].astype(np.float64)
                    normals = np.cross(points[:, 1] - points[:, 0], points[:, 2] - points[:, 0])
                    lengths = np.linalg.norm(normals, axis=1)
                    valid = lengths > 0
                    block['normal'][valid] = normals[valid] / lengths[valid, None]
                    stream.write(block.tobytes())
            if not total:
                raise ValueError('文件里没有可导出的网格面。')
            stream.seek(80)
            stream.write(struct.pack('<I', total))
        os.replace(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {'triangles': total}


def prepare_mesh(source, output, unit='m', up='z'):
    import collada
    import numpy as np
    import trimesh

    output = Path(output)
    document = collada.Collada()
    document.assetInfo.unitname = 'meter'
    document.assetInfo.unitmeter = 1.0
    document.assetInfo.upaxis = collada.asset.UP_AXIS.Z_UP
    nodes = []
    triangles = textures = 0
    for vertices, faces, visual in mesh_instances(source, unit, up):
        name = f'mesh_{len(nodes)}'
        position = collada.source.FloatSource(name + '_pos', vertices.ravel(), ('X', 'Y', 'Z'))
        sources = [position]
        inputs = collada.source.InputList()
        inputs.addInput(0, 'VERTEX', '#' + position.id)
        diffuse = (0.75, 0.75, 0.75, 1.0)
        parameters = []
        bindings = []
        if visual.kind == 'texture':
            material = visual.material
            if isinstance(material, trimesh.visual.material.PBRMaterial):
                material = material.to_simple()
            if not isinstance(material, trimesh.visual.material.SimpleMaterial):
                raise ValueError('网格包含无法转换的材质分配。')
            diffuse = tuple(float(c) / 255 for c in material.diffuse)
            if material.image is not None:
                uv = np.asarray(visual.uv)
                if uv.shape != (len(vertices), 2) or not np.isfinite(uv).all():
                    raise ValueError('贴图对应的 UV 坐标不完整。')
                uv_source = collada.source.FloatSource(name + '_uv', uv.ravel(), ('S', 'T'))
                sources.append(uv_source)
                inputs.addInput(0, 'TEXCOORD', '#' + uv_source.id, '0')
                image_name = name + '.png'
                material.image.save(output / image_name, format='PNG')
                image = collada.material.CImage(name + '_image', image_name)
                document.images.append(image)
                surface = collada.material.Surface(name + '_surface', image)
                sampler = collada.material.Sampler2D(name + '_sampler', surface)
                parameters = [surface, sampler]
                diffuse = collada.material.Map(sampler, 'UVSET0')
                bindings = [('UVSET0', 'TEXCOORD', '0')]
                textures += 1
        elif visual.kind == 'vertex':
            colors = collada.source.FloatSource(name + '_rgb',
                (visual.vertex_colors[:, :3] / 255.0).ravel(), ('R', 'G', 'B'))
            sources.append(colors)
            inputs.addInput(0, 'COLOR', '#' + colors.id)

        effect = collada.material.Effect(name + '_effect', parameters, 'lambert', diffuse=diffuse)
        material = collada.material.Material(name + '_material', name, effect)
        document.effects.append(effect)
        document.materials.append(material)
        geometry = collada.geometry.Geometry(document, name, name, sources)
        geometry.primitives.append(geometry.createTriangleSet(faces.ravel(), inputs, name))
        document.geometries.append(geometry)
        binding = collada.scene.MaterialNode(name, material, bindings)
        nodes.append(collada.scene.Node(name + '_node', children=[collada.scene.GeometryNode(geometry, [binding])]))
        triangles += len(faces)

    if not triangles:
        raise ValueError('文件里没有可导入的网格面。')
    document.scene = collada.scene.Scene('scene', nodes)
    document.scenes.append(document.scene)
    with (output / 'mesh.dae').open('wb') as stream:
        document.write(stream)
    return {'triangles': triangles, 'textures': textures}
