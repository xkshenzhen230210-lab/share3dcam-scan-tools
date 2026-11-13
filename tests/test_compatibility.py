import json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from converter.compatibility import choose_mask

class CompatibilityTests(unittest.TestCase):
 def test_hybrid_prefers_available_efficiency_cores(self):
  rows=[(0,0,1,0),(0,1,1,0),(0,2,0,0),(0,3,0,0)]
  self.assertEqual(choose_mask(15,rows),12)
  self.assertEqual(choose_mask(7,rows),4)
 def test_does_not_select_reserved_or_other_group(self):
  self.assertEqual(choose_mask(7,[(0,0,1,0),(0,1,0,2),(0,2,0,6),(1,2,0,0)]),4)
 def test_uniform_and_unavailable_api_use_one_allowed_processor(self):
  self.assertEqual(choose_mask(12,[(0,2,0,0),(0,3,0,0)]),4)
  self.assertEqual(choose_mask(12,[]),4)
 @unittest.skipUnless(os.name=='nt','Windows process scheduling')
 def test_cli_applies_only_to_its_process_before_numpy_import(self):
  with tempfile.TemporaryDirectory() as name:
   root=Path(name);source=root/'a.xyz';source.write_text('0 0 0\n1 1 1\n')
   subprocess.run([sys.executable,'-m','converter.main','--index','--compatible-cpu','--source',str(source),'--out',str(root/'index'),'--limit','1'],check=True,timeout=30)
   meta=json.loads((root/'index/cloud.json').read_text('utf-8'))
   self.assertEqual(meta['indexed_points'],2)
   self.assertEqual(meta['import_policy']['scope'],'converter_process_only')
   self.assertGreater(meta['import_policy']['cpu_mask'],0)
