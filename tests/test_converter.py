import json
import struct
import tempfile
import unittest
from pathlib import Path
import numpy as np
import laspy
from unittest.mock import patch
from converter.cloud import convert

class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def run_cloud(self,source,**kwargs):
        out=self.root/'缓存';convert(source,out,limit=kwargs.pop('limit',100),**kwargs)
        return json.loads((out/'cloud.json').read_text('utf-8')),np.fromfile(out/'xyz.f32','<f4').reshape(-1,3),np.fromfile(out/'rgb.u8','u1').reshape(-1,3)
    def test_ascii_ply_colors_and_large_coordinates(self):
        p=self.root/'中文 sample.ply'
        p.write_text('ply\nformat ascii 1.0\nelement vertex 2\nproperty double x\nproperty double y\nproperty double z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n600000 3000000 10 255 0 0\n600001.125 3000002.25 13 0 255 10\n')
        m,points,rgb=self.run_cloud(p)
        np.testing.assert_allclose(points+m['origin_m'],[[600000,3000000,10],[600001.125,3000002.25,13]],atol=1e-6)
        self.assertEqual(rgb.tolist(),[[255,0,0],[0,255,10]])
    def test_binary_ply_endian_extra_fields(self):
        for endian,name in [('<','binary_little_endian'),('>','binary_big_endian')]:
            p=self.root/f'{name}.ply'
            header=f'ply\nformat {name} 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 0\nproperty list uchar int vertex_indices\nend_header\n'
            p.write_bytes(header.encode()+struct.pack(endian+'ffffBBBffffBBB',1,2,3,0,10,20,30,4,5,6,1,40,50,60))
            m,points,rgb=self.run_cloud(p)
            np.testing.assert_allclose(points+m['origin_m'],[[1,2,3],[4,5,6]])
            self.assertEqual(rgb.tolist(),[[10,20,30],[40,50,60]])
    def test_las_laz(self):
        for ext in ['las','laz']:
            p=self.root/f'大坐标.{ext}';h=laspy.LasHeader(point_format=3,version='1.2')
            h.offsets=np.array([600000,3000000,0]);h.scales=np.array([.001]*3)
            c=laspy.LasData(h);c.x=np.array([600000,600001.125]);c.y=np.array([3000000,3000002.25]);c.z=np.array([10,13])
            c.red=[65535,0];c.green=[0,65535];c.blue=[257,0];c.write(p)
            m,points,rgb=self.run_cloud(p)
            np.testing.assert_allclose(points+m['origin_m'],[[600000,3000000,10],[600001.125,3000002.25,13]],atol=1e-6)
            self.assertEqual(rgb.tolist(),[[255,0,1],[0,255,0]])
    def test_text_units_and_invalid_filtered(self):
        p=self.root/'sample.xyz';p.write_text('# comment\n1000 2000 3000 10 20 30\nnan 1 2 0 0 0\n2000 4000 6000 40 50 60\n')
        m,points,_=self.run_cloud(p,unit='mm');self.assertEqual(m['valid_points'],2);self.assertEqual(m['invalid_points'],1)
        np.testing.assert_allclose(points+m['origin_m'],[[1,2,3],[2,4,6]])
    def test_sampling_bounded_and_deterministic(self):
        p=self.root/'many.xyz';p.write_text(''.join(f'{i} 0 0\n' for i in range(10000)))
        with patch('converter.cloud.BLOCK',257):m,a,_=self.run_cloud(p,limit=37)
        self.assertEqual(m['display_points'],37);self.assertEqual(m['valid_points'],10000)
        self.assertEqual(m['bounds_m'][1][0],9999)
        _,b,_=self.run_cloud(p,limit=37);np.testing.assert_array_equal(a,b)
    def test_display_limit_is_bounded_at_100000(self):
        p=self.root/'cap.xyz';p.write_text('1 2 3\n')
        m,_,_=self.run_cloud(p,limit=100000)
        self.assertEqual(m['display_points'],1)
        for limit in [0,100001]:
            with self.subTest(limit=limit),self.assertRaises(ValueError):
                self.run_cloud(p,limit=limit)
    def test_pts_count_and_intensity_rgb(self):
        p=self.root/'有空格 样本.pts';p.write_text('2\n1 2 3 700 255 10 20\n4 5 6 800 10 255 30\n')
        m,_,rgb=self.run_cloud(p);self.assertEqual(m['valid_points'],2)
        self.assertEqual(rgb.tolist(),[[255,10,20],[10,255,30]])
        p.write_text('3\n1 2 3\n')
        with self.assertRaises(ValueError):self.run_cloud(p)
    def test_zero_las_and_no_rgb(self):
        p=self.root/'无颜色.las';h=laspy.LasHeader(point_format=0,version='1.2');c=laspy.LasData(h)
        c.write(p)
        with self.assertRaises(ValueError):self.run_cloud(p)
        c.x=np.array([0,1]);c.y=np.array([2,3]);c.z=np.array([4,5]);c.write(p)
        m,_,rgb=self.run_cloud(p);self.assertFalse(m['has_color']);self.assertEqual(rgb[0].tolist(),[190]*3)
    def test_truncated_ply_rejected(self):
        p=self.root/'broken.ply';p.write_text('ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n')
        with self.assertRaises(ValueError):self.run_cloud(p)
    def test_unsupported_and_ambiguous_text_rejected(self):
        p=self.root/'unknown.rwp';p.write_bytes(b'not a point cloud')
        with self.assertRaises(ValueError):self.run_cloud(p)
        p=self.root/'bad.txt';p.write_text('1 2 3 4 5\n')
        with self.assertRaises(ValueError):self.run_cloud(p)

if __name__=='__main__':unittest.main()
