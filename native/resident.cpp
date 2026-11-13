#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <atomic>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "su_overlay_abi.h"
using Microsoft::WRL::ComPtr;
using Clock=std::chrono::steady_clock;
static double seconds(Clock::time_point t) { return std::chrono::duration<double>(Clock::now()-t).count(); }
static void hr(HRESULT r,const char* s) { if(FAILED(r)) { std::ostringstream o;o<<s<<": 0x"<<std::hex<<uint32_t(r);throw std::runtime_error(o.str()); } }
static Vec3 sub(Vec3 a,Vec3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
static Vec3 cross(Vec3 a,Vec3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static double dot(Vec3 a,Vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static Vec3 unit(Vec3 a){double n=std::sqrt(dot(a,a));if(n<1e-12)throw std::runtime_error("invalid camera");return {a.x/n,a.y/n,a.z/n};}
#pragma pack(push,1)
struct Record { double xyz[3];uint16_t rgb[3];uint64_t id; };
#pragma pack(pop)
static_assert(sizeof(Record)==38);
struct Source {double xyz[3];uint64_t id;};
struct Vertex {float xyz[3];uint32_t rgba,index;};
struct Options {double x,y,z,angle;double clip[6];double slice_z,slice_width;uint32_t flags,color;};
static_assert(sizeof(Options)==104);
#include "gaussian_gpu.h"
struct Params {
 float eye[4],right[4],up[4],forward[4],projection[4],transform[4],cliplo[4],cliphi[4],misc[4],height_range[4],mvp[16];
};
static const char* shader=R"(
cbuffer P:register(b0) {float4 eye,right,up,forward,projection,transform,cliplo,cliphi,misc,height_range;row_major float4x4 mvp;}
Buffer<uint> cropMask:register(t2);
struct In {float3 xyz:POSITION;float4 color:COLOR;uint index:INDEX;};
struct V {float4 pos:SV_POSITION;float4 color:COLOR;nointerpolation uint index:INDEX;float viewz:DEPTH;float allowed:ALLOW;};
V vs(In i) {
 V o;float3 p=i.xyz;
 float3 w=float3(p.x*transform.x-p.y*transform.y,p.x*transform.y+p.y*transform.x,p.z);
 w+=float3(cliplo.w,cliphi.w,misc.x);
 o.allowed=all(w>=cliplo.xyz)&&all(w<=cliphi.xyz);
 if(height_range.z>.5 && cropMask[i.index]==0)o.allowed=0;
 o.pos=mul(mvp,float4(p,1));o.pos.z=(o.pos.z+o.pos.w)*.5;o.viewz=o.pos.w;
 if(o.pos.w<=0||o.allowed<.5)o.pos=float4(2,2,2,1);
 o.color=i.color;o.index=i.index+1;
 if(misc.z==1)o.color=float4(.7,.72,.74,1);
 if(misc.z==2){float h=saturate((p.z-height_range.x)/max(.001,height_range.y-height_range.x));o.color=float4(h,1-abs(2*h-1),1-h,1);}
 return o;
}
struct Out {float4 color:SV_Target0;uint index:SV_Target1;float depth:SV_Target2;};
// Validated against real SU viewport screenshots, with native faces both in
// front of and behind the cloud. View.write_image omits C overlays and must
// not be used to infer the compositor's depth convention.
Out ps(V i) {Out o;o.color=i.color;o.index=i.index;o.depth=i.pos.z;return o;}
)";
struct Tile {std::string path;uint64_t count;};
struct Engine {
 std::vector<Tile> tiles;std::vector<Source> source;
 std::string gaussian_path, harmonic_path;
 uint32_t harmonic_count=0;
 std::unique_ptr<GaussianGpu> gaussian;
 std::atomic<int> state{0};std::atomic<uint64_t> loaded{0};std::atomic<bool> cancel{false};std::thread loader;
 std::mutex mutex;Options options{};std::string error,device_name,stats_json;uint64_t count=0,frames=0,uploads=0,submitted=0,visible=0;
 Bounds bounds{};SURef model{},overlay{};BeginFrame camera{};std::array<double,16> source_projection{};
 double frame_ms=0,load_seconds=0,gaussian_opacity=.65;bool frame_valid=false;uint32_t width=0,height=0;
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
 ComPtr<ID3D11Buffer> vertices,constant;ComPtr<ID3D11VertexShader> vs;ComPtr<ID3D11PixelShader> ps;
 ComPtr<ID3D11InputLayout> layout;ComPtr<ID3D11DepthStencilState> depth_state;ComPtr<ID3D11RasterizerState> raster;
 std::array<ComPtr<ID3D11Texture2D>,3> targets,staging;std::array<ComPtr<ID3D11RenderTargetView>,3> rtvs;
 ComPtr<ID3D11Texture2D> depth_tex;ComPtr<ID3D11DepthStencilView> dsv;
 std::vector<uint32_t> crop_mask;ComPtr<ID3D11Buffer> crop_buffer;ComPtr<ID3D11ShaderResourceView> crop_view;
 std::vector<uint32_t> colors,ids;std::vector<float> depths;
 Engine(){options.flags=4;options.slice_width=.1;}
 ~Engine(){cancel=true;if(loader.joinable())loader.join();}
 void fail(const std::exception& e){std::lock_guard<std::mutex> lock(mutex);error=e.what();state=-1;frame_valid=false;}
 void init_device(){
  ComPtr<IDXGIFactory1> factory;hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)),"DXGI factory");
  ComPtr<IDXGIAdapter1> best;SIZE_T memory=0;
  for(UINT i=0;;++i){ComPtr<IDXGIAdapter1> a;if(factory->EnumAdapters1(i,&a)==DXGI_ERROR_NOT_FOUND)break;DXGI_ADAPTER_DESC1 d{};a->GetDesc1(&d);
   if(!(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)&&(!best||d.DedicatedVideoMemory>memory)){best=a;memory=d.DedicatedVideoMemory;}}
  if(!best)throw std::runtime_error("No hardware Direct3D GPU");
  DXGI_ADAPTER_DESC1 desc{};best->GetDesc1(&desc);char name[256]{};WideCharToMultiByte(CP_UTF8,0,desc.Description,-1,name,256,nullptr,nullptr);
  {std::lock_guard<std::mutex> lock(mutex);device_name=name;}
  D3D_FEATURE_LEVEL level;D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_0};
  hr(D3D11CreateDevice(best.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,levels,1,D3D11_SDK_VERSION,&device,&level,&context),"D3D11 hardware device");
  ComPtr<ID3DBlob> vb,pb,err;
  HRESULT result=D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&vb,&err);
  if(FAILED(result))throw std::runtime_error(err?static_cast<char*>(err->GetBufferPointer()):"vertex shader compile");
  hr(D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&pb,&err),"pixel shader");
  hr(device->CreateVertexShader(vb->GetBufferPointer(),vb->GetBufferSize(),nullptr,&vs),"vertex shader create");
  hr(device->CreatePixelShader(pb->GetBufferPointer(),pb->GetBufferSize(),nullptr,&ps),"pixel shader create");
  D3D11_INPUT_ELEMENT_DESC elements[]={{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},{"COLOR",0,DXGI_FORMAT_R8G8B8A8_UNORM,0,12,D3D11_INPUT_PER_VERTEX_DATA,0},{"INDEX",0,DXGI_FORMAT_R32_UINT,0,16,D3D11_INPUT_PER_VERTEX_DATA,0}};
  hr(device->CreateInputLayout(elements,3,vb->GetBufferPointer(),vb->GetBufferSize(),&layout),"input layout");
  D3D11_BUFFER_DESC cb{};cb.ByteWidth=sizeof(Params);cb.Usage=D3D11_USAGE_DEFAULT;cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
  hr(device->CreateBuffer(&cb,nullptr,&constant),"camera buffer");
  D3D11_DEPTH_STENCIL_DESC ds{};ds.DepthEnable=true;ds.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ALL;ds.DepthFunc=D3D11_COMPARISON_LESS;
  hr(device->CreateDepthStencilState(&ds,&depth_state),"depth state");
  D3D11_RASTERIZER_DESC rs{};rs.FillMode=D3D11_FILL_SOLID;rs.CullMode=D3D11_CULL_NONE;rs.DepthClipEnable=true;
  hr(device->CreateRasterizerState(&rs,&raster),"raster state");
 }
 void load(uint32_t divisor){
  auto started=Clock::now();try{
   if(!count||count>100000000)throw std::runtime_error("Invalid resident point count (1..100 million)");
   init_device();source.resize(size_t(count));
   bounds={{1e300,1e300,1e300},{-1e300,-1e300,-1e300}};
   if (!gaussian_path.empty()) {
    load_gaussians();
    std::lock_guard<std::mutex> lock(mutex);
    uploads=1; load_seconds=seconds(started); state=2;
    return;
   }
   std::vector<Vertex> data(static_cast<size_t>(count));uint64_t offset=0;
   for(auto& t:tiles){if(cancel)return;
    std::ifstream in(std::filesystem::u8path(t.path),std::ios::binary|std::ios::ate);
    if(!in||uint64_t(in.tellg())!=t.count*sizeof(Record))throw std::runtime_error("Incomplete index tile");in.seekg(0);
    std::vector<Record> rows(size_t(t.count));in.read(reinterpret_cast<char*>(rows.data()),std::streamsize(rows.size()*sizeof(Record)));
    if(!in)throw std::runtime_error("Index read failed");
    for(auto& r:rows){auto& s=source[size_t(offset)];auto& v=data[size_t(offset)];
     for(int k=0;k<3;k++){if(!std::isfinite(r.xyz[k]))throw std::runtime_error("Non-finite source point");s.xyz[k]=r.xyz[k];v.xyz[k]=float(r.xyz[k]);}
     s.id=r.id;v.index=uint32_t(offset);v.rgba=0xff000000;
     for(int k=0;k<3;k++)v.rgba|=uint32_t(std::min(255u,uint32_t(std::lround(double(r.rgb[k])/std::max(1u,divisor)))))<<(8*k);
     bounds.min.x=std::min(bounds.min.x,r.xyz[0]);bounds.min.y=std::min(bounds.min.y,r.xyz[1]);bounds.min.z=std::min(bounds.min.z,r.xyz[2]);
     bounds.max.x=std::max(bounds.max.x,r.xyz[0]);bounds.max.y=std::max(bounds.max.y,r.xyz[1]);bounds.max.z=std::max(bounds.max.z,r.xyz[2]);offset++;
    }loaded=offset;
   }
   if(offset!=count)throw std::runtime_error("Index count mismatch");
   D3D11_BUFFER_DESC b{};b.ByteWidth=UINT(count*sizeof(Vertex));b.Usage=D3D11_USAGE_IMMUTABLE;b.BindFlags=D3D11_BIND_VERTEX_BUFFER;
   D3D11_SUBRESOURCE_DATA initial{};initial.pSysMem=data.data();hr(device->CreateBuffer(&b,&initial,&vertices),"full resident vertex buffer");
   {std::lock_guard<std::mutex> lock(mutex);uploads=1;load_seconds=seconds(started);state=2;}
  }catch(const std::exception& e){fail(e);}
 }
 void load_gaussians(){
  std::ifstream input(std::filesystem::u8path(gaussian_path),std::ios::binary|std::ios::ate);
  if(!input||uint64_t(input.tellg())!=count*sizeof(GaussianRecord)) throw std::runtime_error("Incomplete Gaussian cache");
  input.seekg(0);
  std::vector<GaussianVertex> vertices_data(static_cast<size_t>(count));
  std::vector<GaussianRecord> block(65536);
  for(size_t start=0;start<count;start+=block.size()) {
   if(cancel) return;
   size_t size=std::min<size_t>(block.size(),count-start);
   if(!input.read(reinterpret_cast<char*>(block.data()),size*sizeof(GaussianRecord))) throw std::runtime_error("Gaussian cache read failed");
   for(size_t i=0;i<size;++i) {
    auto& row=block[i]; auto& src=source[start+i]; auto& vertex=vertices_data[start+i];
    for(int k=0;k<3;++k) {
     if(!std::isfinite(row.mean[k])||std::abs(row.mean[k])>1e7||!std::isfinite(row.dc[k])) throw std::runtime_error("Invalid Gaussian mean or color");
     vertex.mean[k]=float(row.mean[k]); src.xyz[k]=row.mean[k]; vertex.dc[k]=row.dc[k];
    }
    if(!std::isfinite(row.alpha)||row.alpha<0||row.alpha>1||!std::all_of(row.covariance,row.covariance+6,[](float x){return std::isfinite(x);}))
     throw std::runtime_error("Invalid Gaussian covariance or opacity");
    src.id=start+i; vertex.alpha=row.alpha;
    std::copy(row.covariance,row.covariance+6,vertex.covariance);
    bounds.min={std::min(bounds.min.x,row.mean[0]),std::min(bounds.min.y,row.mean[1]),std::min(bounds.min.z,row.mean[2])};
    bounds.max={std::max(bounds.max.x,row.mean[0]),std::max(bounds.max.y,row.mean[1]),std::max(bounds.max.z,row.mean[2])};
   }
   loaded=start+size;
  }
  D3D11_BUFFER_DESC data{};
  data.ByteWidth=UINT(count*sizeof(GaussianVertex)); data.Usage=D3D11_USAGE_IMMUTABLE; data.BindFlags=D3D11_BIND_VERTEX_BUFFER;
  D3D11_SUBRESOURCE_DATA initial{}; initial.pSysMem=vertices_data.data();
  hr(device->CreateBuffer(&data,&initial,&vertices),"Gaussian resident buffer");
  std::vector<GaussianVertex>().swap(vertices_data);
  std::vector<uint16_t> harmonics;
  if(harmonic_count){
   std::ifstream sh(std::filesystem::u8path(harmonic_path),std::ios::binary|std::ios::ate);
   size_t size=size_t(count)*harmonic_count;
   if(!sh||uint64_t(sh.tellg())!=size*sizeof(uint16_t)) throw std::runtime_error("Incomplete Gaussian harmonics");
   harmonics.resize(size); sh.seekg(0);
   if(!sh.read(reinterpret_cast<char*>(harmonics.data()),size*sizeof(uint16_t))) throw std::runtime_error("Gaussian harmonics read failed");
  }
  gaussian=std::make_unique<GaussianGpu>();
  gaussian->initialize(device.Get(),static_cast<uint32_t>(count),harmonics);
 }
 void resize(uint32_t w,uint32_t h){
  if(w==width&&h==height)return;
  if(!w||!h||uint64_t(w)*h>67108864)throw std::runtime_error("Invalid viewport dimensions");
  context->OMSetRenderTargets(0,nullptr,nullptr);
  for(int i=0;i<3;i++){targets[i].Reset();staging[i].Reset();rtvs[i].Reset();}
  depth_tex.Reset();dsv.Reset();frame_valid=false;width=w;height=h;colors.resize(size_t(w)*h);ids.resize(size_t(w)*h);depths.resize(size_t(w)*h);
  for(int i=0;i<3;i++){
   D3D11_TEXTURE2D_DESC t{};t.Width=w;t.Height=h;t.MipLevels=1;t.ArraySize=1;t.SampleDesc.Count=1;
   t.Format=i==0?DXGI_FORMAT_R8G8B8A8_UNORM:i==1?DXGI_FORMAT_R32_UINT:DXGI_FORMAT_R32_FLOAT;t.Usage=D3D11_USAGE_DEFAULT;t.BindFlags=D3D11_BIND_RENDER_TARGET;
   hr(device->CreateTexture2D(&t,nullptr,&targets[i]),"frame target");hr(device->CreateRenderTargetView(targets[i].Get(),nullptr,&rtvs[i]),"frame RTV");
   t.Usage=D3D11_USAGE_STAGING;t.BindFlags=0;t.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
   hr(device->CreateTexture2D(&t,nullptr,&staging[i]),"frame readback");
  }
  D3D11_TEXTURE2D_DESC t{};t.Width=w;t.Height=h;t.MipLevels=1;t.ArraySize=1;t.SampleDesc.Count=1;t.Format=DXGI_FORMAT_D32_FLOAT;t.BindFlags=D3D11_BIND_DEPTH_STENCIL;
  hr(device->CreateTexture2D(&t,nullptr,&depth_tex),"frame depth");hr(device->CreateDepthStencilView(depth_tex.Get(),nullptr,&dsv),"frame DSV");
 }
 void render(const BeginFrame& c){
  if(state!=2)return;auto started=Clock::now();std::lock_guard<std::mutex> lock(mutex);camera=c;
  resize(uint32_t(c.viewport_width),uint32_t(c.viewport_height));
  Vec3 f=unit(sub(c.target,c.position)),r=unit(cross(f,c.up)),u=unit(cross(r,f));Params p{};
  auto set=[](float* d,Vec3 a){d[0]=float(a.x);d[1]=float(a.y);d[2]=float(a.z);};
  set(p.eye,c.position);set(p.right,r);set(p.up,u);set(p.forward,f);
  double aspect=double(width)/height;
  if(c.is_perspective){double fy=1/std::tan(c.fov*3.141592653589793/360.);p.projection[0]=float(fy/aspect);p.projection[1]=float(fy);}
  else {p.projection[0]=float(2/(c.height*aspect));p.projection[1]=float(2/c.height);}
  p.projection[2]=float(std::max(.00001,c.near_clipping_distance));p.projection[3]=float(std::max(c.far_clipping_distance,c.near_clipping_distance+1.));
  double a=options.angle*3.141592653589793/180.;p.transform[0]=float(std::cos(a));p.transform[1]=float(std::sin(a));
  for(int k=0;k<3;k++){p.cliplo[k]=(options.flags&1)?float(options.clip[k]):-1e30f;p.cliphi[k]=(options.flags&1)?float(options.clip[k+3]):1e30f;}
  if(options.flags&2){p.cliplo[2]=std::max(p.cliplo[2],float(options.slice_z-options.slice_width*.5));p.cliphi[2]=std::min(p.cliphi[2],float(options.slice_z+options.slice_width*.5));}
  p.cliplo[3]=float(options.x);p.cliphi[3]=float(options.y);p.misc[0]=float(options.z);p.misc[1]=c.is_perspective?1.f:0.f;p.misc[2]=float(options.color);
  p.height_range[2]=crop_view?1.f:0.f;
  p.height_range[0]=float(bounds.min.z);p.height_range[1]=float(bounds.max.z);
  // Exact native camera, including off-center projections. Compose in double
  // precision before uploading the local-source matrix to the GPU.
  std::array<double,16> pm{},vm{},pose{};
  if(std::abs(c.projection_matrix[0])>1e-15 && std::abs(c.projection_matrix[5])>1e-15){
   std::copy(c.projection_matrix,c.projection_matrix+16,pm.begin());std::copy(c.view_matrix,c.view_matrix+16,vm.begin());
  }else{
   vm={r.x,r.y,r.z,-dot(r,c.position),u.x,u.y,u.z,-dot(u,c.position),-f.x,-f.y,-f.z,dot(f,c.position),0,0,0,1};
   double n=p.projection[2],z=p.projection[3];pm[0]=p.projection[0];pm[5]=p.projection[1];
   if(c.is_perspective){pm[10]=-(z+n)/(z-n);pm[11]=-2*z*n/(z-n);pm[14]=-1;}
   else{pm[10]=-2/(z-n);pm[11]=-(z+n)/(z-n);pm[15]=1;}
  }
  double cs=std::cos(a),sn=std::sin(a),k=1/.0254;
  pose={cs*k,-sn*k,0,options.x*k,sn*k,cs*k,0,options.y*k,0,0,k,options.z*k,0,0,0,1};
  auto mul=[](const std::array<double,16>& a,const std::array<double,16>& b){std::array<double,16> out{};for(int i=0;i<4;i++)for(int j=0;j<4;j++)for(int q=0;q<4;q++)out[i*4+j]+=a[i*4+q]*b[q*4+j];return out;};
  auto next_projection=mul(mul(pm,vm),pose);
  if(gaussian&&frame_valid&&next_projection==source_projection) return;
  source_projection=next_projection;for(int i=0;i<16;i++)p.mvp[i]=float(source_projection[i]);
  if(gaussian){
   double x=c.position.x*.0254-options.x,y=c.position.y*.0254-options.y;
   set(p.eye,{x*cs+y*sn,-x*sn+y*cs,c.position.z*.0254-options.z});
   set(p.forward,{f.x*cs+f.y*sn,-f.x*sn+f.y*cs,f.z});
   p.right[3]=float(width); p.up[3]=float(height); p.misc[3]=float(harmonic_count/3);
   p.height_range[3]=float(gaussian_opacity);
  }
  context->UpdateSubresource(constant.Get(),0,nullptr,&p,0,0);
  float clear[4]={0,0,0,0};for(int i=0;i<2;i++)context->ClearRenderTargetView(rtvs[i].Get(),clear);
  float clear_depth[4]={1,1,1,1};context->ClearRenderTargetView(rtvs[2].Get(),clear_depth);context->ClearDepthStencilView(dsv.Get(),D3D11_CLEAR_DEPTH,1,0);
  ID3D11RenderTargetView* rt[]={rtvs[0].Get(),rtvs[1].Get(),rtvs[2].Get()};context->OMSetRenderTargets(3,rt,dsv.Get());context->OMSetDepthStencilState(depth_state.Get(),0);
  D3D11_VIEWPORT vp{0,0,float(width),float(height),0,1};context->RSSetViewports(1,&vp);context->RSSetState(raster.Get());
  ID3D11Buffer* b=vertices.Get();UINT stride=sizeof(Vertex),offset=0;context->IASetVertexBuffers(0,1,&b,&stride,&offset);context->IASetInputLayout(layout.Get());context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);
  context->VSSetShader(vs.Get(),nullptr,0);context->PSSetShader(ps.Get(),nullptr,0);b=constant.Get();context->VSSetConstantBuffers(0,1,&b);
  auto* crop_resource=crop_view.Get();context->VSSetShaderResources(2,1,&crop_resource);
  submitted=0;
  if(options.flags&4){
   if(gaussian) gaussian->render(device.Get(),context.Get(),vertices.Get(),constant.Get(),rt,source,
       {f.x*cs+f.y*sn,-f.x*sn+f.y*cs,f.z},bounds,width,height);
   else context->Draw(UINT(count),0);
   submitted=count;
  }
  context->OMSetRenderTargets(0,nullptr,nullptr);
  void* destinations[]={colors.data(),ids.data(),depths.data()};
  for(int i=0;i<3;i++)context->CopyResource(staging[i].Get(),targets[i].Get());
  for(int i=0;i<3;i++){D3D11_MAPPED_SUBRESOURCE m{};hr(context->Map(staging[i].Get(),0,D3D11_MAP_READ,0,&m),"GPU readback");
   for(uint32_t y=0;y<height;y++)memcpy(static_cast<char*>(destinations[i])+size_t(y)*width*4,static_cast<char*>(m.pData)+size_t(y)*m.RowPitch,size_t(width)*4);
   context->Unmap(staging[i].Get(),0);}
  visible=std::count_if(ids.begin(),ids.end(),[](uint32_t i){return i!=0;});frames++;frame_ms=seconds(started)*1000;frame_valid=true;
 }
};
using GetModel=int(*)(SURef*);using Create=int(*)(SURef,const CreateOverlay*,SURef*);using Enable=int(*)(SURef,bool);using Release=int(*)(SURef,SURef*);
static Bounds extents(SURef,void* p){auto e=static_cast<Engine*>(p);std::lock_guard<std::mutex> l(e->mutex);Bounds b=e->bounds;double a=e->options.angle*3.141592653589793/180.,c=cos(a),s=sin(a);Bounds out{{1e300,1e300,1e300},{-1e300,-1e300,-1e300}};
 for(int i=0;i<8;i++){double x=(i&1)?b.max.x:b.min.x,y=(i&2)?b.max.y:b.min.y,z=(i&4)?b.max.z:b.min.z;Vec3 v{(x*c-y*s+e->options.x)/.0254,(x*s+y*c+e->options.y)/.0254,(z+e->options.z)/.0254};out.min={std::min(out.min.x,v.x),std::min(out.min.y,v.y),std::min(out.min.z,v.z)};out.max={std::max(out.max.x,v.x),std::max(out.max.y,v.y),std::max(out.max.z,v.z)};}return out;}
