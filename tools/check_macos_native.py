"""Compile/load checks are separate from real Metal and SketchUp acceptance."""
from pathlib import Path
import ctypes as C
import json,platform,re,struct,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]

def main():
    if sys.platform!='darwin' or platform.machine()!='arm64':raise SystemExit('Native arm64 macOS required')
    lib=C.CDLL(str(ROOT/'extension/share_pointcloud/bin/macos-arm64/libshare_cloud_resident.dylib'))
    names=re.findall(r"extern '.*? (pc_\w+)\(",(ROOT/'extension/share_pointcloud/resident_viewport.rb').read_text('utf-8'))
    for name in names:getattr(lib,name)
    lib.pc_create.restype=C.c_void_p
    for name,args in {'pc_add_tile':[C.c_void_p,C.c_char_p,C.c_uint64],'pc_load':[C.c_void_p,C.c_uint],'pc_wait':[C.c_void_p],'pc_stats':[C.c_void_p],'pc_destroy':[C.c_void_p]}.items():getattr(lib,name).argtypes=args
    lib.pc_stats.restype=C.c_char_p
    p=lib.pc_create()
    try:
        with tempfile.TemporaryDirectory(prefix='室内 Mac ') as d:
            path=Path(d)/'基准 点.bin';path.write_bytes(struct.pack('<dddHHHQ',0.,0.,0.,65535,0,0,42))
            assert lib.pc_add_tile(p,str(path).encode(),1)==0
            assert lib.pc_load(p,257)==0
            status=lib.pc_wait(p);info=json.loads(lib.pc_stats(p))
    finally:lib.pc_destroy(p)
    report={'architecture':platform.machine(),'native_library_load':'passed','exported_symbols':names,'gpu_runtime_tests_passed':False,'sketchup_mac_acceptance_passed':False,'probe':info}
    if status!=0:
        if 'No Metal GPU available' not in info.get('error',''):raise RuntimeError(info)
        report['gpu_status']='not run: hosted machine exposes no Metal GPU'
    else:
        sys.path[:0]=[str(ROOT),str(ROOT/'tests')]
        suite=unittest.defaultTestLoader.loadTestsFromNames(['test_resident','test_gaussian','test_free_crop','test_macos_retina'])
        result=unittest.TextTestRunner(verbosity=2).run(suite)
        report.update(gpu_runtime_tests_passed=result.wasSuccessful(),gpu_status='passed' if result.wasSuccessful() else 'failed',tests_run=result.testsRun)
        if not result.wasSuccessful():raise RuntimeError('Metal GPU regression tests failed')
    folder=ROOT/'build/macos-arm64';folder.mkdir(parents=True,exist_ok=True)
    (folder/'native-validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
