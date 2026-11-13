# SHARE3DCAM Scan Tools — English User Guide

**Version 0.10.0 · SHARE3DCAM · E-commerce Center**

[English overview](../README.en.md) | [中文首页](../README.md) | [Download 0.10.0](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/releases/tag/v0.10.0)

Use this guide with **English** selected at the top of the plugin panel. Bold interface labels below match the English plugin. Intended platform: Windows SketchUp 2024–2026; actual validation: SketchUp 2026 and RTX 4080 SUPER. This is a trial / prerelease.

## 1. Install and find the controls

1. Download the RBZ from the release page above.
2. In SketchUp's **Extension Manager**, choose **Install Extension**, select the RBZ, then restart SketchUp.
3. Open **Extensions → 赛尔点云绘图助手 / SHARE3DCAM Scan Tools**.
4. Click **English** next to **中文** at the top of the plugin panel.

The four tabs are **Import**, **View / Crop**, **Draw** and **Project**. Language changes preserve the current tab and unsubmitted dimensions and are remembered when the panel reopens. They do not rename files or modify geometry. Native SketchUp and Windows controls retain their own language settings.

## 2. Import a reference

Each SKP can have one active point-cloud or Gaussian reference. Meshes are added as native components. Choose the appropriate importer: a `.ply` extension alone does not tell you whether a file is an ordinary point cloud or a Gaussian model.

### Point clouds

1. In **Import**, set **Point cloud / Gaussian source units** to match the file: meters, millimeters, centimeters or feet.
2. Under **Point cloud**, click **Choose point cloud** and select a LAS, LAZ, PLY, XYZ, TXT or PTS file.
3. Choose a writable local folder with enough free space for the full index. Wait for the import to finish before drawing.
4. Go to **View / Crop → Zoom to all** to inspect the complete reference and check scale with **Draw → Measure two points**.

If an index already exists, use **Open existing index** under **Point cloud** and select the folder containing `cloud.json`. This avoids rebuilding the index. To troubleshoot a failed background import, try **Import options → Compatibility mode**, then retry.

### Gaussian splats

1. Set the source units as above.
2. Under **Gaussian splats**, choose **Import into SU viewport** and select a standard 3DGS PLY.
3. Choose an index location and wait until the reference is ready.
4. Use **Open existing index** in the Gaussian section for a previously built Gaussian index. Select the folder containing `cloud.json`.

The Gaussian remains a viewport reference. It is not a native face that can be pushed or pulled; create native geometry over it using the plugin's drawing tools. Snapping uses visible Gaussian centers, so verify floor levels at several nearby points.

### Meshes

1. For OBJ, expand **OBJ units, axis & textures** and set the OBJ units and up axis.
2. Click **Import mesh component** and choose a GLB or OBJ.
3. Keep the OBJ, MTL and texture files in their original relative arrangement. Check the imported component's scale, orientation and textures.

GLB / OBJ are supported; OSGB is not implemented. Chinese paths are not categorically unsupported: the backend has Chinese-path tests, but access rights, file locks or external texture references can still cause failures. When diagnosing a failed import, copy the complete dataset to a short, writable local path such as `E:/ScanData/Room01/`, preserving texture relationships, and retry. This is a diagnostic step rather than a mandatory English-only-path rule.

## 3. Align, navigate and crop

Keep the reference visible while you identify corners, openings and structural edges. Under **View / Crop**, use **Zoom to all**, **Top view** and **Show point cloud / Gaussian reference**. **Reference zoom (Z)** lets you scroll or drag vertically over a scan surface; press Esc to return. If a shortcut conflicts with your SketchUp setup, use the panel button.

Use **Move & align (m / degrees)** before drawing. The offsets and rotation move the scan reference; they do not move geometry you already drew. Recheck the drawing elevation after alignment changes.

### 3D clipping box

1. Click **3D clipping box** and drag the colored face handles to restrict the visible region.
2. Orbit the view to reach handles that are difficult to see.
3. Press Esc to finish editing and keep the crop.
4. Use **Clipping box coordinates (local m)** and **Apply clipping box** when you need numeric bounds. **Reset all crops** restores the crop range.

### Free polygon crop