static void begin(SURef,const BeginFrame* c,void* p){auto e=static_cast<Engine*>(p);try{if(!c||c->viewport_width<1||c->viewport_width>32768||c->viewport_height<1||c->viewport_height>32768||!std::isfinite(c->height))throw std::runtime_error("SU overlay camera ABI mismatch");e->render(*c);}catch(const std::exception& x){e->fail(x);}}
static void draw(SURef,DrawFrame* f,void* p){auto e=static_cast<Engine*>(p);std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid)return;
 f->blending_factor=1.;uint32_t pitch=e->width*4,size=pitch*e->height;f->color={e->colors.data(),pitch,size};f->depth={e->depths.data(),pitch,size};}
static void end_frame(SURef,void*) {
 // Engine-owned buffers stay allocated through this callback. The next frame
 // can reuse their contents only after SketchUp has consumed the current one.
}
static void detach(Engine* e){if(e->overlay.ptr){auto fn=reinterpret_cast<Release>(GetProcAddress(GetModuleHandleW(nullptr),"SUModelReleaseOverlay"));if(fn)fn(e->model,&e->overlay);e->overlay={};}}
#define API extern "C" __declspec(dllexport)
API Engine* pc_create(){try{return new Engine;}catch(...){return nullptr;}}
API void pc_destroy(Engine* e){if(e){detach(e);delete e;}}
API int pc_add_tile(Engine* e,const char* path,uint64_t count){if(!e||e->state!=0||!path||count==0||count>100000000||e->count>100000000-count)return -1;try{e->tiles.push_back({path,count});e->count+=count;return 0;}catch(const std::exception& x){e->fail(x);return -1;}}
API int pc_add_gaussians(Engine* e,const char* path,uint64_t count,const char* harmonics,uint32_t coefficients){
 if(!e||e->state!=0||e->count||!path||!harmonics||!count||count>20000000) return -1;
 if(coefficients!=0&&coefficients!=9&&coefficients!=24&&coefficients!=45) return -1;
 try { e->gaussian_path=path; e->harmonic_path=harmonics; e->harmonic_count=coefficients; e->count=count; return 0; }
 catch(const std::exception& x){ e->fail(x); return -1; }
}
API int pc_load(Engine* e,uint32_t divisor){if(!e||e->state!=0)return -1;try{e->state=1;e->loader=std::thread([e,divisor]{e->load(divisor);});return 0;}catch(const std::exception& x){e->fail(x);return -1;}}
API int pc_wait(Engine* e){if(e->loader.joinable())e->loader.join();return e->state==2?0:-1;}
API int pc_status(Engine* e){return e?e->state.load():-1;}
API int pc_options(Engine* e,const Options* o){if(!e||!o)return -1;std::lock_guard<std::mutex> l(e->mutex);e->options=*o;e->frame_valid=false;return 0;}
API int pc_set_gaussian_opacity(Engine* e,double opacity){
 if(!e||!std::isfinite(opacity)||opacity<0||opacity>1) return -1;
 std::lock_guard<std::mutex> lock(e->mutex);
 if(e->gaussian_opacity!=opacity) e->frame_valid=false;
 e->gaussian_opacity=opacity;
 return 0;
}
API int pc_attach(Engine* e){if(!e||e->state!=2)return -1;try{
 auto exe=GetModuleHandleW(nullptr);auto get=reinterpret_cast<GetModel>(GetProcAddress(exe,"SUApplicationGetActiveModel"));auto create=reinterpret_cast<Create>(GetProcAddress(exe,"SUModelCreateOverlay"));auto enable=reinterpret_cast<Enable>(GetProcAddress(exe,"SUOverlayEnable"));
 if(!get||!create||!enable)throw std::runtime_error("SketchUp 2024+ native overlay API required");
 int result=get(&e->model);if(result)throw std::runtime_error("Cannot access active SU model");
 CreateOverlay info{};info.version=1;info.user_data=e;info.id="share3dcam.resident.fullcloud";info.name=e->gaussian?u8"赛尔高斯绘图参照":u8"赛尔连续全量点云";info.desc=u8"随 SketchUp 相机更新的扫描参照";info.source="SHARE3DCAM";info.image_format=0;info.image_orientation=0;info.get_extents=extents;info.begin_frame=begin;info.draw_frame=draw;info.end_frame=end_frame;
 result=create(e->model,&info,&e->overlay);if(result)throw std::runtime_error("SUModelCreateOverlay: "+std::to_string(result));result=enable(e->overlay,true);if(result)throw std::runtime_error("SUOverlayEnable: "+std::to_string(result));return 0;
 }catch(const std::exception& x){e->fail(x);return -1;}}
