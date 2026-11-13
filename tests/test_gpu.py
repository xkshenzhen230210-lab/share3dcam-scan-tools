import tempfile
from pathlib import Path
import unittest
import numpy as np
from converter.full_index import build_index,FullIndex
from converter.queries import CloudQuery
from converter.gpu_visibility import GpuVisibility

CAM={'eye':[0,0,10],'right':[1,0,0],'up':[0,1,0],'forward':[0,0,-1],
     'cx':100,'cy':100,'fx':20,'fy':20,'width':200,'height':200,'perspective':False}

class GpuTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.gpu=None
    def tearDown(self):
        if self.gpu:self.gpu.close()
        self.tmp.cleanup()
    def make(self,xyz):
        path=self.root/'points.xyz';np.savetxt(path,xyz,fmt='%.17g')
        build_index(path,self.root/'index',preview_limit=1,lod_limit=1)
        index=FullIndex(self.root/'index');self.gpu=GpuVisibility(index)
        return CloudQuery(index)
    def test_gpu_device_and_nearest_depth_match_cpu_including_duplicates(self):
        ref=self.make(np.array([[0,0,0],[0,0,1],[0,0,1],[1,0,0],[-1,0,0]],dtype='f8'))
        rows,info=self.gpu.full_view(CAM,{})
        expected,stats=ref.full_view(CAM,{})
        np.testing.assert_array_equal(np.sort(rows['id']),np.sort(expected['id']))
        self.assertEqual(info['engine'],'opencl_gpu');self.assertTrue(info['gpu_device'])
        self.assertEqual(info['in_view_points'],stats['in_view_points'])
        self.assertEqual(info['lod_tiles'],0);self.assertIsNone(info['point_budget'])
    def test_gpu_rotation_clip_slice_and_perspective_match_cpu(self):
        xyz=np.random.default_rng(6).uniform(-2,2,(20000,3));ref=self.make(xyz)
        for perspective in (False,True):
            camera=dict(CAM,perspective=perspective,render_width=250,render_height=250)
            options={'angle':17,'x':.23,'y':-.13,'z':.4,'clip':[0,0,0,4,4,4],
                     'slice':True,'slice_z':2,'slice_width':.75}
            rows,info=self.gpu.full_view(camera,options);expected,stats=ref.full_view(camera,options)
            self.assertEqual(info['in_view_points'],stats['in_view_points'])
            np.testing.assert_array_equal(np.sort(rows['id']),np.sort(expected['id']))
            # Second query uses the same resident source buffers.
            self.assertEqual(info['upload_count'],1)
    def test_gpu_does_not_apply_100000_cap(self):
        x,y=np.meshgrid(np.arange(400)*.01,np.arange(400)*.01)
        ref=self.make(np.column_stack((x.ravel(),y.ravel(),np.full(x.size,.5))))
        cam=dict(CAM,eye=[1.995,1.995,10],cx=199.5,cy=199.5,fx=100,fy=100,width=400,height=400)
        rows,info=self.gpu.full_view(cam,{})
        self.assertEqual(len(rows),160000);self.assertEqual(info['scanned_points'],160000)

if __name__=='__main__':unittest.main()
