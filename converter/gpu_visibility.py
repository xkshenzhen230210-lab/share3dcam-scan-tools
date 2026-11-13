"""Resident OpenCL GPU visibility; no CUDA/Python package or driver installation."""
import ctypes as C
import os
import time
import numpy as np
from converter.full_index import RECORD
from converter.queries import Camera,Pose

KERNEL=r'''
#pragma OPENCL EXTENSION cl_khr_fp64 : enable
#pragma OPENCL EXTENSION cl_khr_int64_base_atomics : enable
#pragma OPENCL EXTENSION cl_khr_int64_extended_atomics : enable
#pragma OPENCL FP_CONTRACT OFF
inline int project_point(__global const double *xyz, uint i, __constant double *p,
                         uint w,uint h,__private uint *pixel,__private double *depth) {
    double bx=xyz[3*(size_t)i],by=xyz[3*(size_t)i+1],bz=xyz[3*(size_t)i+2];
    double x=bx*p[20]-by*p[21]+p[22],y=bx*p[21]+by*p[20]+p[23],z=bz+p[24];
    if(p[34] && (x<p[25]||y<p[26]||z<p[27]||x>p[28]||y>p[29]||z>p[30]))return 0;
    if(p[35] && (z<p[31]||z>p[32]))return 0;
    double vx=x-p[0],vy=y-p[1],vz=z-p[2];
    double d=(vx*p[9]+vy*p[10])+vz*p[11];
    if(!isfinite(d)||d<=1.e-9)return 0;
    double den=p[33]!=0.?d:1.;
    double sx=(p[12]+((vx*p[3]+vy*p[4])+vz*p[5])*p[14]/den)*p[18];
    double sy=(p[13]-((vx*p[6]+vy*p[7])+vz*p[8])*p[15]/den)*p[19];
    if(!isfinite(sx)||!isfinite(sy)||sx<-.5||sy<-.5||sx>=(double)w-.5||sy>=(double)h-.5)return 0;
    *pixel=(uint)floor(sy+.5)*w+(uint)floor(sx+.5);*depth=d;return 1;
}
__kernel void clear_frame(__global ulong *z,__global ulong *id,__global uint *indices,uint count) {
    size_t i=get_global_id(0);if(i>=count)return;
    z[i]=as_ulong((double)INFINITY);id[i]=(ulong)-1;indices[i]=(uint)-1;
}
__kernel void resolve(__global const double *xyz,__global const ulong *source_ids,uint count,
                      __constant double *p,uint w,uint h,__global ulong *z,__global ulong *ids,
                      __global uint *indices,__global uint *counts,uint stage) {
    __local uint sums[256];
    size_t i=get_global_id(0);uint pixel=0;double depth=0.;
    int valid=i<count && project_point(xyz,(uint)i,p,w,h,&pixel,&depth);
    if(valid) {
        ulong bits=as_ulong(depth);
        if(stage==0)atom_min((volatile __global ulong *)(z+pixel),bits);
        else if(bits==z[pixel]) {
            if(stage==1)atom_min((volatile __global ulong *)(ids+pixel),source_ids[i]);
            else if(ids[pixel]==source_ids[i])indices[pixel]=(uint)i;
        }
    }
    if(stage==0) {
        uint local_id=get_local_id(0);sums[local_id]=valid;
        barrier(CLK_LOCAL_MEM_FENCE);
        for(uint step=128;step;step>>=1) {
            if(local_id<step)sums[local_id]+=sums[local_id+step];
            barrier(CLK_LOCAL_MEM_FENCE);
        }
        if(local_id==0)counts[get_group_id(0)]=sums[0];
    }
}
'''


