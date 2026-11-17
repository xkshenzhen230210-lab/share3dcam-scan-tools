#include <metal_stdlib>
using namespace metal;
struct Params {
 float4 eye,right,up,forward,projection,transform,cliplo,cliphi,misc,height_range;
 float4 row0,row1,row2,row3;
};
struct Point { packed_float3 xyz; uint rgba,index; };
struct Gaussian { packed_float3 mean; float c[6]; packed_float3 dc; float alpha; };
struct Pixel {
 float4 pos [[position]];
 float point_size [[point_size]];
 float2 uv;
 float4 color [[flat]];
 uint id [[flat]];
};
struct Output { float4 color [[color(0)]]; uint id [[color(1)]]; float depth [[color(2)]]; };
float4 project(float3 x,constant Params& p) {
 float4 q=float4(x,1);return float4(dot(p.row0,q),dot(p.row1,q),dot(p.row2,q),dot(p.row3,q));
}
bool allowed(float3 x,uint id,constant Params& p,device const uint* mask) {
 float3 w=float3(x.x*p.transform.x-x.y*p.transform.y,x.x*p.transform.y+x.y*p.transform.x,x.z);
 w+=float3(p.cliplo.w,p.cliphi.w,p.misc.x);
 return all(w>=p.cliplo.xyz)&&all(w<=p.cliphi.xyz)&&(p.height_range.z<.5||mask[id]!=0);
}
float3 displayColor(float3 color,float z,constant Params& p) {
 if(p.misc.z==1)return float3(.7,.72,.74);
 if(p.misc.z==2){float h=saturate((z-p.height_range.x)/max(.001,p.height_range.y-p.height_range.x));return float3(h,1-abs(2*h-1),1-h);}
 return color;
}
vertex Pixel pointVertex(uint id [[vertex_id]],device const Point* points [[buffer(0)]],constant Params& p [[buffer(1)]],device const uint* mask [[buffer(2)]]) {
 Point i=points[id];Pixel o;o.pos=project(float3(i.xyz),p);o.point_size=1;o.uv=0;o.id=id+1;
 if(!allowed(float3(i.xyz),id,p,mask)||o.pos.w<=0)o.pos=float4(2,2,2,1);
 o.pos.z=(o.pos.z+o.pos.w)*.5;
 float3 color=float3(i.rgba&255,(i.rgba>>8)&255,(i.rgba>>16)&255)/255.;
 o.color=float4(displayColor(color,i.xyz.z,p),1);return o;
}
fragment Output pointFragment(Pixel i [[stage_in]]) { Output o;o.color=i.color;o.id=i.id;o.depth=i.pos.z;return o; }

