// Same exported C API and source-ID picking contract as Windows.
#define API extern "C" __attribute__((visibility("default")))
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
 auto get=reinterpret_cast<GetModel>(dlsym(RTLD_DEFAULT,"SUApplicationGetActiveModel"));auto create=reinterpret_cast<Create>(dlsym(RTLD_DEFAULT,"SUModelCreateOverlay"));auto enable=reinterpret_cast<Enable>(dlsym(RTLD_DEFAULT,"SUOverlayEnable"));
 if(!get||!create||!enable)throw std::runtime_error("SketchUp 2024+ native overlay API required");
 int result=get(&e->model);if(result)throw std::runtime_error("Cannot access active SU model");
 CreateOverlay info{};info.version=1;info.user_data=e;info.id="share3dcam.resident.fullcloud";info.name=e->gaussian()?u8"赛尔高斯绘图参照":u8"赛尔连续全量点云";info.desc=u8"随 SketchUp 相机更新的扫描参照";info.source="SHARE3DCAM";info.image_format=0;info.image_orientation=0;info.get_extents=extents;info.begin_frame=begin;info.draw_frame=draw;info.end_frame=end_frame;
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
API int pc_crop_reset(Engine* e){if(!e)return -1;std::lock_guard<std::mutex> l(e->mutex);e->crop_mask.clear();e->crop_buffer=e->buffer(4);*static_cast<uint32_t*>(e->crop_buffer.contents)=1;e->frame_valid=false;return 0;}
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
  e->upload_crop(mask);e->crop_mask=std::move(mask);e->frame_valid=false;return 0;
 }catch(const std::exception& x){e->fail(x);return -1;}
}
