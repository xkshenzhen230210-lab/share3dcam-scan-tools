# encoding: UTF-8
# Full-resolution data remains in the external index; SU owns only a bounded frame.
module SHARE3DCAM
  module PointCloud
    class CloudViewEvents < Sketchup::ViewObserver
      def initialize(session); @session=session; end
      def onViewChanged(_view)
        PointCloud.safely { @session.queue_refresh }
      end
    end

    module FullSession
      def full_index?; @cloud && @cloud['schema']==2; end

      def info
        value=super
        if value[:cloud]
          value[:cloud][:full_index]=full_index?
          value[:cloud][:indexed]=@cloud['indexed_points'] || 0
          value[:cloud][:frame]=@frame_info
          value[:cloud][:roi_count]=@roi_count
        end
        value
      end

      def load_cache(cache)
        stop_worker
        @index_folder=File.expand_path(cache)
        @frame_exact=false;@frame_info=nil;@frame_generation=nil;@roi_count=nil
        super
        start_worker if full_index?
      end

      def deactivate
        stop_worker
        super
      end

      def rebuild
        super
        if full_index?
          update_index_bounds
          queue_refresh unless @accepting_frame
        end
      end

      def update_index_bounds
        low,high=@cloud['bounds_local_m'];box=Geom::BoundingBox.new
        a=@options['angle']*Math::PI/180;c=Math.cos(a);s=Math.sin(a)
        [low[0],high[0]].product([low[1],high[1]],[low[2],high[2]]).each do |x,y,z|
          box.add(Geom::Point3d.new((x*c-y*s+@options['x'])*M_TO_IN,
                                  (x*s+y*c+@options['y'])*M_TO_IN,(z+@options['z'])*M_TO_IN))
        end
        @bounds=box
      end

      def camera_data
        view=@model.active_view;camera=view.camera
        right=camera.xaxis.normalize;up=camera.yaxis.normalize;forward=camera.direction.normalize
        target=camera.target;center=view.screen_coords(target)
        sx=view.screen_coords(target.offset(right,1.m));sy=view.screen_coords(target.offset(up,1.m))
        depth=(target-camera.eye).dot(forward).to_f/M_TO_IN
        fx=(sx.x-center.x).to_f;fy=(center.y-sy.y).to_f
        raise '当前相机不能用于点云捕捉，请切换标准透视或平行投影。' unless fx>0 && fy>0 && depth>0
        fx*=depth if camera.perspective?;fy*=depth if camera.perspective?
        data={'eye'=>camera.eye.to_a.map { |n| n.to_f/M_TO_IN },'right'=>right.to_a,
              'up'=>up.to_a,'forward'=>forward.to_a,'cx'=>center.x.to_f,'cy'=>center.y.to_f,
              'fx'=>fx,'fy'=>fy,'width'=>view.vpwidth,'height'=>view.vpheight,'perspective'=>camera.perspective?}
        data['render_width']=view.respond_to?(:device_width) ? view.device_width : view.vpwidth
        data['render_height']=view.respond_to?(:device_height) ? view.device_height : view.vpheight
        # Calibrate to SU's own screen_coords, including DPI/version differences.
        [target.offset(right,0.7.m).offset(up,0.3.m),target.offset(forward,0.2.m).offset(right,0.4.m)].each do |p|
          d=p-camera.eye;z=d.dot(forward).to_f/M_TO_IN;den=camera.perspective? ? z : 1.0
          x=data['cx']+d.dot(right).to_f/M_TO_IN*fx/den;y=data['cy']-d.dot(up).to_f/M_TO_IN*fy/den
          actual=view.screen_coords(p)
          raise '当前两点透视或倾斜相机暂不支持精确捕捉，请切换标准视图。' if (actual.x-x).abs>0.5 || (actual.y-y).abs>0.5
        end
        data
      end

      def queue_refresh
        return unless full_index?
        signature=JSON.generate([camera_data,@options])
        return if signature==@last_view_signature
        @last_view_signature=signature;@generation=@generation.to_i+1
        @want_refresh=true;@refresh_after=Time.now+0.3
      rescue StandardError => e
        @message=e.message
      end

      def start_worker
        @ipc=File.join(ENV.fetch('LOCALAPPDATA'),'SHARE3DCAM','PointCloudSessions',SecureRandom.uuid)
        FileUtils.mkdir_p(@ipc)
        exe=ENGINE;log=File.join(@ipc,'process.log')
        @worker_pid=Process.spawn(exe,'--serve','--cache',@index_folder,'--session',@ipc,'--parent',Process.pid.to_s,out:log,err:log)
        @requests={};@last_view_signature=nil
        @view_observer=CloudViewEvents.new(self);@observed_view=@model.active_view;@observed_view.add_observer(@view_observer)
        @worker_timer=UI.start_timer(0.12,true) { PointCloud.safely { poll_worker } }
        queue_refresh
      end

      def stop_worker
        @prepare_token=nil
        UI.stop_timer(@worker_timer) if @worker_timer
        begin
          @observed_view.remove_observer(@view_observer) if @observed_view && @view_observer
        rescue StandardError => e
          # Opening an SKP deletes the old native View before onOpenModel fires.
          # Its observer is already gone; this must not abort session replacement.
          warn("[赛尔点云] 旧视图已关闭：#{e.message}")
        end
        if @worker_pid
          begin
            write_request('stop',{}) if @ipc && File.directory?(@ipc)
            Process.detach(@worker_pid)
          rescue Errno::ECHILD
            nil
          end
        end
        @worker_pid=nil;@worker_timer=nil;@observed_view=nil;@view_observer=nil
        @requests={};@view_request=nil;@pick_request=nil;@want_refresh=false
      end

      def write_request(action,data,&callback)
        token=SecureRandom.uuid.delete('-')
        request={'action'=>action,'generation'=>@generation,'options'=>@options}.merge(data)
        path=File.join(@ipc,"req_#{token}.json")
        File.write(path+'.tmp',JSON.generate(request),encoding:'UTF-8');File.rename(path+'.tmp',path)
        (@requests ||= {})[token]={action:action,generation:@generation,callback:callback,start:Time.now}
        token
      end

      def poll_worker
        return unless @worker_pid
        @requests.keys.each do |token|
          path=File.join(@ipc,"res_#{token}.json")
          next unless File.file?(path)
          response=JSON.parse(File.read(path,encoding:'UTF-8'));File.delete(path)
          request=@requests.delete(token)
          @view_request=nil if token==@view_request
          @pick_request=nil if token==@pick_request
          current=request[:generation]==@generation
          if !response['ok']
            @message="全量查询失败：#{response['error']}";PointCloud.publish
          elsif %w[view full_view].include?(request[:action])
            accept_frame(response['result']) if current
          elsif current || request[:action]=='export'
            request[:callback].call(response['result']) if request[:callback]
          else
            @message='视图或裁剪已变化，请在当前视图重新捕捉。';PointCloud.publish
          end
          %W[frame_#{token}.f32 frame_#{token}.f64 frame_#{token}.u8 frame_#{token}.i32 frame_#{token}.ids frame_#{token}.v64].each do |name|
            file=File.join(@ipc,name);File.delete(file) if File.file?(file)
          end
        end
        if @want_refresh && !@view_request && Time.now>=@refresh_after && File.file?(File.join(@ipc,'ready.json'))
          @want_refresh=false
          @view_request=write_request('full_view',{'camera'=>camera_data})
          @message='正在补齐全分辨率显示…全量原始点参与计算，不按10万点截断。'
          PointCloud.publish
        end
        dead=Process.waitpid(@worker_pid,Process::WNOHANG)
        if dead
          @worker_pid=nil;stop_worker;@message='点云查询进程已退出，请重新载入缓存。';PointCloud.publish
        elsif @requests.values.any? { |r| Time.now-r[:start]>180 }
          @message='全量查询仍在进行，大范围高密点云需要更长时间。';PointCloud.publish
        end
      rescue JSON::ParserError
        nil
      rescue StandardError => e
        @message="全量查询未完成：#{e.message}";PointCloud.publish
      end

      def accept_frame(result)
        n=Integer(result.fetch('display_points'))
        raise '视图数据超过显示预算' unless n.between?(0,100_000)
        xyz=File.binread(File.join(@ipc,File.basename(result.fetch('xyz'))))
        rgb=File.binread(File.join(@ipc,File.basename(result.fetch('rgb'))))
        raise '视图分块不完整' unless xyz.bytesize==n*12 && rgb.bytesize==n*3
        values=xyz.unpack('e*');raise '视图坐标无效' unless values.all?(&:finite?)
        @base_xyz=values.each_slice(3).to_a
        @base=@base_xyz.map { |p| Geom::Point3d.new(*p.map { |v| v*M_TO_IN }) }
        @rgb=rgb.unpack('C*');@frame_info=result;@frame_generation=@generation;@frame_exact=true;@accepting_frame=true
        rebuild
        @message="全量索引 #{@cloud['indexed_points']} 点；当前视图 #{n} 点。放大或切片后自动读取细节。"
        PointCloud.publish
      ensure
        @accepting_frame=false
      end

      def query_pick(x,y,view,&callback)
        return false if @pick_request
        raise '全量查询尚未就绪，请稍候。' unless @worker_pid && File.file?(File.join(@ipc,'ready.json'))
        camera=camera_data;depth=nil;hit=@model.raytest(view.pickray(x,y),true)
        depth=(hit[0]-view.camera.eye).dot(view.camera.direction).to_f/M_TO_IN+0.03 if hit
        @pick_request=write_request('pick',{'camera'=>camera,'x'=>x.to_f,'y'=>y.to_f,'max_depth'=>depth}) do |result|
          p=result['pick'];@last_full_pick=p
          callback.call(p && Geom::Point3d.new(*p['world_m'].map { |v| v*M_TO_IN }))
        end
        @message='正在全量分块中精确捕捉…';PointCloud.publish
        true
      end

      def full_stats
        require_cloud;raise '旧版缓存只有抽样点，请重新导入源文件。' unless full_index?
        raise '查询进程不可用，请重新载入缓存。' unless @worker_pid
        write_request('stats',{}) do |result|
          @roi_count=result['count'];@message="当前裁剪及切片实际包含 #{@roi_count} 个全量点。";PointCloud.publish
        end
        @message='正在统计全量裁剪范围…'
      end

      def export_full
        require_cloud;raise '旧版缓存只有抽样点，请重新导入源文件。' unless full_index?
        raise '查询进程不可用，请重新载入缓存。' unless @worker_pid
        path=PointCloud.savepanel('导出全量裁剪点云（原始坐标，米）','','点云全量裁剪.ply');return unless path
        path+='.ply' unless File.extname(path).downcase=='.ply'
        write_request('export',{'path'=>path}) do |result|
          @message="已导出 #{result['count']} 点：#{File.basename(result['path'])}。坐标为原始坐标（米），未应用参照平移旋转。"
          PointCloud.publish
        end
        @message='正在导出全量裁剪点云…'
      end

      def apply(data,save=true)
        return if data.all? { |key,value| @options[key]==value }
        @frame_full=false;@pixel_grid=nil;@full_points=nil
        region_keys=%w[clip slice slice_z slice_width x y z angle]
        @roi_count=nil if region_keys.any? { |k| data.key?(k) && data[k]!=@options[k] }
        if data.key?('budget')
          value=Integer(data['budget']);raise '显示预算须为1万至10万点' unless value.between?(10_000,100_000)
          @options['budget']=value
        end
        @frame_exact=false unless @accepting_frame
        super
      end

      def save_to(path)
        return super unless full_index? || gaussian?
        require_cloud
        name="#{File.basename(path,'.skp')}_点云数据";folder=File.join(File.dirname(path),name)
        source=@index_folder
        existing=File.join(folder,'cloud.json')
        if File.file?(existing) && File.expand_path(folder)!=source
          previous_meta=JSON.parse(File.read(existing,encoding:'UTF-8'))
          raise '同名点云数据文件夹属于其他数据，请换一个工程文件名。' unless %w[source_path source_bytes source_mtime_ns schema].all? { |k| previous_meta[k]==@cloud[k] }
        end
        files = if gaussian?
                  %w[cloud.json gaussians.bin harmonics.bin]
                else
                  %w[cloud.json xyz.f32 rgb.u8]+@cloud['tiles'].flat_map { |t| [t.fetch('file'),t.fetch('lod')] }
                end
        files.each do |file|
          a=File.expand_path(file,source);b=File.expand_path(file,folder)
          raise '索引文件路径无效' unless a.start_with?(source+File::SEPARATOR) && b.start_with?(File.expand_path(folder)+File::SEPARATOR)
          next if a==b
          FileUtils.mkdir_p(File.dirname(b));FileUtils.cp(a,b)
          raise '全量索引复制不完整' unless File.size(a)==File.size(b)
        end
        previous=@cache;@cache=name;persist
        unless @model.save(path)
          @cache=previous;persist;raise 'SKP保存失败，原索引仍保留。'
        end
        @message='已保存 SKP 和完整参照索引。移动工程时请同时复制同名点云数据文件夹。'
      end
    end
    Session.prepend(FullSession)
  end
end
