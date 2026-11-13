import ctypes as C
import json, struct, tempfile, unittest
from pathlib import Path
import numpy as np
from converter.gaussian import RECORD

class FreeCropTests(unittest.TestCase):
 def test_concave_keep_remove_reset_camera_and_pick(self):
  api=C.CDLL(str(Path(__file__).resolve().parents[1]/'extension/share_pointcloud/bin/share_cloud_resident_097.dll'))
  api.pc_create.restype=C.c_void_p
  signatures={'pc_add_tile':[C.c_char_p,C.c_uint64],'pc_add_gaussians':[C.c_char_p,C.c_uint64,C.c_char_p,C.c_uint32], 'pc_load':[C.c_uint32],'pc_wait':[], 'pc_destroy':[], 'pc_crop_matrix':[C.c_void_p], 'pc_crop_polygon':[C.c_void_p,C.c_void_p,C.c_uint32,C.c_int], 'pc_crop_reset':[], 'pc_render_test':[C.c_void_p,C.c_uint32,C.c_uint32], 'pc_read_ids':[C.c_void_p,C.c_uint32], 'pc_pick':[C.c_double,C.c_double,C.c_double,C.c_double,C.c_double,C.c_void_p]}
  for name,args in signatures.items():getattr(api,name).argtypes=[C.c_void_p,*args]
  xyz=[(x,y,0) for y in range(-2,3) for x in range(-2,3)]
  expected={i+1 for i,(x,y,z) in enumerate(xyz) if x<=0 or y<=0}
  with tempfile.TemporaryDirectory() as tmp:
   for gaussian in (False,True):
    with self.subTest(gaussian=gaussian):
     path=Path(tmp)/'cloud.bin';e=api.pc_create()
     try:
      if gaussian:
       rows=np.zeros(25,dtype=RECORD);rows['mean']=xyz;rows['covariance'][:,[0,3,5]]=.002;rows['alpha']=1;rows.tofile(path)
       self.assertEqual(api.pc_add_gaussians(e,str(path).encode(),25,b'',0),0)
      else:
       path.write_bytes(b''.join(struct.pack('<dddHHHQ',*p,65535,0,0,i) for i,p in enumerate(xyz)))
       self.assertEqual(api.pc_add_tile(e,str(path).encode(),25),0)
      api.pc_load(e,257);self.assertEqual(api.pc_wait(e),0)
      cam=(C.c_double*10)(0,0,10,0,0,0,0,1,0,8);ids=np.zeros(320*240,dtype=np.uint32)
      def render():
       self.assertEqual(api.pc_render_test(e,cam,320,240),0);self.assertEqual(api.pc_read_ids(e,ids.ctypes.data,len(ids)),0)
       return set(np.unique(ids))-{0}
      self.assertEqual(len(render()),25)
      m=(C.c_double*16)();self.assertEqual(api.pc_crop_matrix(e,m),0)
      poly=(C.c_double*12)(-.6,-.6,.6,-.6,.6,0,0,0,0,.6,-.6,.6)
      self.assertEqual(api.pc_crop_polygon(e,m,poly,6,1),0);self.assertEqual(render(),expected)
      out=C.create_string_buffer(32)
      self.assertEqual(api.pc_pick(e,190,90,2,320,240,out),0) # removed (+1,+1)
      cam[2]=-10;self.assertEqual(render(),expected) # crop persists when viewpoint changes
      api.pc_crop_reset(e);cam[2]=10;self.assertEqual(len(render()),25)
      self.assertEqual(api.pc_crop_polygon(e,m,poly,6,0),0);self.assertEqual(render(),set(range(1,26))-expected)
      self.assertEqual(api.pc_crop_polygon(e,m,poly,2,1),-1)
      api.pc_crop_reset(e);self.assertEqual(len(render()),25)
     finally:api.pc_destroy(e)
