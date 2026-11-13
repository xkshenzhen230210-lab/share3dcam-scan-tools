import tempfile
from pathlib import Path
import unittest
import numpy as np
from converter.full_index import FullIndex,build_index
from converter.queries import CloudQuery

class VisibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def test_more_than_100000_individually_visible_points_are_not_truncated(self):
        x,y=np.meshgrid(np.arange(500)*.01,np.arange(500)*.01)
        a=np.column_stack((x.ravel(),y.ravel(),np.zeros(x.size)))
        source=self.root/'超过十万.xyz';np.savetxt(source,a,fmt='%.8f')
        out=self.root/'index';build_index(source,out,preview_limit=1,lod_limit=1)
        query=CloudQuery(FullIndex(out))
        camera={'eye':[2.495,2.495,10],'right':[1,0,0],'up':[0,1,0],'forward':[0,0,-1],
                'cx':249.5,'cy':249.5,'fx':100,'fy':100,'width':500,'height':500,'perspective':False}
        rows,info=query.full_view(camera,{})
        self.assertEqual(len(rows),250000)
        self.assertEqual(info['scanned_points'],250000)
        self.assertEqual(info['in_view_points'],250000)
        self.assertEqual(info['lod_tiles'],0)
        np.testing.assert_array_equal(np.sort(rows['id']),np.arange(250000))
    def test_nearest_depth_wins_with_exact_id_tie_break_and_roi(self):
        source=self.root/'occlusion.xyz'
        source.write_text('0 0 0 255 0 0\n0 0 1 0 255 0\n0 0 1 0 0 255\n1 0 0 0 0 0\n')
        out=self.root/'index';build_index(source,out,preview_limit=1,lod_limit=1)
        query=CloudQuery(FullIndex(out))
        cam={'eye':[0,0,10],'right':[1,0,0],'up':[0,1,0],'forward':[0,0,-1],
             'cx':50,'cy':50,'fx':10,'fy':10,'width':100,'height':100,'perspective':False}
        rows,info=query.full_view(cam,{})
        self.assertEqual(sorted(rows['id'].tolist()),[1,3]);self.assertEqual(info['in_view_points'],4)
        self.assertEqual(rows[rows['id']==1]['rgb'].tolist(),[[0,255,0]])
        rows,info=query.full_view(cam,{'slice':True,'slice_z':0,'slice_width':.01})
        self.assertEqual(sorted(rows['id'].tolist()),[0,3])
    def test_offscreen_and_behind_camera_points_are_culled_without_sampling(self):
        source=self.root/'frustum.xyz';source.write_text('0 0 0\n100 0 0\n0 0 11\n')
        out=self.root/'index';build_index(source,out)
        cam={'eye':[0,0,10],'right':[1,0,0],'up':[0,1,0],'forward':[0,0,-1],
             'cx':50,'cy':50,'fx':100,'fy':100,'width':100,'height':100,'perspective':True}
        rows,info=CloudQuery(FullIndex(out)).full_view(cam,{})
        self.assertEqual(rows['id'].tolist(),[0]);self.assertEqual(info['in_view_points'],1)

if __name__=='__main__':unittest.main()
