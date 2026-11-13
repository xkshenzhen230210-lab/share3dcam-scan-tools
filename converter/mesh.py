"""Prepare editable SketchUp mesh input while preserving geometry and diffuse UVs."""

from pathlib import Path

from converter.cloud import UNITS


def prepare_mesh(source, output, unit='m', up='z'):
    import collada
    import numpy as np
    import trimesh

    source, output = Path(source), Path(output)
    if source.suffix.lower() not in {'.obj', '.glb'}:
        raise ValueError('请选择 OBJ 或 GLB 网格。')
    if unit not in UNITS or up not in {'y', 'z'}:
        raise ValueError('网格单位或向上轴无效。')
    scene = trimesh.load_scene(source, process=False)
    document = collada.Collada()
    document.assetInfo.unitname = 'meter'
    document.assetInfo.unitmeter = 1.0
    document.assetInfo.upaxis = collada.asset.UP_AXIS.Z_UP
    nodes = []
    triangles = textures = 0

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
        name = f'mesh_{len(nodes)}'
        position = collada.source.FloatSource(name + '_pos', vertices.ravel(), ('X', 'Y', 'Z'))
        sources = [position]
        inputs = collada.source.InputList()
        inputs.addInput(0, 'VERTEX', '#' + position.id)
        diffuse = (0.75, 0.75, 0.75, 1.0)
        parameters = []
        bindings = []
        visual = mesh.visual
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
    document.write(str(output / 'mesh.dae'))
    return {'triangles': triangles, 'textures': textures}
