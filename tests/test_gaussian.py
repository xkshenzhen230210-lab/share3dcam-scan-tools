"""Exercise the Gaussian cache and real D3D alpha/shape path."""
import ctypes as ct
import math
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np

from converter.gaussian import DC, MEAN, RECORD, ROT, SCALE, prepare_gaussian


DLL = Path(__file__).resolve().parents[1] / 'extension/share_pointcloud/bin/share_cloud_resident_097.dll'


class GaussianTests(unittest.TestCase):
    def test_ply_retains_anisotropy_and_transparent_depth_composition(self):
        api = ct.CDLL(str(DLL))
        api.pc_create.restype = ct.c_void_p
        api.pc_stats.restype = ct.c_char_p
        signatures = {
            'pc_add_gaussians': [ct.c_char_p, ct.c_uint64, ct.c_char_p, ct.c_uint32],
            'pc_load': [ct.c_uint32], 'pc_wait': [], 'pc_stats': [], 'pc_destroy': [],
            'pc_render_test': [ct.c_void_p, ct.c_uint32, ct.c_uint32],
            'pc_read_color': [ct.c_void_p, ct.c_uint32],
            'pc_set_gaussian_opacity': [ct.c_double],
        }
        for name, signature in signatures.items():
            getattr(api, name).argtypes = [ct.c_void_p, *signature]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / '半透明高斯.ply'
            fields = MEAN + DC + SCALE + ROT + ['opacity']
            header = 'ply\nformat binary_little_endian 1.0\nelement vertex 2\n'
            header += ''.join(f'property float {name}\n' for name in fields) + 'end_header\n'
            with source.open('wb') as stream:
                stream.write(header.encode())
                for z, color in [(1, (1, 0, 0)), (0, (0, 0, 1))]:
                    sh = [(channel - .5) / .2820947918 for channel in color]
                    stream.write(struct.pack('<14f', 0, 0, z, *sh, math.log(.5), math.log(.2), math.log(.2), 1, 0, 0, 0, 0))
            meta = prepare_gaussian(source, root)
            self.assertEqual(meta['indexed_points'], 2)
            splats = np.fromfile(root / 'gaussians.bin', dtype=RECORD)
            np.testing.assert_allclose(splats['covariance'][0], [.25,0,0,.04,0,.04], atol=1e-7)

            engine = api.pc_create()
            try:
                self.assertEqual(api.pc_add_gaussians(engine, str(root/'gaussians.bin').encode(), 2,
                                                     str(root/'harmonics.bin').encode(), 0), 0)
                self.assertEqual(api.pc_load(engine, 1), 0)
                self.assertEqual(api.pc_wait(engine), 0, api.pc_stats(engine))
                width, height = 640, 480
                pixels = (ct.c_uint32 * (width * height))()
                center = width * (height//2) + width//2
                camera = (ct.c_double * 10)(0,0,10, 0,0,0, 0,1,0, 8)
                self.assertEqual(api.pc_render_test(engine, camera, width, height), 0)
                self.assertEqual(api.pc_read_color(engine, pixels, len(pixels)), 0)
                self.assertAlmostEqual(pixels[center] >> 24, 124, delta=4)
                # Changing opacity must invalidate the cached frame even when
                # the camera is unchanged, and apply once after splat blending.
                self.assertEqual(api.pc_set_gaussian_opacity(engine, 1.0), 0)
                for eye, expected in [(10, (170,0,85,191)), (-10, (85,0,170,191))]:
                    camera = (ct.c_double * 10)(0,0,eye, 0,0,0, 0,1,0, 8)
                    self.assertEqual(api.pc_render_test(engine, camera, width, height), 0, api.pc_stats(engine))
                    self.assertEqual(api.pc_read_color(engine, pixels, len(pixels)), 0)
                    pixel = pixels[center].to_bytes(4, 'little')
                    self.assertTrue(all(abs(a-b)<5 for a,b in zip(pixel,expected)), tuple(pixel))
                    image = np.ctypeslib.as_array(pixels).reshape(height,width)
                    y, x = np.nonzero(image >> 24)
                    self.assertGreater(np.ptp(x), np.ptp(y) * 2)
            finally:
                api.pc_destroy(engine)

    def test_zoom_past_offscreen_splat_preserves_visible_model(self):
        class Vec(ct.Structure):
            _fields_ = [(axis, ct.c_double) for axis in ('x', 'y', 'z')]

        class Frame(ct.Structure):
            _fields_ = [
                ('version', ct.c_uint32), ('position', Vec), ('target', Vec), ('up', Vec),
                ('aspect', ct.c_double), ('near', ct.c_double), ('far', ct.c_double),
                ('projection', ct.c_double * 16), ('view', ct.c_double * 16),
                ('width', ct.c_double), ('height', ct.c_double), ('fov', ct.c_double),
                ('ortho_height', ct.c_double), ('perspective', ct.c_bool), ('reserved', ct.c_void_p),
            ]

        self.assertEqual(ct.sizeof(Frame), 408)
        api = ct.CDLL(str(DLL))
        api.pc_create.restype = ct.c_void_p
        api.pc_stats.restype = ct.c_char_p
        signatures = {
            'pc_add_gaussians': [ct.c_char_p, ct.c_uint64, ct.c_char_p, ct.c_uint32],
            'pc_load': [ct.c_uint32], 'pc_wait': [], 'pc_stats': [], 'pc_destroy': [],
            'pc_render_camera': [ct.POINTER(Frame)],
            'pc_read_color': [ct.c_void_p, ct.c_uint32],
            'pc_set_gaussian_opacity': [ct.c_double],
        }
        for name, signature in signatures.items():
            getattr(api, name).argtypes = [ct.c_void_p, *signature]

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'offscreen-gaussians.bin'
            splats = np.zeros(2, dtype=RECORD)
            splats['mean'] = [(0, 0, 0), (-20, -16, 9.95)]
            splats['covariance'] = [(1, 0, 0, 1, 0, 1), (.000001, 0, 0, .02, 0, .02)]
            splats['dc'] = [(.5 / .2820947918,) * 3, (-.5 / .2820947918,) * 3]
            splats['alpha'] = [1, .95]
            splats.tofile(path)
            engine = api.pc_create()
            try:
                self.assertEqual(api.pc_add_gaussians(engine, str(path).encode(), 2, b'', 0), 0)
                self.assertEqual(api.pc_load(engine, 1), 0)
                self.assertEqual(api.pc_wait(engine), 0, api.pc_stats(engine))
                self.assertEqual(api.pc_set_gaussian_opacity(engine, 1), 0)
                width, height = 320, 240
                pixels = np.zeros((height, width, 4), dtype=np.uint8)
                frame = Frame()
                frame.up = Vec(0, 1, 0)
                frame.near, frame.far = .01 / .0254, 100 / .0254
                frame.width, frame.height, frame.fov = width, height, 35
                frame.perspective = True
                # The black splat stays roughly 25 metres outside the view.
                # An unbounded projection derivative makes it cover the entire
                # viewport as the camera crosses its depth, hiding the model.
                for eye_z in (11, 10.5, 10.1, 10, 9.9):
                    with self.subTest(eye_z=eye_z):
                        frame.position = Vec(0, 0, eye_z / .0254)
                        self.assertEqual(api.pc_render_camera(engine, ct.byref(frame)), 0, api.pc_stats(engine))
                        self.assertEqual(api.pc_read_color(engine, pixels.ctypes.data, width * height), 0)
                        self.assertTrue(np.all(pixels[height // 2, width // 2] > 240),
                                        pixels[height // 2, width // 2].tolist())
                        self.assertEqual(int(pixels[0, 0, 3]), 0)
            finally:
                api.pc_destroy(engine)
