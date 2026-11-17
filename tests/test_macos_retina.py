import ctypes as C
import struct,tempfile,unittest,sys
from pathlib import Path
from native_library import LIBRARY

class RetinaTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin','Mac-specific error contract')
    def test_crop_reset_requires_a_loaded_renderer(self):
        api=C.CDLL(str(LIBRARY));api.pc_create.restype=C.c_void_p
        api.pc_crop_reset.argtypes=[C.c_void_p];api.pc_destroy.argtypes=[C.c_void_p]
        e=api.pc_create()
        try:self.assertEqual(api.pc_crop_reset(e),-1)
        finally:api.pc_destroy(e)

    def test_odd_width_readback_and_two_x_logical_pixel_picking(self):
        api=C.CDLL(str(LIBRARY));api.pc_create.restype=C.c_void_p
        signatures={'pc_destroy':[], 'pc_add_tile':[C.c_char_p,C.c_uint64], 'pc_load':[C.c_uint], 'pc_wait':[], 'pc_render_test':[C.POINTER(C.c_double),C.c_uint,C.c_uint], 'pc_pick':[C.c_double,C.c_double,C.c_double,C.c_double,C.c_double,C.c_void_p]}
        for name,args in signatures.items():getattr(api,name).argtypes=[C.c_void_p,*args]
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'Retina.bin';p.write_bytes(struct.pack('<dddHHHQ',0.,0.,0.,65535,0,0,424242));e=api.pc_create()
            try:
                self.assertEqual(api.pc_add_tile(e,str(p).encode(),1),0);api.pc_load(e,257);self.assertEqual(api.pc_wait(e),0)
                camera=(C.c_double*10)(0,0,10,0,0,0,0,1,0,8)
                self.assertEqual(api.pc_render_test(e,camera,643,479),0)
                result=C.create_string_buffer(32)
                self.assertEqual(api.pc_pick(e,160.75,119.75,3,321.5,239.5,result),1)
                self.assertEqual(struct.unpack('<dddQ',result.raw)[3],424242)
            finally:api.pc_destroy(e)