API void pc_detach(Engine* e){if(e)detach(e);}
API void pc_forget_closed_overlay(Engine* e){if(e){e->overlay={};e->model={};}}
API const char* pc_stats(Engine* e){if(!e)return "{}";std::lock_guard<std::mutex> l(e->mutex);std::ostringstream s;
 auto safe=[](std::string x){for(char& c:x)if(c=='"'||c=='\\'||uint8_t(c)<32)c=' ';return x;};
 s<<"{\"state\":"<<e->state<<",\"resident_points\":"<<(e->state==2?e->count:0)<<",\"loaded_points\":"<<e->loaded<<",\"submitted_points\":"<<e->submitted<<",\"uploads\":"<<e->uploads<<",\"frames\":"<<e->frames<<",\"visible_pixels\":"<<e->visible<<",\"frame_ms\":"<<e->frame_ms<<",\"load_seconds\":"<<e->load_seconds<<",\"preview\":false,\"gpu\":\""<<safe(e->device_name)<<"\",\"error\":\""<<safe(e->error)<<"\",\"width\":"<<e->width<<",\"height\":"<<e->height<<"}";e->stats_json=s.str();return e->stats_json.c_str();}
API int pc_render_test(Engine* e,const double* v,uint32_t w,uint32_t h){try{BeginFrame c{};c.position={v[0]/.0254,v[1]/.0254,v[2]/.0254};c.target={v[3]/.0254,v[4]/.0254,v[5]/.0254};c.up={v[6],v[7],v[8]};c.height=v[9]/.0254;c.viewport_width=w;c.viewport_height=h;c.near_clipping_distance=.01;c.far_clipping_distance=100000.;e->render(c);return 0;}catch(const std::exception& x){e->fail(x);return -1;}}
API int pc_render_camera(Engine* e,const BeginFrame* c){if(!e||!c)return -1;try{e->render(*c);return 0;}catch(const std::exception& x){e->fail(x);return -1;}}
API int pc_read_ids(Engine* e,uint32_t* p,uint32_t n){std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid||n!=e->ids.size())return -1;memcpy(p,e->ids.data(),size_t(n)*4);return 0;}
API int pc_read_color(Engine* e,uint32_t* p,uint32_t n){std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid||n!=e->colors.size())return -1;memcpy(p,e->colors.data(),size_t(n)*4);return 0;}
API int pc_read_depth(Engine* e,float* p,uint32_t n){std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid||n!=e->depths.size())return -1;memcpy(p,e->depths.data(),size_t(n)*4);return 0;}
API int pc_camera(Engine* e,BeginFrame* out){if(!e||!out)return -1;std::lock_guard<std::mutex> l(e->mutex);*out=e->camera;return 0;}
API int pc_pick(Engine* e,double x,double y,double radius,double logical_w,double logical_h,double* out){
 if(!e||!out)return 0;std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid||logical_w<=0||logical_h<=0)return 0;
 double sx=e->width/logical_w,sy=e->height/logical_h,best=radius*radius;uint32_t winner=0;
 double a=e->options.angle*3.141592653589793/180.,c=cos(a),sn=sin(a);
 int x0=std::max(0,int((x-radius)*sx)),x1=std::min(int(e->width)-1,int((x+radius)*sx)),y0=std::max(0,int((y-radius)*sy)),y1=std::min(int(e->height)-1,int((y+radius)*sy));
 for(int py=y0;py<=y1;py++)for(int px=x0;px<=x1;px++){uint32_t id=e->ids[size_t(py)*e->width+px];if(!id||id>e->source.size())continue;
  auto& s=e->source[id-1];const auto& m=e->source_projection;
  double cx=m[0]*s.xyz[0]+m[1]*s.xyz[1]+m[2]*s.xyz[2]+m[3],cy=m[4]*s.xyz[0]+m[5]*s.xyz[1]+m[6]*s.xyz[2]+m[7],cw=m[12]*s.xyz[0]+m[13]*s.xyz[1]+m[14]*s.xyz[2]+m[15];
  if(cw<=0)continue;double dx=logical_w*.5*(cx/cw+1)-x,dy=logical_h*.5*(1-cy/cw)-y,d=dx*dx+dy*dy;
  if(d<=best){best=d;winner=id;}}
 if(!winner)return 0;const auto& s=e->source[winner-1];
 out[0]=(s.xyz[0]*c-s.xyz[1]*sn+e->options.x)/.0254;out[1]=(s.xyz[0]*sn+s.xyz[1]*c+e->options.y)/.0254;out[2]=(s.xyz[2]+e->options.z)/.0254;memcpy(out+3,&s.id,8);return 1;
}

