"""Native full-cloud rendering contract; exercises real D3D11, not a mock GPU."""
import ctypes as C
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
DLL=ROOT/'extension/share_pointcloud/bin/share_cloud_resident_097.dll'

class ResidentTests(unittest.TestCase):
 def test_off_center_native_projection_controls_display_and_pick(self):
  class Vec(C.Structure):_fields_=[('x',C.c_double),('y',C.c_double),('z',C.c_double)]
  class Frame(C.Structure):
   _fields_=[('version',C.c_uint32),('position',Vec),('target',Vec),('up',Vec),('aspect',C.c_double),('near',C.c_double),('far',C.c_double),('projection',C.c_double*16),('view',C.c_double*16),('width',C.c_double),('height',C.c_double),('fov',C.c_double),('ortho_height',C.c_double),('perspective',C.c_bool),('reserved',C.c_void_p)]
  self.assertEqual(C.sizeof(Frame),408)
  lib=C.CDLL(str(DLL));lib.pc_create.restype=C.c_void_p
  for name,args in {'pc_add_tile':[C.c_void_p,C.c_char_p,C.c_uint64],'pc_load':[C.c_void_p,C.c_uint],'pc_wait':[C.c_void_p],'pc_destroy':[C.c_void_p],'pc_render_camera':[C.c_void_p,C.POINTER(Frame)],'pc_pick':[C.c_void_p,C.c_double,C.c_double,C.c_double,C.c_double,C.c_double,C.c_void_p]}.items():getattr(lib,name).argtypes=args
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'偏移投影.bin';path.write_bytes(struct.pack('<dddHHHQ',0,0,0,65535,0,0,42));p=lib.pc_create()
   try:
    lib.pc_add_tile(p,str(path).encode(),1);lib.pc_load(p,257);self.assertEqual(lib.pc_wait(p),0)
    f=Frame();f.position=Vec(0,0,10/.0254);f.up=Vec(0,1,0);f.near=.01;f.far=100000;f.width=640;f.height=480;f.ortho_height=8/.0254
    for i in range(4):f.view[i*5]=1
    f.view[11]=-f.position.z
    f.projection[0]=2/(f.ortho_height*640/480);f.projection[5]=2/f.ortho_height
    f.projection[10]=-2/(f.far-f.near);f.projection[11]=-(f.far+f.near)/(f.far-f.near);f.projection[15]=1
    f.projection[3]=.25;f.projection[7]=-.2
    self.assertEqual(lib.pc_render_camera(p,C.byref(f)),0)
    out=C.create_string_buffer(32);self.assertEqual(lib.pc_pick(p,400,288,3,640,480,out),1)
    self.assertEqual(struct.unpack('<dddQ',out.raw)[3],42)
   finally:lib.pc_destroy(p)

 def test_incomplete_index_fails_without_showing_partial_data(self):
  lib=C.CDLL(str(DLL));lib.pc_create.restype=C.c_void_p
  for name,args in {'pc_add_tile':[C.c_void_p,C.c_char_p,C.c_uint64],'pc_load':[C.c_void_p,C.c_uint],'pc_wait':[C.c_void_p],'pc_stats':[C.c_void_p],'pc_destroy':[C.c_void_p]}.items():getattr(lib,name).argtypes=args
  lib.pc_stats.restype=C.c_char_p
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'损坏索引.bin';path.write_bytes(b'\0'*38);p=lib.pc_create()
   try:
    self.assertEqual(lib.pc_add_tile(p,str(path).encode(),2),0);lib.pc_load(p,1)
    self.assertEqual(lib.pc_wait(p),-1);s=json.loads(lib.pc_stats(p))
    self.assertEqual(s['resident_points'],0);self.assertEqual(s['uploads'],0);self.assertTrue(s['error'])
   finally:lib.pc_destroy(p)

 def test_depth_color_and_pick_remain_original_and_apply_clip(self):
  self.assertTrue(DLL.is_file())
  lib=C.CDLL(str(DLL));lib.pc_create.restype=C.c_void_p
  for name,args in {'pc_destroy':[C.c_void_p],'pc_add_tile':[C.c_void_p,C.c_char_p,C.c_uint64],'pc_load':[C.c_void_p,C.c_uint],'pc_wait':[C.c_void_p],'pc_render_test':[C.c_void_p,C.POINTER(C.c_double),C.c_uint,C.c_uint],'pc_read_ids':[C.c_void_p,C.POINTER(C.c_uint32),C.c_uint],'pc_read_color':[C.c_void_p,C.POINTER(C.c_uint32),C.c_uint],'pc_options':[C.c_void_p,C.c_void_p],'pc_pick':[C.c_void_p,C.c_double,C.c_double,C.c_double,C.c_double,C.c_double,C.c_void_p]}.items():getattr(lib,name).argtypes=args
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'颜色深度.bin'
   path.write_bytes(struct.pack('<dddHHHQ',0,0,0,0,0,65535,42)+struct.pack('<dddHHHQ',0,0,2,65535,0,0,99))
   p=lib.pc_create()
   try:
    self.assertEqual(lib.pc_add_tile(p,str(path).encode(),2),0);lib.pc_load(p,257);self.assertEqual(lib.pc_wait(p),0)
    cam=(C.c_double*10)(0,0,10,0,0,0,0,1,0,8)
    self.assertEqual(lib.pc_render_test(p,cam,640,480),0)
    ids=(C.c_uint32*(640*480))();colors=(C.c_uint32*(640*480))()
    lib.pc_read_ids(p,ids,len(ids));lib.pc_read_color(p,colors,len(colors))
    pixels=[i for i,n in enumerate(ids) if n]
    self.assertEqual(len(pixels),1);self.assertEqual(ids[pixels[0]],2)
    self.assertEqual(colors[pixels[0]],0xff0000ff) # real near-point RGBA
    out=C.create_string_buffer(32)
    self.assertEqual(lib.pc_pick(p,320,240,3,640,480,out),1)
    x,y,z,source_id=struct.unpack('<dddQ',out.raw)
    self.assertAlmostEqual(z,2/.0254,places=8);self.assertEqual(source_id,99)
    self.assertEqual(lib.pc_pick(p,160,120,3,320,240,out),1) # physical/logical DPI scaling
    self.assertEqual(struct.unpack('<dddQ',out.raw)[3],99)
    # Clip away the near red point, retaining the blue source point and ID.
    opt=struct.pack('<12dII',0,0,0,0,-1,-1,-1,1,1,1,0,.1,5,0)
    self.assertEqual(lib.pc_options(p,opt),0)
    self.assertEqual(lib.pc_render_test(p,cam,640,480),0)
    self.assertEqual(lib.pc_pick(p,320,240,3,640,480,out),1)
    self.assertEqual(struct.unpack('<dddQ',out.raw)[3],42)
    # Clipping and horizontal slice live in aligned model coordinates, not
    # untransformed source coordinates (must agree with stats/export).
    opt=struct.pack('<12dII',10,3,5,90,9,2,4,11,4,6,5,.2,7,0)
    lib.pc_options(p,opt);cam=(C.c_double*10)(10,3,15,10,3,5,0,1,0,8)
    self.assertEqual(lib.pc_render_test(p,cam,640,480),0)
    self.assertEqual(lib.pc_pick(p,320,240,3,640,480,out),1)
    x,y,z,source_id=struct.unpack('<dddQ',out.raw)
    self.assertEqual(source_id,42);self.assertAlmostEqual(x,10/.0254,places=8)
    self.assertAlmostEqual(y,3/.0254,places=8);self.assertAlmostEqual(z,5/.0254,places=8)
   finally:lib.pc_destroy(p)

 def test_native_renderer_uses_entire_buffer_for_every_camera(self):
  self.assertTrue(DLL.is_file(),'resident native renderer has not been built')
  lib=C.CDLL(str(DLL));lib.pc_create.restype=C.c_void_p
  lib.pc_destroy.argtypes=[C.c_void_p]
  lib.pc_add_tile.argtypes=[C.c_void_p,C.c_char_p,C.c_uint64]
  lib.pc_load.argtypes=[C.c_void_p,C.c_uint]
  lib.pc_wait.argtypes=[C.c_void_p]
  lib.pc_render_test.argtypes=[C.c_void_p,C.POINTER(C.c_double),C.c_uint,C.c_uint]
  lib.pc_stats.argtypes=[C.c_void_p];lib.pc_stats.restype=C.c_char_p
  lib.pc_read_ids.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.c_uint]
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'室内点云.bin';rows=[]
   # 160001 distinct original points. Every frame must submit all, even if
   # multiple points land on the same pixel. Source records remain exact.
   for i in range(160001):
    rows.append(struct.pack('<dddHHHQ',(i%401-200)*.01,(i//401-200)*.01,0.,65535,0,0,i))
   path.write_bytes(b''.join(rows));p=lib.pc_create();self.assertTrue(p)
   try:
    self.assertEqual(lib.pc_add_tile(p,str(path).encode(),len(rows)),0)
    self.assertEqual(lib.pc_load(p,257),0);self.assertEqual(lib.pc_wait(p),0)
    camera=(C.c_double*10)(0,0,10,0,0,0,0,1,0,8)
    for n in range(3):
     camera[0]=n*.4
     self.assertEqual(lib.pc_render_test(p,camera,640,480),0)
     s=json.loads(lib.pc_stats(p));self.assertEqual(s['resident_points'],160001)
     self.assertEqual(s['submitted_points'],160001);self.assertEqual(s['uploads'],1)
     self.assertFalse(s['preview']);self.assertGreater(s['visible_pixels'],1000)
    ids=(C.c_uint32*(640*480))();self.assertEqual(lib.pc_read_ids(p,ids,len(ids)),0)
    self.assertTrue(all(i<=160001 for i in ids))
   finally:lib.pc_destroy(p)
