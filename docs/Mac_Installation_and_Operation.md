# SHARE3DCAM Scan Tools for Apple Silicon

Saier E-commerce Center · 0.11.0-mac.1 · Chinese / English test build

## Compatibility and validation

M-series Macs only. Run SketchUp natively, without Rosetta. The target SketchUp
range is 2024–2026. Intel Macs are not supported. The automated build environment
is macOS 15 / arm64; other macOS versions have not been verified on a real device.

Native compilation, frozen-converter format checks and Metal GPU regressions
run on an Apple Silicon hosted machine. **Installation, input handling, native
modeling and project reopening inside SketchUp for Mac have not been accepted.**
This is an installable test package, not a production-certified release. Native
files have ad-hoc signatures; Apple Developer signing/notarization is pending.

## Install

1. Extract the delivery ZIP. Keep the inner RBZ intact.
2. In SketchUp's Extension Manager, choose Install Extension and select the RBZ.
3. Restart SketchUp and open “赛尔点云绘图助手 / SHARE3DCAM Scan Tools”.
4. Select Chinese or English at the top. Your selection is remembered.
5. Verify a small sample, picking and reopening before working on a large job.

No separate Python, CUDA or Windows environment is required on the customer Mac.

## Feature correspondence

| Feature | Mac implementation |
|---|---|
| Point clouds | LAS, LAZ, ordinary PLY, XYZ, TXT, PTS; full indexing and existing indexes |
| Full rendering | Metal-resident data; all indexed points submitted while moving and idle |
| Mesh | GLB and OBJ converted/imported as native components with textures |
| Gaussian | Standard 3DGS PLY and existing Gaussian indexes in the SU viewport |
| Reference tools | Move, rotate, 3D clip box, horizontal slice, polygon crop and restore |
| Drawing | Elevations, measurement, tracing/faces, rectangle, circle, polygon, arc, upward extrusion |
| Projects | Existing SKP save, collected reference data and restore code |
| Languages | One shared Chinese/English phrase table and interface/tool implementation |

These describe implemented scope, not completed SketchUp-on-Mac acceptance.
The Windows-only CPU scheduling compatibility checkbox is disabled on Mac.
Limits remain 100 million ordinary points or 20 million standard Gaussians,
subject to unified memory and Metal buffer limits. Resource failures are reported;
they do not silently replace the full reference with a preview. OSGB is unsupported.

## Operation

**Point cloud:** Import → Point cloud → Choose point-cloud file. Confirm source
units and choose a writable local index location. Zoom to All after indexing.
Use Open Existing Index next time; preserve the complete index folder.

**Mesh:** Import → Mesh → Import mesh component. Keep OBJ, MTL and textures
together. Check extent, scale and appearance. Keep the scan component separate
from the new wall geometry and avoid exploding the dense scan.

**Gaussian:** Import → Gaussian → Import into SU viewport, or open an existing
Gaussian index. Ordinary PLY point clouds and 3DGS PLY require different importers.

**Wall:** Verify a clean floor elevation, identify actual corners/openings,
enable fixed-plane tracing and close a wall footprint with thickness. Use Close
and Extrude Upward or Enter Height and Extrude Upward; the dialog takes metres.
Check the wall base and vertical direction. Native Push/Pull requires entering
the group containing the face. Slice height is not the wall-base elevation.

**Crop:** A 3D clip box bounds the reference; Esc retains it. A horizontal slice
changes visibility only. For polygon cropping, keep the camera fixed, click
vertices, Enter to apply, Backspace to undo a vertex and Esc to cancel. The mask
extends along the view direction; it is not a mesh Boolean operation.

## Save and acceptance checklist

Carry the SKP together with its matching “_点云数据” data directory. Do not rename
individual index files. The index format is shared with Windows. Temporary query
files use the Mac user cache. Chinese and spaced paths pass converter smoke tests.

Before customer deployment, verify inside SketchUp for Mac:

- Native arm64 SU/macOS versions, language switching and dimension input.
- Correct picking after Retina scaling and viewport resizing.
- Camera following and occlusion between native geometry and references.
- Face closure/upward extrusion, shape dimensions, crop and restore behavior.
- Save, exit, reopen, then move/copy the project to another directory and reopen.

Windows 0.10.0 testing previously exposed Gaussian restore error
`SUModelCreateOverlay:15`. This does not establish either success or failure on
Mac; the Mac SketchUp integration still needs direct verification.

## References

- [SketchUp C Overlay API](https://extensions.sketchup.com/developers/sketchup_c_api/sketchup/struct_s_u_model_ref.html)
- [Metal resource storage](https://developer.apple.com/documentation/metal/setting-resource-storage-modes)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