1. Establish a clear view, then expand **Free crop**.
2. Choose **Keep inside** to retain the polygon region or **Remove inside** to remove it.
3. Click at least three distinct polygon corners in the viewport, without moving the camera during selection. Avoid crossed edges.
4. Press Enter to apply. Backspace removes the last corner; Esc cancels the unfinished selection.
5. Use **Undo last polygon** or **Reset free crop** as needed.

The polygon cuts through the scene along the current viewing direction. It is not a shallow brush: points behind the visible surface can also be affected. The resulting mask remains attached to the original points after you orbit. Both free crop and the clipping box preserve the source file.

### Horizontal slice

Enable **Enable horizontal slice**, set **Center elevation (m)** and **Thickness (m)**, then click **Apply slice**. Select a level that reveals continuous walls and useful openings, and inspect other heights when a single slice hides a feature. Slice elevation and drawing elevation are separate settings.

These scan crop controls apply to point clouds and Gaussians. Use native SketchUp section planes for mesh components. **Advanced: box statistics & export** is for ordinary point clouds; reset free crop before using box statistics or **Export cropped PLY**. This version does not export a free-cropped Gaussian or mesh.

## 4. Establish the drawing elevation

1. In **Draw**, click **Pick elevation**.
2. Point at a clean, visible floor surface. Confirm the red snap marker and click to read the elevation. Check several nearby positions before accepting it.
3. Read **Model Z** and **Source Z**, then click **Use as drawing elevation**.
4. Enable **Top-view planar tracing**. Check **Drawing elevation (m)** before tracing that floor.

Model Z is the local SketchUp elevation after import and alignment. Source Z refers to the source coordinate system. Neither value automatically establishes site ±0.000 or an absolute survey datum. Use a known site benchmark when that relationship matters.

Planar tracing places every traced vertex at the chosen elevation and switches tracing to a top parallel view. It prevents scan noise from making the footprint nonplanar. Use a separate verified elevation for another floor.

## 5. Trace wall footprints with the scan visible

1. Identify continuous wall faces and real corners in the visible scan. Ignore isolated points and surface noise. Check an oblique view if a top slice is ambiguous.
2. Choose **Snap trace / Create face**. Move over a visible scan point until the red marker appears; click to establish the start.
3. Trace the wall footprint, including its thickness. Use the left arrow to lock Y or the right arrow to lock X when appropriate. Type a length such as `3m` or `3000mm`, then press Enter to constrain the segment.
4. Right-click and choose **Close & create face**. A successful closed profile enters its group and starts native Push/Pull. If the profile is nonplanar or self-intersecting, correct it before extruding.
5. Finish the current group edit before starting the next scan profile. Use **Measure two points** to check wall lengths and openings; **Guide points → Add guide point** creates native guide points for subsequent native snapping.

Use straight walls and square corners when the scan supports them. Do not trace every noisy jog as a real architectural corner, and do not force a genuinely angled wall to be square. Resolve uncertain dimensions against additional scan views or site measurements.

## 6. Common drawing tools and exact dimensions

These controls are in **Draw → Common drawing tools**. With an active point-cloud/Gaussian reference, the first corner or center must snap to a visible scan point. Subsequent points can lie on the established horizontal plane, including across scan gaps.

| Tool | Click sequence | Dimension input, followed by Enter |
|---|---|---|
| **Rectangle** | First corner → opposite corner | `3m,200mm`; positive dimensions along model X/Y; mouse direction determines the quadrant |
| **Circle** | Center → radius point | `500mm` is a radius, producing a 1 m diameter |
| **Regular polygon** | Center → direction of a vertex | Center-to-vertex radius, such as `500mm`; default is six sides |
| **Center-point arc** | Center → start/radius → counterclockwise end direction | Radius such as `1m` at the second step, then an angle such as `90` at the third; angle must be greater than 0 and less than 360 |

Type dimensions while the tool is active in the viewport; do not click the SketchUp Measurements box first. Plugin panel coordinate fields use meters, while tool length input accepts explicit units. In **Dimensions & curve detail**, set **Circle / full-circle segments** to 12–360 (default 48) and **Polygon sides** to 3–64 (default 6), then start the next shape. Existing geometry is unchanged.