float3 coefficient(device const half* sh,uint start,uint count,uint i){return float3(sh[start+i],sh[start+count+i],sh[start+2*count+i]);}
float3 evaluateColor(Gaussian g,uint id,constant Params& p,device const half* sh) {
 float3 color=.5+.2820947918*float3(g.dc);uint count=uint(p.misc.w);
 if(count>0){
  float3 d=p.misc.y>0?float3(g.mean)-p.eye.xyz:p.forward.xyz;d*=rsqrt(max(dot(d,d),1e-20f));
  float x=d.x,y=d.y,z=d.z,xx=x*x,yy=y*y,zz=z*z;uint start=id*count*3;
  color+=.4886025119*(-y*coefficient(sh,start,count,0)+z*coefficient(sh,start,count,1)-x*coefficient(sh,start,count,2));
  if(count>=8)color+=1.0925484306*x*y*coefficient(sh,start,count,3)-1.0925484306*y*z*coefficient(sh,start,count,4)+.3153915653*(2*zz-xx-yy)*coefficient(sh,start,count,5)-1.0925484306*x*z*coefficient(sh,start,count,6)+.5462742153*(xx-yy)*coefficient(sh,start,count,7);
  if(count>=15)color+=-.5900435899*y*(3*xx-yy)*coefficient(sh,start,count,8)+2.8906114426*x*y*z*coefficient(sh,start,count,9)-.4570457995*y*(4*zz-xx-yy)*coefficient(sh,start,count,10)+.3731763326*z*(2*zz-3*xx-3*yy)*coefficient(sh,start,count,11)-.4570457995*x*(4*zz-xx-yy)*coefficient(sh,start,count,12)+1.4453057213*z*(xx-yy)*coefficient(sh,start,count,13)-.5900435899*x*(xx-3*yy)*coefficient(sh,start,count,14);
 }
 return saturate(color);
}
vertex Pixel splatVertex(uint vertexIndex [[vertex_id]],uint instance [[instance_id]],device const Gaussian* gs [[buffer(0)]],constant Params& p [[buffer(1)]],device const uint* mask [[buffer(2)]],device const uint* order [[buffer(3)]],device const half* sh [[buffer(4)]]) {
 uint id=order[instance];Gaussian g=gs[id];Pixel o;o.pos=float4(2,2,2,1);o.point_size=1;o.uv=0;o.color=0;o.id=id+1;
 if(!allowed(float3(g.mean),id,p,mask)||g.alpha<.00392)return o;
 float4 pos=project(float3(g.mean),p);if(pos.w<=0||pos.z< -pos.w||pos.z>pos.w)return o;
 float2 center=clamp(pos.xy/pos.w,-1.3f,1.3f);
 float3 dx=(p.row0.xyz-center.x*p.row3.xyz)*(p.right.w/(2*pos.w));
 float3 dy=(p.row1.xyz-center.y*p.row3.xyz)*(p.up.w/(2*pos.w));
 float3x3 cov=float3x3(float3(g.c[0],g.c[1],g.c[2]),float3(g.c[1],g.c[3],g.c[4]),float3(g.c[2],g.c[4],g.c[5]));
 float xx=dot(dx,cov*dx),yy=dot(dy,cov*dy),xy=dot(dx,cov*dy);if(!all(isfinite(float3(xx,yy,xy))))return o;
 float spread=sqrt(max(0.f,xx*yy-xy*xy)/max(1e-12f,(xx+.3)*(yy+.3)-xy*xy));
 xx+=.3;yy+=.3;float a=sqrt(max(xx,.3f)),b=xy/a,d=sqrt(max(yy-b*b,.3f));
 float2 extent=3.3*float2(a,abs(b)+d)/float2(p.right.w*.5,p.up.w*.5);
 if(any(abs(pos.xy/pos.w)>1+extent))return o;
 const uint corners[6]={0,1,2,2,1,3};uint corner=corners[vertexIndex];o.uv=float2((corner&1)?3.3:-3.3,(corner&2)?3.3:-3.3);
 pos.xy+=float2(a*o.uv.x/(p.right.w*.5),(b*o.uv.x+d*o.uv.y)/(p.up.w*.5))*pos.w;
 pos.z=(pos.z+pos.w)*.5;o.pos=pos;o.color=float4(displayColor(evaluateColor(g,id,p,sh),g.mean.z,p),g.alpha*spread);return o;
}
fragment Output splatFragment(Pixel i [[stage_in]]) {
 float alpha=min(.99f,i.color.a*exp(-.5*dot(i.uv,i.uv)));if(alpha<.00392)discard_fragment();
 Output o;o.color=float4(i.color.rgb*alpha,alpha);o.id=i.id;o.depth=i.pos.z;return o;
}
kernel void resolveColor(texture2d<float,access::read> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],constant float& opacity [[buffer(0)]],uint2 xy [[thread_position_in_grid]]) {
 if(xy.x>=output.get_width()||xy.y>=output.get_height())return;
 float4 c=input.read(xy);output.write(c.a>.001?float4(c.rgb/c.a,c.a*opacity):float4(0),xy);
}
