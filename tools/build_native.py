"""Build the resident renderer against the installed Windows SDK, no SU SDK binary."""
from pathlib import Path
import os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
# Set VCVARS64 explicitly for a custom Build Tools installation.
vc=Path(os.environ['VCVARS64']) if os.environ.get('VCVARS64') else None
if vc is None:
    where=Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
    if not where.is_file():
        raise SystemExit('Install Visual Studio 2022 Build Tools (Desktop development with C++), or set VCVARS64.')
    installation=subprocess.check_output([str(where),'-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],text=True).strip()
    if not installation:
        raise SystemExit('C++ Build Tools not found. Install the C++ workload and Windows SDK.')
    vc=Path(installation)/'VC/Auxiliary/Build/vcvars64.bat'
if not vc.is_file():
    raise SystemExit('VCVARS64 must point to an existing vcvars64.bat.')
env=os.environ.copy()
with tempfile.TemporaryDirectory(prefix='share3dcam-build-') as temporary:
    setup=Path(temporary)/'environment.cmd'
    setup.write_text(f'@echo off\ncall "{vc}" >nul\nif errorlevel 1 exit /b %errorlevel%\nset\n',encoding='mbcs')
    r=subprocess.run(['cmd.exe','/d','/c',str(setup)],capture_output=True,text=True,check=True)
for line in r.stdout.splitlines():
 if '=' in line:
  key,value=line.split('=',1)
  if key:env[key]=value
out=ROOT/'extension/share_pointcloud/bin';out.mkdir(exist_ok=True)
build=ROOT/'build/native';build.mkdir(parents=True,exist_ok=True)
cl=Path(env['VCToolsInstallDir'])/'bin/Hostx64/x64/cl.exe'
args=[str(cl),'/nologo','/O2','/EHsc','/std:c++17','/utf-8','/MD','/LD',str(ROOT/'native/resident.cpp'),'/Fo'+str(build/'resident.obj'),'/Fe'+str(out/'share_cloud_resident_097.dll'),'/link','d3d11.lib','dxgi.lib','d3dcompiler.lib','/IMPLIB:'+str(build/'resident.lib')]
subprocess.run(args,env=env,cwd=build,check=True)
