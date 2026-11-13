# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    # Draw source-coordinate visibility winners in 3D. There is no image overlay
    # and no fixed point cap: SU still performs its normal entity depth test.
    # Keep source-coordinate picking separate from tiny line endpoints used
    # by the stable native renderer. Materialize source points only on demand.
    class FramePoints
      include Enumerable
      def initialize(values);@values=values;end
      def size;@values.size/3;end
      def [](i);Geom::Point3d.new(@values[i*3,3]) if i>=0 && i<size;end
      def each
        return enum_for(:each) unless block_given?
        @values.each_slice(3) { |p| yield Geom::Point3d.new(p) }
      end
    end
    module FullViewport

      def frame_pick(x,y,view)
        return nil unless @frame_full && @frame_generation==@generation && @pixel_grid && @full_points
        eye=view.camera.eye;direction=view.camera.direction
        camera=@frame_camera;w=@frame_info['render_width'];h=@frame_info['render_height']
        sx=w.to_f/camera['width'];sy=h.to_f/camera['height'];best=nil;score=nil;seen={}
        xmin=[((x-10)*sx-1).floor,0].max;xmax=[((x+10)*sx+1).ceil,w-1].min
        ymin=[((y-10)*sy-1).floor,0].max;ymax=[((y+10)*sy+1).ceil,h-1].min
        (ymin..ymax).each do |py|
          (xmin..xmax).each do |px|
            index=@pixel_grid[py*w+px];next if !index || index<0 || seen[index]
            seen[index]=true;p=@full_points[index];screen=view.screen_coords(p)
            distance=(screen.x-x)**2+(screen.y-y)**2;next if distance>100
            depth=(p-eye).dot(direction)
            rank=[distance,depth,@source_ids ? @source_ids[index] : index]
            if !score || (rank<=>score)==-1;best=[p,index];score=rank;end
          end
        end
        return nil unless best
        hit=@model.raytest(view.pickray(x,y),true)
        return nil if hit && (best[0]-eye).dot(direction)>(hit[0]-eye).dot(direction)+0.03.m
        @last_full_pick={'source_id'=>@source_ids && @source_ids[best[1]],'world_m'=>best[0].to_a.map { |v| v/M_TO_IN },'method'=>'visible_frame'}
        best[0]
      end
      def camera_snapshot
        c=@model.active_view.camera
        {'eye'=>c.eye.to_a.map(&:to_f),'target'=>c.target.to_a.map(&:to_f),'up'=>c.up.to_a.map(&:to_f),
         'perspective'=>c.perspective?,'fov'=>c.fov.to_f,'height'=>c.perspective? ? nil : c.height.to_f}
      end

      def restore_camera(saved)
        %w[eye target up].each do |key|
          values=saved[key]
          raise '已保存相机参数无效' unless values.is_a?(Array) && values.size==3 && values.all? { |v| v.is_a?(Numeric) && v.finite? }
        end
        camera=Sketchup::Camera.new(saved['eye'],saved['target'],saved['up'],saved['perspective']==true)
        if saved['perspective']
          camera.fov=Float(saved['fov'])
        else
          camera.height=Float(saved['height'])
        end
        @model.active_view.camera=camera
        queue_refresh
      end

      def info
        result=super
        if result[:cloud]
          result[:cloud][:full_resolution]=!!@frame_full
          result[:cloud][:visible]=@frame_info['display_points'] if @frame_full && @frame_info
        end
        result
      end

      def load_cache(cache)
        @prepare_token=nil;@frame_full=false;@pixel_grid=nil;@full_points=nil;@preview_batches=nil
        super
      end

      def queue_refresh
        before=@generation
        super
        return if before==@generation || !@frame_full || @accepting_frame || @switching_preview
        # Retain a light temporary preview during orbit/pan. This preview is
        # explicitly replaced by the uncapped full-resolution stop frame.
        @switching_preview=true
        @frame_full=false;@frame_exact=false
        @pixel_grid=nil;@full_points=nil;@source_ids=nil
        @batches=@preview_batches;@points=@preview_points;@revision+=1
        @model.active_view.invalidate
        @message='交互预览中；停止后自动补齐全分辨率。'
        PointCloud.publish
      ensure
        @switching_preview=false
      end

      def rebuild
        unless @frame_full
          return super
        end
        # Full frames are immutable; changed options request a replacement.
        queue_refresh unless @accepting_frame
      end

      def accept_frame(result)
        unless result['render_mode']=='full_visibility'
          @frame_full=false
          return super
        end
        n=Integer(result.fetch('display_points'))
        pixels=Integer(result.fetch('render_width'))*Integer(result.fetch('render_height'))
        raise '全分辨率帧大小无效' unless n.between?(0,pixels) && pixels.between?(1,67_108_864)
        xyz=File.binread(File.join(@ipc,File.basename(result.fetch('xyz'))))
        rgb=File.binread(File.join(@ipc,File.basename(result.fetch('rgb'))))
        raise '全分辨率帧不完整' unless result['xyz_type']=='float64' && xyz.bytesize==n*24 && rgb.bytesize==n*3
        vertices=File.binread(File.join(@ipc,File.basename(result.fetch('vertices'))))
        raise '绘制顶点格式不匹配' unless result['primitive']=='lines' && vertices.bytesize==n*48
        vertex_values=vertices.unpack('E*');raise '绘制顶点无效' unless vertex_values.all?(&:finite?)
        values=xyz.unpack('E*');raise '全分辨率帧含无效坐标' unless values.all?(&:finite?)
        raise '绘制坐标版本不匹配，请完整更新插件' unless result['xyz_space']=='world_inches'
        grid=File.binread(File.join(@ipc,File.basename(result.fetch('grid'))))
        ids=File.binread(File.join(@ipc,File.basename(result.fetch('ids'))))
        raise '捕捉像素索引不完整' unless grid.bytesize==pixels*4 && ids.bytesize==n*8
        pixel_grid=grid.unpack('l<*');source_ids=ids.unpack('Q<*')
        raise '捕捉像素索引超出范围' unless pixel_grid.all? { |i| i>=-1 && i<n }
        groups=result.fetch('native_groups')
        raise '绘制颜色分组不完整' unless groups.sum { |g| Integer(g['count']) }==n
        generation=@generation;camera=camera_data;token=Object.new;@prepare_token=token
        @frame_full=false;@pixel_grid=nil
        started=Time.now;cpu=0.0;max_chunk=0.0;full=FramePoints.new(values);preview=[];batches=[];preview_batches=[];offset=0
        step=[(n.to_f/@options.fetch('budget',50_000)).ceil,1].max
        group_index=0;remaining=0;color=nil
        advance=nil
        advance=proc do
          next unless @prepare_token.equal?(token) && @generation==generation
          begin
            tick=Process.clock_gettime(Process::CLOCK_MONOTONIC)
            while group_index<groups.size || remaining>0
              if remaining==0
                group=groups[group_index];group_index+=1
                remaining=Integer(group['count']);raise '绘制分组大小无效' unless remaining>=0 && remaining<=n
                color=Sketchup::Color.new(*group.fetch('color'))
                next if remaining==0
              end
              take=[2046,remaining].min
              points=vertex_values.slice(offset*6,take*6).each_slice(3).map { |p| Geom::Point3d.new(p) }
              batches << [color,points]
              chosen=[];j=(-offset)%step
              while j<take
                preview << full[offset+j];chosen << points[j*2] << points[j*2+1];j+=step
              end
              preview_batches << [color,chosen] unless chosen.empty?
              offset+=take;remaining-=take
              break if Process.clock_gettime(Process::CLOCK_MONOTONIC)-tick>=0.015
            end
            elapsed=Process.clock_gettime(Process::CLOCK_MONOTONIC)-tick;cpu+=elapsed;max_chunk=[max_chunk,elapsed].max
            if remaining==0 && group_index==groups.size
              @frame_info=result;@frame_generation=generation;@frame_exact=true;@frame_camera=camera
              @pixel_grid=pixel_grid;@source_ids=source_ids;@full_points=full
              @preview_points=preview;@preview_batches=preview_batches;@points=preview;@batches=batches
              @frame_full=true;@rendered_full_count=n;@revision+=1;@prepare_token=nil
              result['native_prepare_seconds']=cpu;result['native_max_chunk_seconds']=max_chunk
              result['native_elapsed_seconds']=Time.now-started
              update_index_bounds;persist;@model.active_view.invalidate
              engine=result['engine']=='opencl_gpu' ? "GPU · #{result['gpu_device']}" : "CPU回退：#{result['gpu_fallback']}"
              @message="#{engine}；全量后台 #{result['compute_seconds']} 秒，SU准备 #{cpu.round(2)} 秒；可见 #{n} 点。"
              PointCloud.publish
            else
              UI.start_timer(0.001,false) { PointCloud.safely(&advance) }
            end
          rescue StandardError => e
            @prepare_token=nil;@message="点云绘制准备失败：#{e.message}";PointCloud.publish
          end
        end
        UI.start_timer(0.001,false) { PointCloud.safely(&advance) }
      end

    end
    Session.prepend(FullViewport)
  end
end
