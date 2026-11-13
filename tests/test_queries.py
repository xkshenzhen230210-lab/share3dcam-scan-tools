import tempfile
import unittest
from pathlib import Path
import numpy as np
from converter.full_index import build_index,FullIndex
from converter.queries import CloudQuery
from converter.cloud import ply_chunks

CAMERA={'eye':[0,0,10],'right':[1,0,0],'up':[0,1,0],'forward':[0,0,-1],
        'cx':500,'cy':400,'fx':100,'fy':100,'perspective':False,'width':1000,'height':800}

class QueryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        p=self.root/'点.xyz'
        p.write_text(''.join(f'{x} {y} {z} 100 200 30\n' for x,y,z in
                            [(0,0,0),(1,0,0),(1,0,1),(2,2,0),(3,3,3),(-1,0,0)]))
        build_index(p,self.root/'索引',preview_limit=1,lod_limit=1)
        self.query=CloudQuery(FullIndex(self.root/'索引'))
    def tearDown(self):self.temp.cleanup()
    def test_crop_and_export_use_all_points_not_overview(self):
        options={'clip':[1,0,0,3,2,1]}
        self.assertEqual(self.query.stats(options)['count'],4)
        path=self.root/'全量裁剪.ply';self.query.export(path,options)
        rows=list(ply_chunks(path));self.assertEqual(sum(len(a) for a,b in rows),4)
        np.testing.assert_array_equal(np.concatenate([b for a,b in rows]),np.tile([100,200,30],(4,1)))
        original=np.concatenate([a for a,b in rows]);self.assertIn([2,2,0],original.tolist())
    def test_pick_finds_unsampled_point_and_returns_exact_source_id(self):
        # local origin is [-1,0,0]; source point x=1 has local x=2.
        p=self.query.pick(CAMERA,700,400,{'clip':[0,-1,0,5,5,5]},radius=1)
        self.assertEqual(p['source_id'],2) # same screen position: nearest depth wins
        self.assertEqual(p['local_m'],[2,0,1])
        self.assertIsNone(self.query.pick(CAMERA,700,400,{},radius=1,max_depth=8))
    def test_rotation_translation_slice_and_view_budget(self):
        options={'angle':90,'x':10,'z':2,'slice':True,'slice_z':2,'slice_width':.01}
        self.assertEqual(self.query.stats(options)['count'],4)
        rows,info=self.query.view(CAMERA,{},2)
        self.assertLessEqual(len(rows),2)
        self.assertEqual(info['indexed_points'],6)
        self.assertTrue(set(rows['id']).issubset(set(range(6))))
    def test_view_full_resolution_when_local_points_fit_budget(self):
        cam=dict(CAMERA,fx=1000,fy=1000,cx=0,cy=3000,width=4000,height=4000)
        rows,info=self.query.view(cam,{},100)
        self.assertEqual(len(rows),6)
        self.assertEqual(info['full_tiles'],len(self.query.index.tiles))
    def test_export_never_overwrites_source_or_index(self):
        with self.assertRaises(ValueError):self.query.export(self.root/'点.xyz',{})
        with self.assertRaises(ValueError):self.query.export(self.root/'索引'/'恶意.ply',{})

    def test_dense_tile_pick_reaches_point_absent_from_current_frame(self):
        source=self.root/'密集.xyz'
        source.write_text(''.join(f'{i*.0001} 0 0\n' for i in range(10000)))
        folder=self.root/'密集索引';build_index(source,folder,preview_limit=1,lod_limit=2)
        query=CloudQuery(FullIndex(folder));cam=dict(CAMERA,fx=1,fy=1)
        rows,info=query.view(cam,{},1)
        self.assertGreater(info['lod_tiles'],0)
        wanted=1234 if rows['id'][0]!=1234 else 1235
        p=query.pick(cam,500+wanted*.0001,400,{},radius=.000001)
        self.assertEqual(p['source_id'],wanted)
        self.assertNotIn(wanted,rows['id'].tolist())
        # Activating a slice queries complete intersecting tiles before budgeting.
        rows,info=query.view(cam,{'slice':True,'slice_z':0,'slice_width':.01},20000)
        self.assertEqual(len(rows),10000);self.assertEqual(info['lod_tiles'],0)

    def test_rotated_crop_ids_match_independent_brute_force(self):
        rng=np.random.default_rng(9);xyz=rng.random((10000,3))*12
        source=self.root/'随机.xyz';np.savetxt(source,xyz,fmt='%.17g')
        folder=self.root/'随机索引';build_index(source,folder,preview_limit=2,lod_limit=2)
        query=CloudQuery(FullIndex(folder));angle=np.deg2rad(32)
        world=np.column_stack((xyz[:,0]*np.cos(angle)-xyz[:,1]*np.sin(angle)+2,
                               xyz[:,0]*np.sin(angle)+xyz[:,1]*np.cos(angle)-3,xyz[:,2]+1))
        clip=[1,0,2,7,9,10];mask=((world>=clip[:3])&(world<=clip[3:])).all(axis=1)
        options={'angle':32,'x':2,'y':-3,'z':1,'clip':clip}
        rows=list(query.selected(options));ids=np.sort(np.concatenate([r['id'] for r,w in rows]))
        np.testing.assert_array_equal(ids,np.flatnonzero(mask))

if __name__=='__main__':unittest.main()