class OpenCL:
    def __init__(self):
        try:self.initialize()
        except BaseException:
            if hasattr(self,'lib'):self.close()
            raise
    def initialize(self):
        if os.name!='nt':raise RuntimeError('当前GPU后台支持Windows OpenCL驱动')
        self.lib=C.WinDLL('OpenCL.dll');self.context=self.queue=self.program=None
        self.buffers=[];self.kernels=[]
        v=C.c_void_p;u=C.c_uint;s=C.c_size_t;i=C.c_int;p=C.POINTER
        definitions={
            'clGetPlatformIDs':([u,p(v),p(u)],i),'clGetDeviceIDs':([v,C.c_ulonglong,u,p(v),p(u)],i),
            'clGetDeviceInfo':([v,u,s,v,p(s)],i),'clCreateContext':([v,u,p(v),v,v,p(i)],v),
            'clCreateCommandQueue':([v,v,C.c_ulonglong,p(i)],v),
            'clCreateProgramWithSource':([v,u,p(C.c_char_p),p(s),p(i)],v),
            'clBuildProgram':([v,u,p(v),C.c_char_p,v,v],i),'clGetProgramBuildInfo':([v,v,u,s,v,p(s)],i),
            'clCreateKernel':([v,C.c_char_p,p(i)],v),'clCreateBuffer':([v,C.c_ulonglong,s,v,p(i)],v),
            'clSetKernelArg':([v,u,s,v],i),
            'clEnqueueWriteBuffer':([v,v,u,s,s,v,u,v,v],i),
            'clEnqueueReadBuffer':([v,v,u,s,s,v,u,v,v],i),
            'clEnqueueNDRangeKernel':([v,v,u,p(s),p(s),p(s),u,v,v],i),'clFinish':([v],i)}
        for name in ('MemObject','Kernel','Program','CommandQueue','Context'):
            definitions['clRelease'+name]=([v],i)
        for name,(args,result) in definitions.items():
            f=getattr(self.lib,name);f.argtypes=args;f.restype=result
        count=u();self.check(self.lib.clGetPlatformIDs(0,None,C.byref(count)))
        platforms=(v*count.value)();self.check(self.lib.clGetPlatformIDs(count,platforms,None))
        devices=[]
        for platform in platforms:
            n=u()
            if self.lib.clGetDeviceIDs(platform,4,0,None,C.byref(n))!=0:continue
            found=(v*n.value)();self.check(self.lib.clGetDeviceIDs(platform,4,n,found,None))
            for device in found:
                ext=self.device_text(device,0x1030).split()
                if all(e in ext for e in ('cl_khr_fp64','cl_khr_int64_extended_atomics')):
                    memory=C.c_ulonglong();self.check(self.lib.clGetDeviceInfo(device,0x101f,8,C.byref(memory),None))
                    devices.append((memory.value,device,self.device_text(device,0x102b)))
        if not devices:raise RuntimeError('未找到支持双精度和64位原子的OpenCL GPU')
        self.memory,self.device,self.name=max(devices);device=v(self.device);error=i()
        self.context=self.lib.clCreateContext(None,1,C.byref(device),None,None,C.byref(error));self.check(error.value)
        self.queue=self.lib.clCreateCommandQueue(self.context,device,0,C.byref(error));self.check(error.value)
        source=C.c_char_p(KERNEL.encode('ascii'));length=s(len(source.value))
        self.program=self.lib.clCreateProgramWithSource(self.context,1,C.byref(source),C.byref(length),C.byref(error));self.check(error.value)
        result=self.lib.clBuildProgram(self.program,1,C.byref(device),b'-cl-std=CL1.2',None,None)
        if result:
            log=C.create_string_buffer(65536);self.lib.clGetProgramBuildInfo(self.program,device,0x1183,len(log),log,None)
            raise RuntimeError('GPU内核编译失败：'+log.value.decode('utf-8','replace'))
    @staticmethod
    def check(error):
        if error:raise RuntimeError(f'OpenCL错误 {error}')
    def device_text(self,device,key):
        value=C.create_string_buffer(32768);self.check(self.lib.clGetDeviceInfo(device,key,len(value),value,None))
        return value.value.decode('utf-8','replace')
    def buffer(self,nbytes,array=None):
        error=C.c_int();handle=self.lib.clCreateBuffer(self.context,4|32 if array is not None else 1,nbytes,
             C.c_void_p(array.ctypes.data) if array is not None else None,C.byref(error))
        self.check(error.value);self.buffers.append(handle);return handle
    def release_buffer(self,handle):
        self.check(self.lib.clReleaseMemObject(handle));self.buffers.remove(handle)
    def kernel(self,name):
        error=C.c_int();kernel=self.lib.clCreateKernel(self.program,name.encode(),C.byref(error))
        self.check(error.value);self.kernels.append(kernel);return kernel
    def run(self,kernel,count,args):
        for index,(kind,value) in enumerate(args):
            arg=C.c_void_p(value) if kind=='buffer' else C.c_uint(value)
            self.check(self.lib.clSetKernelArg(kernel,index,C.sizeof(arg),C.byref(arg)))
        work=C.c_size_t(((count+255)//256)*256);local=C.c_size_t(256)
        self.check(self.lib.clEnqueueNDRangeKernel(self.queue,kernel,1,None,C.byref(work),C.byref(local),0,None,None))
    def write(self,buffer,array):
        self.check(self.lib.clEnqueueWriteBuffer(self.queue,buffer,1,0,array.nbytes,C.c_void_p(array.ctypes.data),0,None,None))
    def read(self,buffer,array):
        self.check(self.lib.clEnqueueReadBuffer(self.queue,buffer,1,0,array.nbytes,C.c_void_p(array.ctypes.data),0,None,None))
    def close(self):
        if self.queue:self.lib.clFinish(self.queue)
        for handle in self.buffers:self.lib.clReleaseMemObject(handle)
        for handle in self.kernels:self.lib.clReleaseKernel(handle)
        if self.program:self.lib.clReleaseProgram(self.program)
        if self.queue:self.lib.clReleaseCommandQueue(self.queue)
        if self.context:self.lib.clReleaseContext(self.context)
        self.buffers=[];self.kernels=[];self.program=self.queue=self.context=None


class GpuVisibility:
    def __init__(self,index):
        try:self.initialize(index)
        except BaseException:
            if hasattr(self,'cl'):self.cl.close()
            raise
    def initialize(self,index):
        started=time.perf_counter();self.index=index;self.cl=OpenCL();self.frame_buffers=[]
        self.n=index.meta['indexed_points']
        if self.n>=2**32:raise RuntimeError('当前GPU单云最多支持约42亿点')
        need=self.n*32+512*1024**2
        if need>self.cl.memory*.8:raise RuntimeError('显存不足以常驻当前完整点云')
        self.rows=np.empty(self.n,dtype=RECORD);offset=0
        for rows in index.all_records():self.rows[offset:offset+len(rows)]=rows;offset+=len(rows)
        if offset!=self.n:raise ValueError('GPU源点载入数量不一致')
        xyz=np.ascontiguousarray(self.rows['xyz']);ids=np.ascontiguousarray(self.rows['id'])
        self.xyz=self.cl.buffer(xyz.nbytes,xyz);self.ids=self.cl.buffer(ids.nbytes,ids)
        self.params=self.cl.buffer(36*8)
        self.clear=self.cl.kernel('clear_frame');self.resolve=self.cl.kernel('resolve')
        self.upload_count=1;self.cold_seconds=time.perf_counter()-started;self.size=None
    def close(self):self.cl.close()
    def full_view(self,camera,options):
        started=time.perf_counter();cam=Camera(camera);pose=Pose(options)
        w=int(camera.get('render_width',cam.width));h=int(camera.get('render_height',cam.height))
        if not 1<=w<=16384 or not 1<=h<=16384 or w*h>67_108_864:raise ValueError('GPU视窗尺寸无效')
        if self.size!=(w,h):
            for buffer in self.frame_buffers:self.cl.release_buffer(buffer)
            self.z=self.cl.buffer(w*h*8);self.winner_ids=self.cl.buffer(w*h*8);self.indices=self.cl.buffer(w*h*4)
            self.counts=self.cl.buffer(((self.n+255)//256)*4)
            self.frame_buffers=[self.z,self.winner_ids,self.indices,self.counts];self.size=(w,h)
        values=np.zeros(36,dtype='f8');values[:3]=cam.eye;values[3:12]=cam.basis.ravel()
        values[12:20]=[cam.cx,cam.cy,cam.fx,cam.fy,cam.width,cam.height,w/cam.width,h/cam.height]
        values[20:25]=[pose.rotation[0,0],pose.rotation[1,0],*pose.offset]
        if pose.clip is not None:values[25:31]=pose.clip.ravel();values[34]=1
        if pose.slice is not None:values[31:33]=pose.slice;values[35]=1
        values[33]=cam.perspective;self.cl.write(self.params,values)
        self.cl.run(self.clear,w*h,[('buffer',self.z),('buffer',self.winner_ids),('buffer',self.indices),('uint',w*h)])
        args=[('buffer',self.xyz),('buffer',self.ids),('uint',self.n),('buffer',self.params),('uint',w),('uint',h),
              ('buffer',self.z),('buffer',self.winner_ids),('buffer',self.indices),('buffer',self.counts)]
        for stage in range(3):self.cl.run(self.resolve,self.n,args+[('uint',stage)])
        indices=np.empty(w*h,dtype='u4');counts=np.empty((self.n+255)//256,dtype='u4')
        self.cl.read(self.indices,indices);self.cl.read(self.counts,counts)
        valid=indices!=np.iinfo('u4').max;selected=indices[valid]
        rows=self.rows[selected].copy()
        self.last_grid=np.full(w*h,-1,dtype='<i4');self.last_grid[valid]=np.arange(len(rows),dtype='i4')
        return rows,{'indexed_points':self.n,'scanned_points':self.n,'in_view_points':int(counts.sum(dtype='u8')),
            'display_points':len(rows),'visible_pixel_points':len(rows),'full_tiles':len(self.index.tiles),'lod_tiles':0,
            'render_mode':'full_visibility','render_width':w,'render_height':h,'point_budget':None,
            'engine':'opencl_gpu','gpu_device':self.cl.name,'resident_bytes':self.n*32,
            'upload_count':self.upload_count,'cold_load_seconds':round(self.cold_seconds,3),
            'gpu_frame_seconds':round(time.perf_counter()-started,3)}
