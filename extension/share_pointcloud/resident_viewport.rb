# encoding: UTF-8
require 'fiddle/import'
module SHARE3DCAM
 module PointCloud
  module ResidentAPI
   extend Fiddle::Importer
   dlload File.join(ROOT,'bin','share_cloud_resident_097.dll')
   def self.import_function(name,ctype,argtype,call_type=nil)
    # Live SU API calls may synchronously re-enter Ruby observers. Keep the
    # interpreter lock; Fiddle::Importer otherwise releases it by default.
    Fiddle::Function.new(handler.sym(name),argtype,ctype,Fiddle::Function::DEFAULT,name:name,need_gvl:true)
   end
   extern 'void* pc_create()'
   extern 'void pc_destroy(void*)'
   extern 'void pc_forget_closed_overlay(void*)'
   extern 'int pc_add_tile(void*, char*, unsigned long long)'
   extern 'int pc_add_gaussians(void*, char*, unsigned long long, char*, unsigned int)'
   extern 'int pc_load(void*, unsigned int)'
   extern 'int pc_status(void*)'
   extern 'int pc_attach(void*)'
   extern 'int pc_options(void*, void*)'
   extern 'int pc_crop_matrix(void*, void*)'
   extern 'int pc_crop_reset(void*)'
   extern 'int pc_crop_polygon(void*, void*, void*, unsigned int, int)'
   extern 'int pc_set_gaussian_opacity(void*, double)'
   extern 'char* pc_stats(void*)'
   extern 'int pc_pick(void*, double, double, double, double, double, void*)'
  end
  module ResidentViewport
   def resident?;!!@resident;end
   def gaussian?; @cloud && @cloud['kind']=='gaussian'; end
   def load_cache(cache)
    root=File.expand_path(cache);meta=JSON.parse(File.read(File.join(root,'cloud.json'),encoding:'UTF-8'))
    count=Integer(meta.fetch('indexed_points'))
    splats=meta['schema']==3 && meta['kind']=='gaussian'
    if splats
     geometry=File.join(root,'gaussians.bin'); harmonics=File.join(root,'harmonics.bin')
     coefficients=Integer(meta.fetch('sh_coefficients'))
     unless count.between?(1,20_000_000) && [0,9,24,45].include?(coefficients) && meta['record_bytes']==64 &&
            File.size(geometry)==count*64 && File.size(harmonics)==count*coefficients*2
      raise '高斯索引不完整或超出主视窗支持范围，请重新导入。'
     end
    else
     raise '需要完整分块索引，请重新导入原始点云。' unless meta['schema']==2 && meta['record_bytes']==38
     raise '索引点数不完整' unless meta.fetch('tiles').sum { |t| Integer(t.fetch('count')) }==count
     raise '当前连续全量版单云上限为1亿点。' unless count.between?(1,100_000_000)
    end
    replacing=true
    stop_resident;stop_worker
    @cloud=meta;@cache=root;@index_folder=root;@options['clip']=nil;@options['free_crop']=[];@free_crop_resident=nil;@picked_elevation=nil
    @points=[];@batches=[];@frame_full=false;@pixel_grid=nil;@full_points=nil;@frame_info=nil
    @resident=ResidentAPI.pc_create;raise '无法创建原生点云显示器。' if @resident.null?
    if splats
     raise '原生高斯索引登记失败' unless ResidentAPI.pc_add_gaussians(@resident,geometry.encode('UTF-8'),count,harmonics.encode('UTF-8'),coefficients)==0
    else
     meta['tiles'].each do |t|
      file=File.expand_path(t.fetch('file'),root)
      raise '索引文件路径无效' unless file.start_with?(root+File::SEPARATOR) && File.size(file)==Integer(t['count'])*38
      raise '原生索引登记失败' unless ResidentAPI.pc_add_tile(@resident,file.encode('UTF-8'),Integer(t['count']))==0
     end
    end
    update_index_bounds;resident_options
    raise '数据上传未能启动' unless ResidentAPI.pc_load(@resident,splats ? 1 : Integer(meta.fetch('color_divisor')))==0
    @resident_attached=false;@resident_metrics={};@resident_publish_state=nil;@resident_publish_at=nil
    @message=splats ? '正在载入高斯参数并上传显存…' : '正在一次性读取完整点云并上传显存…'
    @resident_timer=UI.start_timer(0.25,true) { PointCloud.safely { poll_resident } }
   rescue StandardError
    stop_resident if replacing
    raise
   end
   def stop_resident
    UI.stop_timer(@resident_timer) if @resident_timer
    @resident_timer=nil
    if @resident
     ResidentAPI.pc_destroy(@resident);@resident=nil
    end
    @resident_attached=false
   end
   def forget_closed_model_overlay
    # SU has already destroyed the model's native overlays before onOpenModel.
    # Never ask the Live C API to release an old, now invalid overlay handle.
    ResidentAPI.pc_forget_closed_overlay(@resident) if @resident
   end
   def deactivate
    stop_resident
    super
   end
   def poll_resident
    return unless @resident
    @resident_metrics=JSON.parse(ResidentAPI.pc_stats(@resident).to_s)
    state=@resident_metrics['state']
    if state==2
     unless @resident_attached
      if ResidentAPI.pc_attach(@resident)!=0
       @resident_metrics=JSON.parse(ResidentAPI.pc_stats(@resident).to_s)
       raise @resident_metrics['error']
      end
      @resident_attached=true;@model.active_view.invalidate
     end
     @frame_full=@resident_metrics['frames']>0
     mode = gaussian? ? '主视窗高斯参照' : '连续全量点云'
     @frame_info=@resident_metrics.merge('render_mode'=>gaussian? ? 'gaussian' : 'continuous_full','display_points'=>@resident_metrics['visible_pixels'])
     if !@job || @job[:kind]==:mesh
      @message=@frame_full ? "GPU · #{@resident_metrics['gpu']} · #{mode} #{@cloud['indexed_points']} · 本帧 #{@resident_metrics['frame_ms'].round(1)} ms" : '完整数据已驻留显存，正在生成第一帧…'
     end
    elsif state<0
     @frame_full=false;@message="原生全量显示失败：#{@resident_metrics['error']}"
     UI.stop_timer(@resident_timer);@resident_timer=nil
    else
     @message="参照数据上传中：#{@resident_metrics['loaded_points']} / #{@cloud['indexed_points']}。"
    end
    now=Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @resident_publish_state!=state || !@resident_publish_at || now-@resident_publish_at>=1.0
     @resident_publish_state=state;@resident_publish_at=now;PointCloud.publish
    end
   rescue StandardError=>e
    @frame_full=false;@message="原生全量显示未完成：#{e.message}";PointCloud.publish
    UI.stop_timer(@resident_timer) if @resident_timer;@resident_timer=nil
   end
   def info
    value=super
    if value[:cloud] && @resident
     value[:cloud][:gaussian]=gaussian?
     value[:cloud][:continuous_full]=true
     value[:cloud][:full_resolution]=@frame_full
     value[:cloud][:visible]=@resident_metrics.fetch('visible_pixels',0)
     value[:cloud][:frame]=@resident_metrics
    end
    value
   end
   def resident_options
    return unless @resident
    if gaussian? && ResidentAPI.pc_set_gaussian_opacity(@resident,@options.fetch('gaussian_opacity') / 100.0)!=0
     raise '高斯参照不透明度无效。'
    end
    flags=(@options['clip'] ? 1 : 0) | (@options['slice'] ? 2 : 0) | (@options['visible'] ? 4 : 0)
    values=%w[x y z angle].map { |k| @options.fetch(k).to_f }+(@options['clip']||[0.0]*6)+%w[slice_z slice_width].map { |k| @options.fetch(k).to_f }
    data=values.pack('d*')+[flags,%w[rgb gray height].index(@options['color'])||0].pack('L<*')
    raise '原生绘制参数不完整' unless data.bytesize==104 && ResidentAPI.pc_options(@resident,data)==0
   end
   def rebuild
    return super unless @resident
    @revision+=1;update_index_bounds
    clip=@options['clip'];@clip_box=nil
    if clip
     @clip_box=Geom::BoundingBox.new
     @clip_box.add(Geom::Point3d.new(*clip[0,3].map { |v|v*M_TO_IN }))
     @clip_box.add(Geom::Point3d.new(*clip[3,3].map { |v|v*M_TO_IN }))
    end
    resident_options;@model.active_view.invalidate
   end
   def queue_refresh
    return super unless @resident
    # SU invokes the native begin_frame callback for the current camera itself.
    # No debounce, preview replacement, disk IPC or Ruby point reconstruction.
    @model.active_view.invalidate
   end
   def resident_pick(x,y,view)
    return nil unless @resident && @frame_full && @options['visible']
    out="\0"*32
    return nil unless ResidentAPI.pc_pick(@resident,x.to_f,y.to_f,10.0,view.vpwidth.to_f,view.vpheight.to_f,out)==1
    p=Geom::Point3d.new(out.unpack('d3'));screen=view.screen_coords(p)
    return nil if Math.hypot(screen.x-x,screen.y-y)>11
    hit=@model.raytest(view.pickray(x,y),true);eye=view.camera.eye;direction=view.camera.direction
    return nil if hit && (p-eye).dot(direction)>(hit[0]-eye).dot(direction)+0.03.m
    @last_full_pick={'source_id'=>out.byteslice(24,8).unpack1('Q<'),'world_m'=>p.to_a.map { |v|v/M_TO_IN },'method'=>'resident_gpu_frame'}
    p
   end
   def ensure_query_worker
    raise '高斯参照支持剪切盒和描图。点数统计和裁剪 PLY 导出仅用于普通点云。' if gaussian?
    return if @worker_pid
    @ipc=File.join(ENV.fetch('LOCALAPPDATA'),'SHARE3DCAM','PointCloudSessions',SecureRandom.uuid);FileUtils.mkdir_p(@ipc)
    exe=ENGINE;log=File.join(@ipc,'process.log')
    @worker_pid=Process.spawn(exe,'--serve','--cache',@index_folder,'--session',@ipc,'--parent',Process.pid.to_s,out:log,err:log)
    @requests={};@want_refresh=false
    @worker_timer=UI.start_timer(0.12,true) { PointCloud.safely { poll_worker } }
   end
   def full_stats;ensure_query_worker;super;end
   def export_full;ensure_query_worker;super;end
  end
  Session.prepend(ResidentViewport)
 end
end
