#pragma once

// Project the 3D covariance using the local derivative of the exact SketchUp
// camera matrix. The Cholesky factor maps the unit Gaussian to a screen quad.
static const char* gaussian_shader = R"HLSL(
cbuffer Camera : register(b0) {
 float4 eye,right,up,forward,projection,transform,cliplo,cliphi,misc,height_range;
 row_major float4x4 mvp;
}
Buffer<float> harmonics : register(t0);
Buffer<uint> cropMask : register(t2);
struct Input {
 float3 mean : POSITION;
 float3 cov0 : COVARIANCE0;
 float3 cov1 : COVARIANCE1;
 float4 color : COLOR;
 uint id : SV_VertexID;
};
struct Projected {
 float4 pos : SV_POSITION;
 float3 ellipse : ELLIPSE;
 float4 color : COLOR;
 uint id : SOURCEID;
};
struct Pixel {
 float4 pos : SV_POSITION;
 float2 uv : TEXCOORD;
 nointerpolation float4 color : COLOR;
 nointerpolation uint id : SOURCEID;
};
float3 coefficient(uint start, uint count, uint i) {
 return float3(harmonics[start+i], harmonics[start+count+i], harmonics[start+2*count+i]);
}
float3 evaluateColor(Input i) {
 float3 color = 0.5 + 0.2820947918 * i.color.rgb;
 uint count = (uint)misc.w;
 if (count > 0) {
  float3 direction = misc.y > 0 ? i.mean - eye.xyz : forward.xyz;
  direction *= rsqrt(max(dot(direction,direction),1e-20));
  float x=direction.x, y=direction.y, z=direction.z;
  float xx=x*x, yy=y*y, zz=z*z;
  uint start=i.id*count*3;
  color += 0.4886025119 * (-y*coefficient(start,count,0) + z*coefficient(start,count,1) - x*coefficient(start,count,2));
  if (count >= 8) {
   color += 1.0925484306*x*y*coefficient(start,count,3) - 1.0925484306*y*z*coefficient(start,count,4)
    + 0.3153915653*(2*zz-xx-yy)*coefficient(start,count,5) - 1.0925484306*x*z*coefficient(start,count,6)
    + 0.5462742153*(xx-yy)*coefficient(start,count,7);
  }
  if (count >= 15) {
   color += -0.5900435899*y*(3*xx-yy)*coefficient(start,count,8) + 2.8906114426*x*y*z*coefficient(start,count,9)
    - 0.4570457995*y*(4*zz-xx-yy)*coefficient(start,count,10) + 0.3731763326*z*(2*zz-3*xx-3*yy)*coefficient(start,count,11)
    - 0.4570457995*x*(4*zz-xx-yy)*coefficient(start,count,12) + 1.4453057213*z*(xx-yy)*coefficient(start,count,13)
    - 0.5900435899*x*(xx-3*yy)*coefficient(start,count,14);
  }
 }
 return saturate(color);
}
Projected projectSplat(Input i) {
 Projected o = (Projected)0;
 if(height_range.z>.5 && cropMask[i.id]==0)return o;
 float3 p = i.mean;
 float3 world = float3(p.x*transform.x-p.y*transform.y, p.x*transform.y+p.y*transform.x, p.z);
 world += float3(cliplo.w,cliphi.w,misc.x);
 if (any(world < cliplo.xyz) || any(world > cliphi.xyz) || i.color.a < 0.00392) return o;

 float4 pos = mul(mvp,float4(p,1));
 if (pos.w <= 0 || pos.z < -pos.w || pos.z > pos.w) return o;
 // The perspective derivative is only a local approximation. Far off-axis
 // centers near the eye plane otherwise acquire enormous footprints that
 // cover the entire room while zooming. Bound the derivative to an expanded
 // viewport, leaving the actual center and depth unchanged for clipping,
 // depth composition and picking. Orthographic derivatives are unchanged
 // because mvp[3].xyz is zero.
 float2 derivativeCenter = clamp(pos.xy/pos.w, -1.3, 1.3);
 float3 dx = (mvp[0].xyz - derivativeCenter.x*mvp[3].xyz) * (right.w / (2*pos.w));
 float3 dy = (mvp[1].xyz - derivativeCenter.y*mvp[3].xyz) * (up.w / (2*pos.w));
 float3x3 covariance = float3x3(i.cov0.x,i.cov0.y,i.cov0.z, i.cov0.y,i.cov1.x,i.cov1.y, i.cov0.z,i.cov1.y,i.cov1.z);
 float xx = dot(dx,mul(covariance,dx));
 float yy = dot(dy,mul(covariance,dy));
 float xy = dot(dx,mul(covariance,dy));
 if (!all(isfinite(float3(xx,yy,xy)))) return o;
 // A small pixel footprint prevents aliasing in the far field.
 const float pixelVariance = 0.3;
 float spread = sqrt(max(0,xx*yy-xy*xy) / max(1e-12,(xx+pixelVariance)*(yy+pixelVariance)-xy*xy));
 xx += pixelVariance;
 yy += pixelVariance;
 float a = sqrt(max(xx,pixelVariance));
 float b = xy/a;
 float d = sqrt(max(yy-b*b,pixelVariance));
 float2 extent = 3.3 * float2(a, abs(b)+d) / float2(right.w*0.5,up.w*0.5);
 if (any(abs(pos.xy/pos.w) > 1+extent)) return o;

 o.pos = float4(pos.xy,(pos.z+pos.w)*0.5,pos.w);
 o.ellipse = float3(a,b,d) / float3(right.w*0.5,up.w*0.5,up.w*0.5) * pos.w;
 o.color = float4(evaluateColor(i), i.color.a * spread);
 if (misc.z == 1) o.color.rgb = float3(.7,.72,.74);
 if (misc.z == 2) {
  float z = saturate((p.z-height_range.x)/max(.001,height_range.y-height_range.x));
  o.color.rgb = float3(z,1-abs(2*z-1),1-z);
 }
 o.id = i.id+1;
 return o;
}

[maxvertexcount(4)]
void quad(point Projected inputs[1], inout TriangleStream<Pixel> stream) {
 Projected i=inputs[0];
 if (i.color.a < 0.00392) return;
 [unroll] for(uint index=0;index<4;++index) {
  Pixel o;
  o.uv = float2((index&1)?3.3:-3.3,(index&2)?3.3:-3.3);
  o.pos=i.pos;
  o.pos.xy += float2(i.ellipse.x*o.uv.x,i.ellipse.y*o.uv.x+i.ellipse.z*o.uv.y);
  o.color=i.color;
  o.id=i.id;
  stream.Append(o);
 }
}

struct Output {
 float4 color : SV_Target0;
 uint id : SV_Target1;
 float depth : SV_Target2;
};
Output blendSplat(Pixel i) {
 float alpha = min(0.99,i.color.a*exp(-0.5*dot(i.uv,i.uv)));
 clip(alpha - 0.00392);
 Output o;
 o.color=float4(i.color.rgb*alpha,alpha);
 o.id=i.id;
 o.depth=i.pos.z;
 return o;
}

Texture2D<float4> accumulated : register(t1);
float4 fullScreen(uint vertex : SV_VertexID) : SV_POSITION {
 return float4(vertex == 2 ? 3 : -1, vertex == 1 ? 3 : -1, 0, 1);
}
float4 resolveColor(float4 pos : SV_POSITION) : SV_TARGET {
 float4 rgba = accumulated.Load(int3(int2(pos.xy),0));
 return rgba.a > 0.001 ? float4(rgba.rgb/rgba.a,rgba.a*height_range.w) : 0;
}
)HLSL";