These four scan profiles stay horizontal: they use the chosen drawing elevation when planar tracing is enabled, or the first snapped point's Z otherwise. Esc clears the unfinished preview; right-click offers restart or finish. Completed rectangles, circles and polygons are native profile groups with faces. An arc remains open until you add closing edges and form a face.

With no active scan reference, the four buttons invoke native SketchUp tools and use native mesh inference and dimension prompts. **Native Line** and **Native Offset** operate on native geometry; they do not directly snap to Gaussian splats or point clouds.

## 7. Extrude in place and add architectural details

For a completed horizontal profile group, select the group and use either method:

- **Native Push/Pull (P):** enters the profile group and starts SketchUp's Push/Pull. Click the face, move in the intended direction, type a height with units such as `2.8m`, and press Enter. Inspect from an oblique view to confirm the direction.
- **Extrude upward by height:** enter the height in meters in the dialog, such as `2.8`. This extrudes upward along the global blue axis and creates a closed solid from a valid horizontal profile.

The dimensions above are examples, not measurements of your building. Establish actual heights and thicknesses from the reference or verified drawings. Exit group editing before starting the next scan profile. If the Gaussian obscures a coincident base face, lower **View / Crop → Reference opacity** while drawing.

For doors and windows, keep the reference visible, measure the opening position and height, enter the wall's group, draw the opening on the correct native wall face and use native Push/Pull through the wall thickness. Confirm the opening against the scan from both sides. The plugin does not identify openings automatically.

For columns, beams and slabs, use the same model and reference. Draw a column footprint at its verified base elevation and extrude vertically. Create beam and slab profiles at their measured elevations using native SketchUp editing; the scan shape tools create horizontal profiles. Check every room in top, oblique and side views: wall bases, slab coverage, vertical columns and beam-to-column joints. Temporarily hiding the scan and top slab helps inspect connections, but restore the scan to check alignment.

## 8. Save, reopen and hand off

1. Open **Project** and click **Save & collect project** for a point-cloud/Gaussian project. Without a scan reference the button reads **Save SKP as…**.
2. Select the SKP destination and allow collection to finish.
3. Keep the SKP and its matching scan-data folder together when copying or delivering the project. Native drawn geometry and imported mesh components are stored in the SKP; scan references need their collected data folder.
4. Reopen the saved SKP and verify the reference, geometry and alignment before delivery. Use **Project → Restore reference → Reload saved index** if needed. If the data folder has moved, use the appropriate **Open existing index** importer to locate it again and verify placement.

Test the copied project from its delivery location, rather than assuming a working source folder proves that the handoff is complete.

## 9. Troubleshooting and practical limits

| Symptom | Checks and action |
|---|---|
| Wrong scale or orientation | Verify source units and OBJ up axis. Measure a known distance. Finish alignment before tracing. |
| Reference seems empty or disappears nearby | Use **Zoom to all**, check reference visibility, crops and slice settings, then try **Reference zoom (Z)** over a visible surface. |
| Mesh has no color | Check SketchUp's textured face display and the OBJ/MTL/texture relationship. Inspect the source before assuming color data was imported. |
| A traced face cannot be pulled | Confirm that a closed planar native face exists. Select its profile group before using **Native Push/Pull (P)**. Check group-edit context; an open arc or the Gaussian reference itself is not a face. |
| Scan obscures new geometry | Lower Gaussian **Reference opacity**; verify the drawing elevation rather than moving geometry arbitrarily above the scan. |
| Import reports permission denied | Use a writable local index destination, check file/folder permissions and locks, and try **Compatibility mode**. Retain the source dataset while diagnosing. |
| Import or navigation is slow | Reuse an existing index and check available RAM/VRAM and storage speed. Full-resolution display still depends on hardware; cropping is a display operation and does not promise that the full index will no longer consume memory. |
| A screenshot export omits the scan | Scan overlays are not included in normal SU 2D image export. Capture the actual viewport. |

Current reference limits are 100 million ordinary points or 20 million standard Gaussians per dataset, subject to hardware capacity. Compressed/nonstandard Gaussian PLY and OSGB are not supported. Automatic building reconstruction is not implemented.

See the [English overview](../README.en.md#current-limitations) for known stability issues and test coverage. To report a problem, include SketchUp and plugin versions, GPU, format and reproduction steps in [GitHub Issues](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/issues). Share only data you have permission to disclose.
