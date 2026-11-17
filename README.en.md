# SHARE3DCAM Scan Tools · Apple Silicon test branch

[中文](README.md) | **English**

<img src="extension/share_pointcloud/share3dcam-logo.png" width="260" alt="SHARE3DCAM">

**Saier E-commerce Center · 0.11.0-mac.1 · Chinese / English · MIT**

This branch targets native Apple Silicon SketchUp 2024–2026. Intel Macs and Rosetta
are unsupported. Metal renders full point clouds and Gaussian references; drawing,
cropping, project handling and bilingual UI reuse the existing implementation.

Native compilation, 9 frozen-converter format groups, 9 Metal GPU tests and 32 UI
combinations pass on an arm64 macOS 15 hosted runner. **Installation, interaction,
native modeling and save/reopen inside SketchUp for Mac have not been accepted.**
The test package is ad-hoc signed and has not been Apple Developer signed/notarized.

- [English installation and operation](docs/Mac_Installation_and_Operation.md)
- [中文安装与操作说明](docs/Mac安装与操作说明.md)
- [Successful build and tests](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/actions/runs/44038413085)
- Download the package from that run's Artifacts and install the RBZ via Extension Manager.

## Implemented scope

LAS/LAZ/PLY/XYZ/TXT/PTS point clouds; textured GLB/OBJ meshes; standard 3DGS PLY and
existing indexes; full viewport references, elevations and snapping, closed faces,
upward extrusion, rectangles/circles/polygons/arcs, 3D clip boxes, horizontal slices,
polygon cropping and collected reference projects. OSGB import is unsupported.

See the guide for limits and the remaining acceptance checklist.

## Build

On native arm64 macOS, install requirements-macos.txt and run
`python tools/build_macos.py`, `python tools/check_macos_frozen.py`,
`python tools/check_macos_native.py` and `python tools/mac_release.py`.
The complete pipeline is in `.github/workflows/macos-arm64.yml`.

The existing Windows 0.10.0 sources/packages remain on main and Releases.
This test branch does not replace them.
