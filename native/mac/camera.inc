// Camera math mirrors the tested Windows ABI; matrices remain double until upload.
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
  p.height_range[2]=!crop_mask.empty()?1.f:0.f;
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
  if(gaussian()&&frame_valid&&next_projection==source_projection) return;
  source_projection=next_projection;for(int i=0;i<16;i++)p.mvp[i]=float(source_projection[i]);
  if(gaussian()){
   double x=c.position.x*.0254-options.x,y=c.position.y*.0254-options.y;
   set(p.eye,{x*cs+y*sn,-x*sn+y*cs,c.position.z*.0254-options.z});
   set(p.forward,{f.x*cs+f.y*sn,-f.x*sn+f.y*cs,f.z});
   p.right[3]=float(width); p.up[3]=float(height); p.misc[3]=float(harmonic_count/3);
   p.height_range[3]=float(gaussian_opacity);
  }
