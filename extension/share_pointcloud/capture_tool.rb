# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    class CaptureTool
      def initialize(session, mode)
        @session=session; @mode=mode; @vertices=[]; @edges=[]; @axis=nil
      end
      def activate
        if @mode=='level'
          Sketchup.set_status_text('单击干净地面读取模型Z标高；Esc返回。高斯取点应在邻近位置复核。')
          Sketchup.vcb_label='模型 Z'
          return
        end
        ensure_plan_view if @mode=='trace' && @session.options['plane']
        Sketchup.set_status_text('单击全量捕捉；描线可用方向键锁轴，尺寸框输入3m或3000mm；右键结束。')
        Sketchup.vcb_label = '线段长度'
      end
      def enableVCB?
        @mode=='trace'
      end
      def screen_index(view)
        camera=view.camera
        # Parallel zoom changes height without changing eye/target; invalidate picks too.
        scale=camera.perspective? ? camera.fov : camera.height
        key=(camera.eye.to_a+camera.target.to_a+camera.up.to_a+[scale,camera.aspect_ratio]).map(&:to_f).pack('d*') + [camera.perspective? ? 1 : 0,view.vpwidth,view.vpheight,@session.revision].pack('L*')
        return if key==@screen_key
        @screen_key=key; @index={}
        eye=camera.eye; direction=camera.direction
        @session.points.each do |p|
          next unless (p-eye).dot(direction)>0
          screen=view.screen_coords(p); x=screen.x; y=screen.y
          next unless x.finite? && y.finite? && x.between?(-16,view.vpwidth+16) && y.between?(-16,view.vpheight+16)
          cell=[(x/16).floor,(y/16).floor]
          (@index[cell] ||= []) << [x,y,p,(p-eye).dot(direction)]
        end
      end
      def pick(x,y,view)
        return nil unless @session.options['visible']
        return @session.resident_pick(x,y,view) if @session.respond_to?(:resident?) && @session.resident?
        if @session.instance_variable_get(:@frame_full) && @session.instance_variable_get(:@pixel_grid)
          return @session.frame_pick(x,y,view)
        end
        screen_index(view)
        cell=[(x/16).floor,(y/16).floor]; best=nil; score=nil
        (-1..1).each do |dx|
          (-1..1).each do |dy|
            (@index[[cell[0]+dx,cell[1]+dy]] || []).each do |sx,sy,p,depth|
              distance=(sx-x)**2+(sy-y)**2
              next if distance>100
              if !score || distance<score[0] || (distance==score[0] && depth<score[1])
                best=p;score=[distance,depth]
              end
            end
          end
        end
        if best
          ray=view.pickray(x,y)
          hit=@session.model.raytest(ray,true)
          if hit
            direction=ray[1].normalize
            return nil if (best-ray[0]).dot(direction)>(hit[0]-ray[0]).dot(direction)+0.03.m
          end
        end
        best
      end
      def projected(point)
        return point if @mode!='trace'
        p=point.clone
        p.z=@session.options['plane_z']*M_TO_IN if @session.options['plane']
        if @axis && !@vertices.empty?
          a=@vertices.last
          p=Geom::Point3d.new(p.x,a.y,a.z) if @axis==:x
          p=Geom::Point3d.new(a.x,p.y,a.z) if @axis==:y
          p=Geom::Point3d.new(a.x,a.y,p.z) if @axis==:z
        end
        p
      end
      def onMouseMove(_flags,x,y,view)
        return if PointCloud.drawing?
        old=@hover;old_source=@source;@source=pick(x,y,view); @hover=@source && projected(@source)
        if @mode=='level'
          view.tooltip=@hover ? format('模型标高 Z = %.4f m，单击读取',@hover.z/M_TO_IN) : '请对准地面可见扫描点'
        else
        view.tooltip=@hover ? (@session.options['plane'] && @mode=='trace' ? '俯视平面描图；按指定标高落线' : '三维原点捕捉；红框与实际落点一致') : '靠近可见点捕捉；裁剪或放大可减少前后点重叠'
        end
        if @mode=='level' && @hover
          Sketchup.vcb_value=format('%.4f m',@hover.z/M_TO_IN)
        elsif @hover && !@vertices.empty?
          Sketchup.vcb_value=format('%.4f m',@vertices.last.distance(@hover)/M_TO_IN)
        end
        view.invalidate unless old==@hover && old_source==@source
      end
      def onLButtonDown(flags,x,y,view)
        PointCloud.safely { capture_click(flags,x,y,view) }
      end
      def capture_click(_flags,x,y,view)
        return UI.beep unless @session.options['visible']
        if (@session.respond_to?(:resident?) && @session.resident?) || (@session.instance_variable_get(:@frame_full) && @session.instance_variable_get(:@pixel_grid))
          accept_capture(pick(x,y,view),view)
        elsif @session.full_index?
          @session.query_pick(x,y,view) do |point|
            next unless @session.model.tools.active_tool==self
            accept_capture(point,view)
          end
        else
          accept_capture(pick(x,y,view),view)
        end
      rescue StandardError => e
        PointCloud.report(e)
      end
      def accept_capture(p,view)
        unless p
          Sketchup.set_status_text('这一点没有捕捉到。请移到可见的扫描点上，出现红框后再单击。') if @mode=='trace'
          return UI.beep
        end
        if @mode=='level'
          @vertices=[p];@session.read_elevation(p)
        elsif @mode=='anchor'
          @session.model.start_operation('点云采辅助点',true)
          @session.model.entities.add_cpoint(p)
          @session.model.commit_operation
          @session.message='已创建原生辅助点，可切换SU原生工具吸附。'
          PointCloud.publish
        elsif @mode=='measure'
          @vertices=[] if @vertices.size>=2
          @vertices << p
          if @vertices.size==2
            @session.message=format('两点距离 %.4f m（%s，须校核扫描精度）',@vertices[0].distance(p)/M_TO_IN,@session.full_index? ? '全量原始点捕捉' : '旧版显示样本')
            PointCloud.publish
          end
        else
          if commit_point(projected(p))
            Sketchup.set_status_text(@vertices.length==1 ? '起点已确认，请单击终点。' : '已创建原生线段。可继续描线，或右键结束。')
          end
        end
        view.invalidate
      rescue StandardError => e
        @session.model.abort_operation rescue nil
        PointCloud.report(e)
      end
      def commit_point(p)
        if !@vertices.empty?
          if @vertices.last.distance(p)<0.1.mm
            Sketchup.set_status_text('两点重合或过近。请重新选终点，或检查锁轴和平面标高。')
            UI.beep
            return false
          end
          @session.model.start_operation('点云捕捉描线',true)
          begin
            unless @group && @group.valid?
              @group=@session.model.entities.add_group
              @group.name='点云描线'
              @group.set_attribute(DICT,'source',@session.cloud['source_name'])
            end
            edge=@group.entities.add_line(@vertices.last,p)
            raise 'SketchUp 未能创建此线段，请重新选择终点。' unless edge && edge.valid?
            @session.model.commit_operation
            @edges << edge
          rescue StandardError
            @session.model.abort_operation
            raise
          end
        end
        @vertices << p
        true
      end
      def onUserText(text,view)
        PointCloud.safely { user_length(text,view) }
      end
      def user_length(text,view)
        return unless @mode=='trace' && @hover && !@vertices.empty?
        length=text.to_l
        raise '请输入大于0的长度，例如3m或3000mm' unless length>0
        direction=@hover-@vertices.last
        raise '先用鼠标确定线段方向' if direction.length<0.001
        commit_point(@vertices.last.offset(direction,length))
        view.invalidate
      rescue StandardError => e
        UI.messagebox(e.message)
      end
      def self.prompt_extrusion(session, group)
        input = UI.inputbox(['向上拉伸高度（米）'], [2.8], '拉伸描线面')
        extrude_profile(session, group, input.first) if input
      end

      def self.native_pushpull(session, target = nil)
        model = session.model
        target ||= model.selection.first if model.selection.size == 1
        if target.is_a?(Sketchup::Group)
          unless target.valid? && !target.locked? && model.active_entities.include?(target)
            raise ArgumentError, '请选中当前层级中未锁定的描线群组。'
          end
          faces = target.entities.grep(Sketchup::Face)
          raise ArgumentError, '群组内没有面，请先闭合轮廓成面。' if faces.empty?
          model.active_path = (model.active_path || []) + [target]
          model.selection.clear
          model.selection.add(faces.first) if faces.size == 1
        elsif !target.is_a?(Sketchup::Face) || !model.active_entities.include?(target)
          raise ArgumentError, '先单击选中底面群组，或双击进入群组后选中面。'
        end
        Sketchup.send_action('selectPushPullTool:')
        Sketchup.focus
        model.active_view.invalidate
        Sketchup.set_status_text('已进入面所在群组。单击面，移动鼠标确定推拉方向，再输入带单位的高度（例如 2.8m）并回车。')
        target
      end

      def self.extrude_profile(session, group, height_m)
        height = Float(height_m, exception: false)
        unless height&.finite? && height.positive?
          raise ArgumentError, '请输入大于 0 的拉伸高度（米）。'
        end

        model = session.model
        previous_path = model.active_path
        if (previous_path && previous_path != [group]) || !group.is_a?(Sketchup::Group) || !group.valid? || group.locked?
          raise ArgumentError, '请退出群组编辑，再选中一个未锁定的底面群组。'
        end

        faces = group.entities.grep(Sketchup::Face)
        unless faces.size == 1 && group.entities.length == faces.first.edges.length + 1
          raise ArgumentError, '需要一个只有一张闭合底面的描线群组。请先闭合成面。'
        end

        face = faces.first
        transform = group.transformation
        direction = face.normal.transform(transform)
        levels = face.vertices.map { |vertex| vertex.position.transform(transform).z.to_f }
        unless direction.valid? && direction.parallel?(Z_AXIS) && levels.max - levels.min < 0.01.mm
          raise ArgumentError, '底面需要水平。请开启「俯视平面描图」，按同一标高重新闭合成面。'
        end

        model.select_tool(nil)
        model.active_path = nil if previous_path
        model.start_operation('沿蓝轴向上拉伸描线面', true)
        begin
          group.make_unique
          group.entities.grep(Sketchup::Face).first.pushpull(height * M_TO_IN / direction.z)
          raise '未能生成闭合实体。请检查轮廓和拉伸高度。' unless group.manifold?

          model.commit_operation
        rescue StandardError
          model.abort_operation
          model.active_path = previous_path if previous_path
          raise
        end

        model.selection.clear
        model.selection.add(group)
        view = model.active_view
        camera = view.camera
        if camera.direction.z.abs > 0.98
          target = group.bounds.center
          offset = Geom::Vector3d.new(1, -1, 1)
          offset.length = [camera.eye.distance(camera.target), 1.m].max
          angle_view = Sketchup::Camera.new(target.offset(offset), target, Z_AXIS, camera.perspective?)
          angle_view.height = camera.height unless camera.perspective?
          view.camera = angle_view
        end
        view.invalidate
        Sketchup.set_status_text("已向上拉伸 #{height} 米，生成可编辑的 SU 实体群组。")
        group
      end

      def onKeyDown(key,_repeat,_flags,view)
        if PointCloud.drawing?
          PointCloud.safely { onKeyDown(key,_repeat,_flags,view) }
          return [VK_RIGHT,VK_LEFT,VK_UP].include?(key)
        end
        axis=case key
             when VK_RIGHT then :x
             when VK_LEFT then :y
             when VK_UP then @session.options['plane'] ? nil : :z
             end
        return false unless axis
        @axis=(@axis==axis ? nil : axis)
        @hover=projected(@source) if @source
        view.invalidate
        true
      end
      def onCancel(_reason,view)
        return @session.model.tools.pop_tool if @mode=='level' && _reason==0
        return PointCloud.safely { onCancel(_reason,view) } if PointCloud.drawing?
        @vertices=[];@edges=[];@group=nil;@axis=nil;view.invalidate
      end
      def getMenu(menu,*_args)
        if @mode=='trace'
          menu.add_item('闭合并尝试成面') do
            PointCloud.safely { close_path(edit_for_pushpull: true) }
          end
          if @session.gaussian? && @session.options['plane']
            menu.add_item('闭合并向上拉伸…') do
              PointCloud.safely do
                begin
                  group = @group
                  CaptureTool.prompt_extrusion(@session, group) if close_path
                rescue StandardError => error
                  UI.messagebox(error.message)
                end
              end
            end
          end
          menu.add_item('撤销上一点') do
            PointCloud.safely do
              if @vertices.size>1
                @session.model.start_operation('撤销描线末段',true)
                edge=@edges.pop;edge.erase! if edge && edge.valid?
                @session.model.commit_operation
              end
              @vertices.pop
              @session.model.active_view.invalidate
            end
          end
        end
        menu.add_item('结束工具（保留已画几何）') { PointCloud.safely { @session.model.select_tool(nil) } }
      end
      def close_path(edit_for_pushpull: false)
        points = @vertices.dup
        already_closed = points.size > 1 && points.first.distance(points.last) < 0.1.mm
        points.pop if already_closed
        if points.size < 3
          UI.messagebox('至少需要三个不同的点。')
          return nil
        end

        commit_point(points.first) unless already_closed
        model = @session.model
        model.start_operation('点云轮廓成面', true)
        begin
          face = @group.entities.add_face(points)
          if !face && already_closed
            face = @group.entities.grep(Sketchup::Face).find do |candidate|
              boundary = candidate.outer_loop.vertices.map(&:position)
              boundary.size == points.size && points.all? { |point| boundary.include?(point) }
            end
          end
          model.commit_operation
        rescue ArgumentError
          model.abort_operation
          face = nil
        rescue StandardError
          model.abort_operation
          raise
        end
        model.select_tool(nil)
        if !face
          UI.messagebox('闭合边已创建，但轮廓不共面或自交。请开启「俯视平面描图」，沿同一标高重新描线。')
        elsif edit_for_pushpull
          CaptureTool.native_pushpull(@session, @group)
        elsif @session.gaussian?
          model.selection.clear
          model.selection.add(@group)
          Sketchup.set_status_text('已闭合成原生面。可在「绘图」点击「向上拉伸描线面」。')
        end
        face
      end
      def resume(view)
        ensure_plan_view if @mode=='trace' && @session.options['plane']
        @screen_key=nil;view.invalidate
      end
      def ensure_plan_view
        view=@session.model.active_view;c=view.camera;target=c.target
        return if !c.perspective? && c.direction.dot(Z_AXIS)<-0.999999
        height=c.perspective? ? [@session.bounds.diagonal,1.m].max : c.height
        camera=Sketchup::Camera.new(target.offset(Z_AXIS,[@session.bounds.diagonal,1.m].max),target,Y_AXIS,false)
        camera.height=height;view.camera=camera
        @session.message='水平面描图已切到俯视平行投影；若需斜视三维捕捉，请取消“俯视平面描图”。'
        PointCloud.publish
      end
      def draw(view)
        PointCloud.with_draw { draw_preview(view) }
      end
      def draw_preview(view)
        if @source && @hover && @source.distance(@hover)>0.01.mm
          a=view.screen_coords(@source);x=a.x;y=a.y
          view.drawing_color='blue';view.line_width=1
          view.draw2d(GL_LINES,[[x-4,y,0],[x+4,y,0],[x,y-4,0],[x,y+4,0]])
          view.draw_text(a,' 原点（红框为锁轴/平面落点）',color:'blue',size:10)
        end
        view.drawing_color=Sketchup::Color.new(190,28,38)
        view.line_width=2
        gaussian_trace = @mode=='trace' && @session.gaussian?
        draw_gaussian_trace(view) if gaussian_trace
        view.draw(GL_LINE_STRIP,@vertices) if !gaussian_trace && @vertices.size>=2
        if @hover
          a=view.screen_coords(@hover);x=a.x;y=a.y
          view.draw2d(GL_LINE_LOOP,[[x-5,y-5,0],[x+5,y-5,0],[x+5,y+5,0],[x-5,y+5,0]])
          view.draw_line(@vertices.last,@hover) if !gaussian_trace && !@vertices.empty? && @vertices.last!=@hover
        end
        if @mode=='level' && !@vertices.empty?
          view.draw_text(view.screen_coords(@vertices.last),format(' Z = %.4f m',@vertices.last.z/M_TO_IN),color:'red',size:14)
        end
        if @mode=='measure' && @vertices.size==2
          screen=view.screen_coords(@vertices.last)
          view.draw_text(screen,format(' %.4f m',@vertices[0].distance(@vertices[1])/M_TO_IN),color:'red',size:14)
        end
      end

      def draw_gaussian_trace(view)
        # During tracing, show confirmed segments and the pending segment in
        # screen space. The committed native edges still occupy exact XYZ.
        camera = view.camera
        eye, direction = camera.eye, camera.direction
        points = @vertices.dup
        points << @hover if @hover && !points.empty? && points.last!=@hover
        screen = points.map do |point|
          next if (point-eye).dot(direction)<=0
          projected_point=view.screen_coords(point)
          Geom::Point3d.new(projected_point.x,projected_point.y,0) if projected_point.x.finite? && projected_point.y.finite?
        end
        lines = screen.each_cons(2).select { |first,second| first && second }.flatten
        return if lines.empty?

        view.drawing_color='white';view.line_width=5
        view.draw2d(GL_LINES,lines)
        view.drawing_color=Sketchup::Color.new(190,28,38);view.line_width=2
        view.draw2d(GL_LINES,lines)
      end
    end
  end
end