API int pc_crop_matrix(Engine* e,double* matrix){if(!e||!matrix)return -1;std::lock_guard<std::mutex> l(e->mutex);if(!e->frame_valid)return -1;std::copy(e->source_projection.begin(),e->source_projection.end(),matrix);return 0;}
API int pc_crop_reset(Engine* e){if(!e)return -1;std::lock_guard<std::mutex> l(e->mutex);e->crop_mask.clear();e->crop_view.Reset();e->crop_buffer.Reset();e->frame_valid=false;return 0;}
API int pc_crop_polygon(Engine* e,const double* matrix,const double* xy,uint32_t n,int keep){
 if(!e||e->state!=2||!matrix||!xy||n<3||n>256||(keep!=0&&keep!=1))return -1;
 for(int i=0;i<16;i++)if(!std::isfinite(matrix[i]))return -1;
 for(uint32_t i=0;i<n*2;i++)if(!std::isfinite(xy[i])||std::abs(xy[i])>10)return -1;
 try{std::lock_guard<std::mutex> lock(e->mutex);
  std::vector<uint32_t> mask=e->crop_mask.empty()?std::vector<uint32_t>(size_t(e->count),1):e->crop_mask;
  for(size_t k=0;k<e->source.size();k++){
   if(!mask[k])continue;auto& p=e->source[k];double q[4]={};
   for(int r=0;r<4;r++)q[r]=matrix[r*4]*p.xyz[0]+matrix[r*4+1]*p.xyz[1]+matrix[r*4+2]*p.xyz[2]+matrix[r*4+3];
   bool inside=false;
   if(q[3]>0&&q[2]>=-q[3]&&q[2]<=q[3]){
    double x=q[0]/q[3],y=q[1]/q[3];
    for(uint32_t i=0,j=n-1;i<n;j=i++){
     double ax=xy[2*j],ay=xy[2*j+1],bx=xy[2*i],by=xy[2*i+1];
     double cross=(x-ax)*(by-ay)-(y-ay)*(bx-ax);
     if(std::abs(cross)<1e-10 && x>=std::min(ax,bx)-1e-10&&x<=std::max(ax,bx)+1e-10&&y>=std::min(ay,by)-1e-10&&y<=std::max(ay,by)+1e-10){inside=true;break;}
     if((ay>y)!=(by>y) && x<(bx-ax)*(y-ay)/(by-ay)+ax)inside=!inside;
    }
   }
   if(inside!=(keep!=0))mask[k]=0;
  }
  D3D11_BUFFER_DESC b{};b.ByteWidth=UINT(mask.size()*4);b.Usage=D3D11_USAGE_DEFAULT;b.BindFlags=D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA data{};data.pSysMem=mask.data();ComPtr<ID3D11Buffer> buffer;hr(e->device->CreateBuffer(&b,&data,&buffer),"free crop mask");
  D3D11_SHADER_RESOURCE_VIEW_DESC d{};d.Format=DXGI_FORMAT_R32_UINT;d.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;d.Buffer.NumElements=UINT(mask.size());ComPtr<ID3D11ShaderResourceView> view;hr(e->device->CreateShaderResourceView(buffer.Get(),&d,&view),"free crop view");
  e->crop_mask=std::move(mask);e->crop_buffer=buffer;e->crop_view=view;e->frame_valid=false;return 0;
 }catch(const std::exception& x){e->fail(x);return -1;}
}
