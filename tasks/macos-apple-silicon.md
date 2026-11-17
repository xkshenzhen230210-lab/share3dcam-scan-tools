# Apple Silicon macOS port — 0.11.0-mac.1

Scope: M-series Macs only, native arm64 SketchUp 2024–2026. Preserve the existing
Chinese/English UI, formats, complete resident rendering, clipping, picking,
native geometry tools and project/index layout. Intel/Rosetta is out of scope.
Existing Windows binaries and the installed extension are not replaced.

## Implementation and verification

- [ ] Portable platform paths and subprocess launch; tests cover macOS cache,
  Chinese/spaced paths, unsupported architectures and executable validation.
- [ ] Metal renderer with the existing C ABI: full point buffers; Gaussian
  covariance, SH and alpha; native camera/depth and logical/physical picking;
  clipping, slice and persistent polygon masks. No preview/LOD replacement.
- [ ] arm64 macOS build of converter + dylib; package only matching binaries;
  test malformed/missing inputs and all exported symbols.
- [ ] Shared bilingual UI regression checks and format/converter tests.
- [ ] Native GPU tests on an Apple Silicon hosted runner if credentials allow.
- [ ] Chinese/English installation, use and limitations; SHA256 release manifest.
- [ ] Actual SketchUp-on-Mac installation/reopen/Retina/tool interaction check.

The last item needs a real licensed SketchUp Mac session. User has no Mac for
testing. Hosted compilation/GPU tests must never be described as SU acceptance.
Do not issue a customer-ready label or release binary unless its native build
and basic GPU tests pass. Unsigned local test packages remain clearly marked.

## Source contracts

- https://extensions.sketchup.com/developers/sketchup_c_api/sketchup/struct_s_u_model_ref.html
- https://extensions.sketchup.com/developers/sketchup_c_api/sketchup/struct_s_u_overlay_draw_frame_info.html
- https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
- https://developer.apple.com/documentation/metal/setting-resource-storage-modes
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners

Metal renders to engine-owned offscreen color, source-ID and depth targets;
SketchUp consumes CPU buffers through its public C Overlay API. Data buffers
use shared memory on Apple Silicon, checked against device limits. Rendering
still submits every original indexed point or Gaussian on each changed frame.
