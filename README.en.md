# SHARE3DCAM Scan Tools for SketchUp

[中文](README.md) | **English** | [Step-by-step user guide](docs/User-Guide.en.md)

<img src="extension/share_pointcloud/share3dcam-logo.png" width="260" alt="SHARE3DCAM">

**SHARE3DCAM · E-commerce Center · MIT open source**

Import point clouds, Gaussian splats and meshes into SketchUp, then trace the visible scan to create editable native edges, faces and solids.

> Version **0.10.0 — trial / prerelease**. Intended for Windows SketchUp 2024–2026. Tested on SketchUp 2026 with an RTX 4080 SUPER; SketchUp 2024/2025, other GPUs and long-term stability still require validation.

## Download and install

1. Download `SHARE3DCAM_SU_0.10.0.rbz` from the [0.10.0 release](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/releases/tag/v0.10.0).
2. In SketchUp, open **Extension Manager → Install Extension**, select the RBZ and restart SketchUp.
3. Open **Extensions → 赛尔点云绘图助手 / SHARE3DCAM Scan Tools**. Choose **English** at the top of the plugin panel. The plugin remembers your choice.

The installation package includes its runtime; customers do not need Python. SketchUp's own tools, menus and system dialog buttons follow their own language settings.

## Features

| Task | Available functions |
|---|---|
| Point clouds | LAS / LAZ / PLY / XYZ / TXT / PTS; complete index; reopen an existing index |
| Gaussian splats | Standard 3DGS PLY with shape, color and opacity as a reference in the SU viewport; reopen an existing index |
| Meshes | GLB / OBJ imported as native components; OBJ requires its MTL and texture files |
| View | Original colors, top view, reference zoom, Gaussian opacity, reference alignment |
| Crop | 3D clipping box, horizontal slice, polygon keep/remove, undo and reset |
| Draw | Snap tracing, rectangle, circle, regular polygon, center-point arc, native Push/Pull, upward extrusion, native Offset, distance measurement and guide points |
| Elevation | Read model Z and source Z; use a picked value as the drawing elevation |
| Project | Save the SKP and collect its scan index for reopening or handoff |
| Language | Chinese / English panel, plugin tool hints and context menus; persistent preference |

Point clouds and Gaussians are uploaded to GPU memory once. The renderer submits the full dataset during navigation and at rest rather than switching to a sampled navigation preview. Hardware resources determine the practical dataset size. Current hard limits per reference are 100 million ordinary points or 20 million standard Gaussians; these are not guaranteed usable capacities on every computer.

## Recommended workflow

1. **Import:** select the correct input type and source units, or open an existing index.
2. **View / Crop:** align the reference, remove distracting regions and inspect the floor plan.
3. **Draw:** pick and verify a floor elevation; trace wall footprints while the scan remains visible. Use straight, axis-aligned geometry where supported by the scan instead of following isolated noise.
4. **Build:** close planar profiles, extrude in place, and use native SketchUp editing for openings, beams, columns and slabs. Verify dimensions against the visible reference.
5. **Project:** choose **Save & collect project**. Keep the SKP and its matching scan-data folder together.

See the [English user guide](docs/User-Guide.en.md) for click sequences, dimension examples, cropping, troubleshooting and project handoff.

## Current limitations

- Gaussian input must use the standard 3DGS PLY property layout. Ordinary vertex PLY files belong in the point-cloud importer. Compressed or nonstandard Gaussian formats may not load.
- Mesh support is GLB / OBJ. OSGB is not implemented. The plugin does not automatically reconstruct a complete building from scans.
- Gaussian snapping uses the original center of a visible Gaussian. Verify elevations and dimensions using neighboring points and a site reference.
- Free crop is a reversible display mask, not a source-file edit. Cropped PLY export is limited to ordinary point clouds within the clipping box; reset free crop before box statistics or export.
- Scan overlays are not included in SketchUp's normal 2D image export. Use an actual viewport screenshot when documenting the scan together with geometry.
- This is an unsigned trial extension. A GPU process exited unexpectedly during an earlier test run; three subsequent full reruns passed without reproducing it. One 0.10.0 test run also encountered a temporary JSON-file `PermissionError`; the affected test passed three isolated reruns and the full suite then passed. Long-term stability remains under validation.

## Development and verification

Use Windows x64, Python 3.12, Visual Studio 2022 C++ Build Tools, Windows SDK and a D3D11-capable GPU.

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-lock.txt
.\.venv\Scripts\python.exe tools/build.py
```

The repository contains source code, not customer datasets, generated indexes or compiled runtimes. Installable binaries are provided in Releases. The build compiles the native renderer, runs backend tests and packages the runtime and extension. Additional architecture notes are currently [available in Chinese](docs/构建与架构.md).

Verification includes 40 backend tests, 18 SketchUp shape checks, 11 native bilingual checks and 32 language/width/tab browser-layout combinations. Tests use synthetic datasets. Passing tests does not establish compatibility with every customer environment.

Report issues through [GitHub Issues](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/issues), including SketchUp version, GPU, plugin version, file format and reproduction steps. Do not upload customer data without permission.

## License

Original project code is licensed under [MIT](LICENSE). Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.txt).

This project is independently developed and is not affiliated with Trimble or SketchUp. The code license does not grant trademark rights or imply official endorsement.
