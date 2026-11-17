"""Native Apple Silicon build. Run on arm64 macOS, never cross-label Windows output."""
from pathlib import Path
import json,os,platform,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]

def main():
    if sys.platform!='darwin' or platform.machine()!='arm64':
        raise SystemExit('Build requires native Apple Silicon macOS; Intel/Rosetta/Windows is unsupported.')
    build=ROOT/'build/macos-arm64';build.mkdir(parents=True,exist_ok=True)
    out=ROOT/'extension/share_pointcloud/bin/macos-arm64';out.mkdir(parents=True,exist_ok=True)
    subprocess.run([sys.executable,str(ROOT/'tools/collect_licenses.py')],check=True)
    shader=(ROOT/'native/mac/shaders.metal').read_text('utf-8')
    (build/'metal_source.h').write_text('static const char* metal_source=R"METAL('+shader+')METAL";\n',encoding='utf-8')
    subprocess.run(['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-fvisibility=hidden','-arch','arm64','-mmacosx-version-min=13.0','-dynamiclib',str(ROOT/'native/mac/resident_metal.mm'),'-I'+str(build),'-framework','Foundation','-framework','Metal','-o',str(out/'libshare_cloud_resident.dylib')],check=True)
    # Explicitly compile MSL as well as embedding it for runtime compilation.
    subprocess.run(['xcrun','-sdk','macosx','metal','-c',str(ROOT/'native/mac/shaders.metal'),'-o',str(build/'shaders.air')],check=True)
    subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onefile','--target-arch','arm64','--name','share_cloud_engine','--paths',str(ROOT),'--collect-all','laspy','--collect-all','lazrs','--collect-all','trimesh','--collect-all','collada','--distpath',str(build/'dist'),'--workpath',str(build/'pyinstaller'),str(ROOT/'converter/main.py')],cwd=ROOT,check=True)
    import shutil
    shutil.copy2(build/'dist/share_cloud_engine',out/'share_cloud_engine')
    for p in [out/'share_cloud_engine',out/'libshare_cloud_resident.dylib']:
        p.chmod(0o755)
        subprocess.run(['codesign','--force','--sign','-',str(p)],check=True)
        subprocess.run(['codesign','--verify','--strict',str(p)],check=True)
        subprocess.run(['lipo','-verify_arch','arm64',str(p)],check=True)
    print(json.dumps({'platform':platform.platform(),'architecture':platform.machine(),'native_build':'passed','sketchup_mac_acceptance':'not run'},indent=2))

if __name__=='__main__':main()
