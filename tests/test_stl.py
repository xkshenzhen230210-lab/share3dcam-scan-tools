import tempfile
import unittest
from pathlib import Path

import collada
import numpy as np
import trimesh

from converter.mesh import prepare_mesh, write_stl


class StlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='赛尔 STL ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_import_ascii_and_binary_at_mm_scale(self):
        for kind in ('stl_ascii', 'stl'):
            with self.subTest(kind=kind):
                source = self.root / '导入样本.STL'
                payload = trimesh.creation.box(extents=[1000, 200, 300]).export(file_type=kind)
                source.write_bytes(payload.encode() if isinstance(payload, str) else payload)
                self.assertEqual(prepare_mesh(source, self.root, 'mm'), {'triangles': 12, 'textures': 0})
                geometry = collada.Collada(str(self.root / 'mesh.dae')).geometries[0]
                np.testing.assert_allclose(np.ptp(geometry.primitives[0].vertex, axis=0), [1, .2, .3])

    def test_obj_to_binary_stl_axis_and_units(self):
        source = self.root / '输入.obj'
        source.write_text('v 0 0 0\nv 100 0 0\nv 0 200 300\nf 1 2 3\n', encoding='ascii')
        target = self.root / '输出.stl'
        self.assertEqual(write_stl(source, target, 'cm', 'y', 'mm'), {'triangles': 1})
        self.assertEqual(target.stat().st_size, 134)
        np.testing.assert_allclose(trimesh.load_mesh(target).bounds, [[0, -3000, 0], [1000, 0, 2000]])

    def test_glb_export_preserves_instances_and_uses_meters(self):
        source = self.root / '输入.glb'
        scene = trimesh.Scene()
        for x in (0, 3):
            scene.add_geometry(trimesh.creation.box(), transform=trimesh.transformations.translation_matrix([x, 0, 0]))
        scene.export(source)
        target = self.root / '输出.stl'
        self.assertEqual(write_stl(source, target, 'cm', 'z', 'mm'), {'triangles': 24})
        np.testing.assert_allclose(trimesh.load_mesh(target).bounds, [[-500]*3, [3500, 500, 500]])

    def test_invalid_source_does_not_replace_existing_output(self):
        source = self.root / '输入.obj'
        source.write_text('v 0 0 0\n', encoding='ascii')
        target = self.root / '输出.stl'
        target.write_bytes(b'previous')
        with self.assertRaises(ValueError):
            write_stl(source, target, 'm', 'z', 'mm')
        self.assertEqual(target.read_bytes(), b'previous')
