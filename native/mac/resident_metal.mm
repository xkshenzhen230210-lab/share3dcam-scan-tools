#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>
#include "../su_overlay_abi.h"
#include "metal_source.h"
using Clock=std::chrono::steady_clock;
static double seconds(Clock::time_point t){return std::chrono::duration<double>(Clock::now()-t).count();}
static void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static std::string error_text(NSError* error){return error ? std::string(error.localizedDescription.UTF8String) : "Metal operation failed";}
static Vec3 sub(Vec3 a,Vec3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
static Vec3 cross(Vec3 a,Vec3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static double dot(Vec3 a,Vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static Vec3 unit(Vec3 a){double n=std::sqrt(dot(a,a));require(n>1e-12,"Invalid camera basis");return {a.x/n,a.y/n,a.z/n};}
#pragma pack(push,1)
struct Record{double xyz[3];uint16_t rgb[3];uint64_t id;};
#pragma pack(pop)
struct Source{double xyz[3];uint64_t id;};
struct Vertex{float xyz[3];uint32_t rgba,index;};
struct GaussianRecord{double mean[3];float covariance[6],dc[3],alpha;};
struct GaussianVertex{float mean[3],covariance[6],dc[3],alpha;};
struct Options{double x,y,z,angle;double clip[6];double slice_z,slice_width;uint32_t flags,color;};
struct Params{float eye[4],right[4],up[4],forward[4],projection[4],transform[4],cliplo[4],cliphi[4],misc[4],height_range[4],mvp[16];};
static_assert(sizeof(Record)==38&&sizeof(Vertex)==20&&sizeof(GaussianRecord)==64&&sizeof(GaussianVertex)==52&&sizeof(Options)==104&&sizeof(Params)==224);
struct Tile{std::string path;uint64_t count;};
struct Engine{
 std::vector<Tile> tiles;std::vector<Source> source;
 std::string gaussian_path,harmonic_path;uint32_t harmonic_count=0;
 std::atomic<int> state{0};std::atomic<uint64_t> loaded{0};std::atomic<bool> cancel{false};std::thread loader;
 std::atomic<bool> retired{false};
 std::mutex mutex;Options options{};std::string error,device_name,stats_json;uint64_t count=0,frames=0,uploads=0,submitted=0,visible=0;
 Bounds bounds{};SURef model{},overlay{};BeginFrame camera{};std::array<double,16> source_projection{};
 double frame_ms=0,load_seconds=0,gaussian_opacity=.65;bool frame_valid=false;uint32_t width=0,height=0;
 id<MTLDevice> device;id<MTLCommandQueue> queue;id<MTLRenderPipelineState> points_pipeline,splats_pipeline;
 id<MTLComputePipelineState> resolve_pipeline;id<MTLDepthStencilState> point_depth,splat_depth;
 id<MTLBuffer> vertices,harmonics,order,crop_buffer,readback[3];
 id<MTLTexture> targets[3],depth_tex,accumulated;
 std::vector<uint32_t> crop_mask,colors,ids;std::vector<float> depths;
 std::vector<uint16_t> sort_keys;Vec3 last_direction{};bool has_order=false;size_t read_pitch=0;
 Engine(){options.flags=4;options.slice_width=.1;}
 ~Engine(){cancel=true;if(loader.joinable())loader.join();}
 bool gaussian()const{return !gaussian_path.empty();}
 void fail(const std::exception& e){std::lock_guard<std::mutex> lock(mutex);error=e.what();state=-1;frame_valid=false;}
 id<MTLBuffer> buffer(size_t bytes){
  require(bytes>0&&bytes<=device.maxBufferLength,"Full data exceeds this Mac's Metal buffer limit; no preview substituted");
  id<MTLBuffer> result=[device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
  require(result!=nil,"Insufficient unified memory for full data");return result;
 }
 void init_device(){
  device=MTLCreateSystemDefaultDevice();require(device!=nil,"No Metal GPU available");
  require(device.hasUnifiedMemory,"Apple Silicon unified-memory GPU required");
  device_name=std::string(device.name.UTF8String);queue=[device newCommandQueue];require(queue!=nil,"Metal command queue unavailable");
  NSError* err=nil;MTLCompileOptions* opts=[MTLCompileOptions new];opts.fastMathEnabled=NO;
  id<MTLLibrary> library=[device newLibraryWithSource:[NSString stringWithUTF8String:metal_source] options:opts error:&err];
  if(!library)throw std::runtime_error(error_text(err));
  for(int splat=0;splat<2;splat++){
   MTLRenderPipelineDescriptor* p=[MTLRenderPipelineDescriptor new];
   p.vertexFunction=[library newFunctionWithName:splat?@"splatVertex":@"pointVertex"];
   p.fragmentFunction=[library newFunctionWithName:splat?@"splatFragment":@"pointFragment"];
   p.colorAttachments[0].pixelFormat=splat?MTLPixelFormatRGBA16Float:MTLPixelFormatRGBA8Unorm;
   p.colorAttachments[1].pixelFormat=MTLPixelFormatR32Uint;p.colorAttachments[2].pixelFormat=MTLPixelFormatR32Float;
   p.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
   if(splat){auto c=p.colorAttachments[0];c.blendingEnabled=YES;c.sourceRGBBlendFactor=c.sourceAlphaBlendFactor=MTLBlendFactorOne;c.destinationRGBBlendFactor=c.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;}
   id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:p error:&err];
   if(!pipeline)throw std::runtime_error(error_text(err));
   if(splat)splats_pipeline=pipeline;else points_pipeline=pipeline;
  }
  resolve_pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"resolveColor"] error:&err];
  if(!resolve_pipeline)throw std::runtime_error(error_text(err));
  MTLDepthStencilDescriptor* depth=[MTLDepthStencilDescriptor new];depth.depthCompareFunction=MTLCompareFunctionLess;depth.depthWriteEnabled=YES;point_depth=[device newDepthStencilStateWithDescriptor:depth];
  depth.depthCompareFunction=MTLCompareFunctionAlways;depth.depthWriteEnabled=NO;splat_depth=[device newDepthStencilStateWithDescriptor:depth];
  crop_buffer=buffer(4);*static_cast<uint32_t*>(crop_buffer.contents)=1;
  harmonics=buffer(4);memset(harmonics.contents,0,4);
 }
 static void read(std::ifstream& file,void* dst,size_t size){require(bool(file.read(static_cast<char*>(dst),std::streamsize(size))),"Incomplete index read");}
 static std::ifstream open(const std::string& path,uint64_t bytes){
  std::ifstream f(std::filesystem::u8path(path),std::ios::binary|std::ios::ate);
  require(bool(f)&&uint64_t(f.tellg())==bytes,"Incomplete index file");f.seekg(0);return f;
 }
 void load(uint32_t divisor){@autoreleasepool{
  auto started=Clock::now();try{
   require(count&&count<=100000000,"Invalid resident point count (1..100 million)");init_device();
   vertices=buffer(size_t(count)*(gaussian()?sizeof(GaussianVertex):sizeof(Vertex)));source.resize(size_t(count));
   bounds={{1e300,1e300,1e300},{-1e300,-1e300,-1e300}};
   auto account=[&](size_t i,const double* xyz,uint64_t id){
    for(int k=0;k<3;k++){require(std::isfinite(xyz[k]),"Non-finite source coordinate");source[i].xyz[k]=xyz[k];}source[i].id=id;
    bounds.min={std::min(bounds.min.x,xyz[0]),std::min(bounds.min.y,xyz[1]),std::min(bounds.min.z,xyz[2])};
    bounds.max={std::max(bounds.max.x,xyz[0]),std::max(bounds.max.y,xyz[1]),std::max(bounds.max.z,xyz[2])};
   };
   if(gaussian()){
    auto f=open(gaussian_path,count*sizeof(GaussianRecord));std::vector<GaussianRecord> block(65536);auto* dst=static_cast<GaussianVertex*>(vertices.contents);
    for(size_t start=0;start<count;start+=block.size()){
     if(cancel)return;size_t size=std::min<size_t>(block.size(),count-start);read(f,block.data(),size*sizeof(GaussianRecord));
     for(size_t j=0;j<size;j++){auto& r=block[j];auto& v=dst[start+j];account(start+j,r.mean,start+j);
      require(std::isfinite(r.alpha)&&r.alpha>=0&&r.alpha<=1,"Invalid Gaussian opacity");
      for(int k=0;k<3;k++){require(std::abs(r.mean[k])<=1e7&&std::isfinite(r.dc[k]),"Invalid Gaussian mean/color");v.mean[k]=float(r.mean[k]);v.dc[k]=r.dc[k];}
      for(int k=0;k<6;k++){require(std::isfinite(r.covariance[k]),"Invalid Gaussian covariance");v.covariance[k]=r.covariance[k];}v.alpha=r.alpha;
     }loaded=start+size;
    }
    if(harmonic_count){size_t bytes=size_t(count)*harmonic_count*2;auto sh=open(harmonic_path,bytes);harmonics=buffer(bytes);read(sh,harmonics.contents,bytes);}
    order=buffer(size_t(count)*4);sort_keys.resize(size_t(count));
   }else{
    auto* dst=static_cast<Vertex*>(vertices.contents);uint64_t offset=0;
    for(auto& tile:tiles){if(cancel)return;auto f=open(tile.path,tile.count*sizeof(Record));std::vector<Record> block(65536);
     for(size_t start=0;start<tile.count;start+=block.size()){
      if(cancel)return;size_t size=std::min<size_t>(block.size(),tile.count-start);read(f,block.data(),size*sizeof(Record));
      for(size_t j=0;j<size;j++){auto& r=block[j];auto& v=dst[offset];account(offset,r.xyz,r.id);v.index=uint32_t(offset);v.rgba=0xff000000;
       for(int k=0;k<3;k++){v.xyz[k]=float(r.xyz[k]);v.rgba|=uint32_t(std::min(255u,uint32_t(std::lround(double(r.rgb[k])/std::max(1u,divisor)))))<<(8*k);}++offset;
      }loaded=offset;
     }
    }require(offset==count,"Index count mismatch");
   }
   std::lock_guard<std::mutex> lock(mutex);uploads=1;load_seconds=seconds(started);state=2;
  }catch(const std::exception& e){fail(e);}
 }}
 id<MTLTexture> texture(MTLPixelFormat format,uint32_t w,uint32_t h,MTLTextureUsage usage){
  auto t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];t.usage=usage;t.storageMode=MTLStorageModePrivate;
  id<MTLTexture> result=[device newTextureWithDescriptor:t];require(result!=nil,"Metal frame allocation failed");return result;
 }
 void resize(uint32_t w,uint32_t h){
  if(w==width&&h==height)return;require(w&&h&&uint64_t(w)*h<=67108864,"Invalid viewport dimensions");
  width=w;height=h;read_pitch=(size_t(w)*4+255)&~size_t(255);frame_valid=false;colors.resize(size_t(w)*h);ids.resize(size_t(w)*h);depths.resize(size_t(w)*h);
  for(int i=0;i<3;i++){targets[i]=texture(i==0?MTLPixelFormatRGBA8Unorm:i==1?MTLPixelFormatR32Uint:MTLPixelFormatR32Float,w,h,MTLTextureUsageRenderTarget|(i==0?MTLTextureUsageShaderWrite:MTLTextureUsageUnknown));readback[i]=buffer(read_pitch*h);}
  depth_tex=texture(MTLPixelFormatDepth32Float,w,h,MTLTextureUsageRenderTarget);
  if(gaussian())accumulated=texture(MTLPixelFormatRGBA16Float,w,h,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
 }
 void depth_order(Vec3 direction){
  if(has_order&&dot(direction,last_direction)>1.-1e-12)return;
  constexpr size_t N=8192;std::array<uint32_t,N> buckets{};double lo=0,hi=0;
  const double low[]={bounds.min.x,bounds.min.y,bounds.min.z},high[]={bounds.max.x,bounds.max.y,bounds.max.z},axis[]={direction.x,direction.y,direction.z};
  for(int k=0;k<3;k++){lo+=std::min(low[k]*axis[k],high[k]*axis[k]);hi+=std::max(low[k]*axis[k],high[k]*axis[k]);}
  double scale=(N-1)/std::max(1e-12,hi-lo);
  for(size_t i=0;i<source.size();i++){auto& p=source[i];double d=p.xyz[0]*direction.x+p.xyz[1]*direction.y+p.xyz[2]*direction.z;auto key=uint16_t(std::clamp((hi-d)*scale,0.,double(N-1)));sort_keys[i]=key;++buckets[key];}
  uint32_t total=0;for(auto& bucket:buckets){uint32_t n=bucket;bucket=total;total+=n;}
  auto* dst=static_cast<uint32_t*>(order.contents);for(uint32_t i=0;i<source.size();i++)dst[buckets[sort_keys[i]]++]=i;
  has_order=true;last_direction=direction;
 }
 void upload_crop(const std::vector<uint32_t>& mask){crop_buffer=buffer(mask.size()*4);memcpy(crop_buffer.contents,mask.data(),mask.size()*4);}
 void render(const BeginFrame& c);
};

void Engine::render(const BeginFrame& c){@autoreleasepool{
 #include "camera.inc"
 if(gaussian())depth_order({f.x*cs+f.y*sn,-f.x*sn+f.y*cs,f.z});
 id<MTLCommandBuffer> command=[queue commandBuffer];require(command!=nil,"Metal frame command unavailable");
 auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
 for(int i=0;i<3;i++){
  pass.colorAttachments[i].texture=i==0&&gaussian()?accumulated:targets[i];
  pass.colorAttachments[i].loadAction=MTLLoadActionClear;pass.colorAttachments[i].storeAction=MTLStoreActionStore;
  pass.colorAttachments[i].clearColor=i==2?MTLClearColorMake(1,1,1,1):MTLClearColorMake(0,0,0,0);
 }
 pass.depthAttachment.texture=depth_tex;pass.depthAttachment.clearDepth=1;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionDontCare;
 id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];require(render!=nil,"Metal render encoder unavailable");
 [render setRenderPipelineState:gaussian()?splats_pipeline:points_pipeline];[render setDepthStencilState:gaussian()?splat_depth:point_depth];
 [render setCullMode:MTLCullModeNone];[render setViewport:MTLViewport{0,0,double(width),double(height),0,1}];
 [render setVertexBuffer:vertices offset:0 atIndex:0];[render setVertexBytes:&p length:sizeof(p) atIndex:1];[render setVertexBuffer:crop_buffer offset:0 atIndex:2];
 submitted=0;
 if(options.flags&4){
  if(gaussian()){
   [render setVertexBuffer:order offset:0 atIndex:3];[render setVertexBuffer:harmonics offset:0 atIndex:4];
   [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:NSUInteger(count)];
  }else [render drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:NSUInteger(count)];
  submitted=count;
 }
 [render endEncoding];
 if(gaussian()){
  auto resolve=[command computeCommandEncoder];[resolve setComputePipelineState:resolve_pipeline];
  [resolve setTexture:accumulated atIndex:0];[resolve setTexture:targets[0] atIndex:1];float opacity=float(gaussian_opacity);[resolve setBytes:&opacity length:sizeof(opacity) atIndex:0];
  [resolve dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[resolve endEncoding];
 }
 auto blit=[command blitCommandEncoder];require(blit!=nil,"Metal readback encoder unavailable");
 for(int i=0;i<3;i++)[blit copyFromTexture:targets[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:readback[i] destinationOffset:0 destinationBytesPerRow:read_pitch destinationBytesPerImage:read_pitch*height];
 [blit endEncoding];[command commit];[command waitUntilCompleted];
 if(command.status==MTLCommandBufferStatusError)throw std::runtime_error(error_text(command.error));
 void* destinations[]={colors.data(),ids.data(),depths.data()};
 for(int i=0;i<3;i++)for(uint32_t row=0;row<height;row++)memcpy(static_cast<char*>(destinations[i])+size_t(row)*width*4,static_cast<const char*>(readback[i].contents)+row*read_pitch,size_t(width)*4);
 visible=std::count_if(ids.begin(),ids.end(),[](uint32_t i){return i!=0;});frames++;frame_ms=seconds(started)*1000;frame_valid=true;
}}

// Public SketchUp Live C API symbols only. No renderer hooks or SDK copy is loaded.
using GetModel=int(*)(SURef*);using Create=int(*)(SURef,const CreateOverlay*,SURef*);using Enable=int(*)(SURef,bool);using Release=int(*)(SURef,SURef*);
static Bounds extents(SURef,void* p){auto e=static_cast<Engine*>(p);std::lock_guard<std::mutex> l(e->mutex);Bounds b=e->bounds;double a=e->options.angle*3.141592653589793/180.,c=cos(a),s=sin(a);Bounds out{{1e300,1e300,1e300},{-1e300,-1e300,-1e300}};
 for(int i=0;i<8;i++){double x=(i&1)?b.max.x:b.min.x,y=(i&2)?b.max.y:b.min.y,z=(i&4)?b.max.z:b.min.z;Vec3 v{(x*c-y*s+e->options.x)/.0254,(x*s+y*c+e->options.y)/.0254,(z+e->options.z)/.0254};out.min={std::min(out.min.x,v.x),std::min(out.min.y,v.y),std::min(out.min.z,v.z)};out.max={std::max(out.max.x,v.x),std::max(out.max.y,v.y),std::max(out.max.z,v.z)};}return out;}
static void begin(SURef,const BeginFrame* c,void* p){auto e=static_cast<Engine*>(p);if(e->retired)return;try{require(c&&c->viewport_width>=1&&c->viewport_width<=32768&&c->viewport_height>=1&&c->viewport_height<=32768&&std::isfinite(c->height),"SU overlay camera ABI mismatch");e->render(*c);}catch(const std::exception& x){e->fail(x);}}
static void draw(SURef,DrawFrame* f,void* p){auto e=static_cast<Engine*>(p);std::lock_guard<std::mutex> l(e->mutex);if(e->retired||!e->frame_valid)return;uint32_t pitch=e->width*4,size=pitch*e->height;f->blending_factor=1.;f->color={e->colors.data(),pitch,size};f->depth={e->depths.data(),pitch,size};}
static void end_frame(SURef,void*){}
static bool detach(Engine* e){
 if(!e->overlay.ptr)return true;
 const auto release=reinterpret_cast<Release>(dlsym(RTLD_DEFAULT,"SUModelReleaseOverlay"));
 if(!release||release(e->model,&e->overlay)!=0)return false;
 e->overlay={};return true;
}
#include "resident_api.inc"
