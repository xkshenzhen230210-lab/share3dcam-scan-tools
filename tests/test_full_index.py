import tempfile
import unittest
from pathlib import Path
import numpy as np
from converter.full_index import build_index, FullIndex

class FullIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def test_every_valid_point_survives_and_source_ids_are_retained(self):
        source=self.root/'中文 全量.xyz'
        source.write_text(''.join(f'{600000+i*.001} 3000000 2 10 20 30\n' for i in range(5000))+'nan 0 0 0 0 0\n')
        original=source.read_bytes();out=self.root/'索引'
        m=build_index(source,out,preview_limit=7,lod_limit=3)
        self.assertEqual(m['indexed_points'],5000);self.assertEqual(m['invalid_points'],1)
        index=FullIndex(out);rows=np.concatenate(list(index.all_records()))
        rows=rows[np.argsort(rows['id'])]
        np.testing.assert_array_equal(rows['id'],np.arange(5000))
        np.testing.assert_allclose(rows['xyz']+m['origin_m'],[[600000+i*.001,3000000,2] for i in range(5000)],rtol=0,atol=1e-9)
        np.testing.assert_array_equal(rows['rgb'],np.tile([10,20,30],(5000,1)))
        self.assertEqual(source.read_bytes(),original)
        self.assertLessEqual(m['display_points'],7)
        self.assertEqual(sum(t['count'] for t in m['tiles']),5000)
    def test_no_partial_index_is_published_on_bad_input(self):
        p=self.root/'坏.pts';p.write_text('3\n1 2 3\n')
        out=self.root/'失败索引'
        with self.assertRaises(ValueError):build_index(p,out)
        self.assertFalse((out/'cloud.json').exists())
    def test_duplicates_are_separate_records_and_invalid_ids_have_gaps(self):
        p=self.root/'点.pts';p.write_text('4\n1 2 3\nnan 2 3\n1 2 3\n4 5 6\n')
        out=self.root/'缓存';m=build_index(p,out,preview_limit=1,lod_limit=1)
        ids=np.sort(np.concatenate([a['id'] for a in FullIndex(out).all_records()]))
        self.assertEqual(ids.tolist(),[0,2,3]);self.assertEqual(m['indexed_points'],3)
    def test_unit_and_16bit_color_are_preserved(self):
        p=self.root/'点.ply'
        p.write_text('ply\nformat ascii 1.0\nelement vertex 2\nproperty double x\nproperty double y\nproperty double z\nproperty ushort red\nproperty ushort green\nproperty ushort blue\nend_header\n1001.125 2000 3000 65535 257 0\n1002 2001 3001 0 65535 12345\n')
        out=self.root/'缓存';m=build_index(p,out,unit='mm')
        rows=np.concatenate(list(FullIndex(out).all_records()));rows=rows[np.argsort(rows['id'])]
        np.testing.assert_allclose(rows['xyz']+m['origin_m'],[[1.001125,2,3],[1.002,2.001,3.001]],rtol=0,atol=1e-12)
        self.assertEqual(rows['rgb'].tolist(),[[65535,257,0],[0,65535,12345]])
        self.assertEqual(m['color_divisor'],257)

if __name__=='__main__':unittest.main()
