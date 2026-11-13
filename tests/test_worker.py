import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import numpy as np
from converter.full_index import build_index,atomic_json,FullIndex
from converter.queries import CloudQuery
from converter.worker import execute
from tests.test_queries import CAMERA


class WorkerTests(unittest.TestCase):
    def test_cpu_fallback_keeps_native_marks_and_exact_pick_grid(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'cloud.xyz';source.write_text('0 0 0\n1 0 0\n')
            build_index(source,root/'index',preview_limit=1)
            query=CloudQuery(FullIndex(root/'index'));query.gpu_error='GPU unavailable in test'
            result=execute(query,{'action':'full_view','camera':CAMERA},root,'a'*32)
            self.assertEqual(result['engine'],'cpu')
            self.assertEqual(result['gpu_fallback'],'GPU unavailable in test')
            self.assertEqual(result['display_points'],2)
            self.assertEqual(result['primitive'],'lines')
            grid=np.fromfile(root/result['grid'],dtype='<i4')
            self.assertEqual(set(grid[grid>=0]),{0,1})

    def test_real_process_queries_full_data_and_stops(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'中文 文件.xyz';source.write_text('0 0 0 1 2 3\n1 0 0 4 5 6\n')
            build_index(source,root/'索引',preview_limit=1)
            ipc=root/'会话';ipc.mkdir()
            p=subprocess.Popen([sys.executable,'-m','converter.main','--serve','--cache',str(root/'索引'),
                                '--session',str(ipc),'--parent',str(os.getpid())])
            def wait_for(path):
                deadline=time.monotonic()+15
                while not path.exists():
                    if time.monotonic()>deadline or p.poll() is not None:self.fail('worker did not respond')
                    time.sleep(.03)
                return json.loads(path.read_text('utf-8'))
            def request(action,**data):
                token=uuid.uuid4().hex
                atomic_json(ipc/f'req_{token}.json',dict(action=action,generation=73,**data))
                return wait_for(ipc/f'res_{token}.json')
            try:
                self.assertEqual(wait_for(ipc/'ready.json')['state'],'ready')
                r=request('view',camera=CAMERA,limit=1)
                self.assertTrue(r['ok']);self.assertEqual(r['generation'],73)
                self.assertEqual((ipc/r['result']['xyz']).stat().st_size,12)
                r=request('pick',camera=CAMERA,x=600,y=400,radius=1)
                self.assertEqual(r['result']['pick']['source_id'],1)
                r=request('stats');self.assertEqual(r['result']['count'],2)
                r=request('full_view',camera=CAMERA,limit=1)
                self.assertEqual(r['result']['display_points'],2)
                self.assertEqual(r['result']['scanned_points'],2)
                self.assertEqual(r['result']['xyz_type'],'float64')
                self.assertEqual((ipc/r['result']['xyz']).stat().st_size,48)
                self.assertEqual(r['result']['xyz_space'],'world_inches')
                grid=np.fromfile(ipc/r['result']['grid'],dtype='<i4')
                self.assertEqual(set(grid[grid>=0]),{0,1})
                ids=np.fromfile(ipc/r['result']['ids'],dtype='<u8')
                self.assertEqual(set(ids),{0,1})
                self.assertEqual(sum(g['count'] for g in r['result']['native_groups']),2)
                self.assertEqual(r['result']['primitive'],'lines')
                vertices=np.fromfile(ipc/r['result']['vertices'],dtype='<f8').reshape(-1,2,3)
                centers=np.fromfile(ipc/r['result']['xyz'],dtype='<f8').reshape(-1,3)
                np.testing.assert_allclose(vertices.mean(axis=1),centers,atol=1e-12)
                # Native marks are one physical pixel wide and retain the true
                # source center for picking instead of snapping to an endpoint.
                np.testing.assert_allclose((vertices[:,1,0]-vertices[:,0,0])*.0254*CAMERA['fx'],1,atol=1e-12)
                r=request('full_view',camera=CAMERA,options={'angle':90,'x':2})
                xyz=np.fromfile(ipc/r['result']['xyz'],dtype='<f8').reshape(-1,3)*.0254
                ids=np.fromfile(ipc/r['result']['ids'],dtype='<u8')
                np.testing.assert_allclose(xyz[np.argsort(ids)],[[2,0,0],[2,1,0]],atol=1e-14)
                r=request('view',camera=CAMERA,limit=10_000_000)
                self.assertFalse(r['ok'])
                self.assertTrue(request('stop')['result']['stopped'])
                self.assertEqual(p.wait(timeout=5),0)
            finally:
                if p.poll() is None:p.terminate();p.wait(timeout=5)

if __name__=='__main__':unittest.main()
