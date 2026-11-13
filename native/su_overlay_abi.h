#pragma once
#include <cstdint>
// Minimal binding to the public SketchUp C Overlay API (introduced in 2024).
// Field order/types mirror the public API references linked in docs/构建与架构.md.
// No private SU graphics context or undocumented renderer objects are accessed.
struct SURef { void* ptr; };
struct Vec3 { double x,y,z; };
struct Bounds { Vec3 min,max; };
struct BeginFrame {
 uint32_t version; Vec3 position,target,up;
 double aspect_ratio,near_clipping_distance,far_clipping_distance;
 double projection_matrix[16],view_matrix[16];
 double viewport_width,viewport_height,fov,height;
 bool is_perspective; void* reserved;
};
struct FrameMemory { void* ptr; uint32_t row_pitch,size; };
struct DrawFrame {
 uint32_t version; double blending_factor;
 FrameMemory color,depth; void* reserved;
};
struct CreateOverlay {
 uint32_t version; void* user_data;
 const char *id,*name,*desc,*source;
 uint8_t image_format,image_orientation;
 void (*start)(SURef,void*); void (*stop)(SURef,void*);
 Bounds (*get_extents)(SURef,void*);
 void (*begin_frame)(SURef,const BeginFrame*,void*);
 void (*draw_frame)(SURef,DrawFrame*,void*);
 void (*end_frame)(SURef,void*);
};
static_assert(sizeof(BeginFrame)==408 && sizeof(DrawFrame)==56 && sizeof(CreateOverlay)==104);
