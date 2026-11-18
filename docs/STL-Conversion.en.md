# SHARE3DCAM Scan Tools | STL conversion and export

Saier E-commerce Center · Windows 0.11.1 · SketchUp 2024–2026

Install the new RBZ via Extension Manager, restart SketchUp, and open SHARE3DCAM Scan Tools. Choose English at the top of the panel.

1. **Import STL into SketchUp:** Open Import → Mesh. Under “OBJ / STL input units and up axis”, match the source file. Printing files commonly use millimeters. Choose “Import mesh component”, select the STL, and verify a known dimension.
2. **Convert a GLB or OBJ file:** Expand “STL conversion and export” in the same card and choose STL output units (default: millimeters). Click “GLB / OBJ to STL” and select the source and destination. OBJ uses the selected input settings. GLB uses meters and Y up. Both are written as Z-up STL.
3. **Export native SketchUp geometry:** Exit group or component edit mode. Select the faces, groups, or components and click “Export selection”. Leave the scan mesh unselected if you only need the new geometry.

STL contains triangles without units, textures, colors or materials. Use the same units when reopening the file. Point clouds and Gaussian references must be modeled as geometry before they can be exported. Conversion does not close holes or repair non-manifold geometry; verify that a model is solid before printing.

When collecting project references, the new version prevents an index with a different unit, extent or tile layout from overwriting an existing project index. If a name conflicts, choose a different project name.

[SketchUp's STL guide](https://help.sketchup.com/en/sketchup/importing-and-exporting-stl-files-3d-printing)
