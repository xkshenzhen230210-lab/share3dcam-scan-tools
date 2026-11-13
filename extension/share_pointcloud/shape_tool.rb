# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    # Scan anchors are world coordinates. Keep every profile horizontal so it
    # can be pushed/pulled without reproducing scan noise in the geometry.
    class ShapeTool
      NAMES = {'rectangle'=>'矩形', 'circle'=>'圆', 'polygon'=>'正多边形', 'arc'=>'圆心圆弧'}.freeze

      def initialize(session, kind, segments: 48, sides: 6)
        raise ArgumentError, '未知绘图工具' unless NAMES.key?(kind)
        @session, @kind = session, kind
        @segments = Integer(segments)
        @sides = Integer(sides)
        raise ArgumentError, '圆弧段数应为 12–360，边数应为 3–64' unless @segments.between?(12,360) && @sides.between?(3,64)
        @picker = CaptureTool.new(session, 'anchor')
        @vertices = []
      end

      def activate
        @picker.ensure_plan_view if @session.options['plane']
        update_prompt
      end

      def enableVCB?
        true
      end

      def update_prompt
        label = @kind=='rectangle' ? '长,宽' : (@kind=='arc' && @vertices.size==2 ? '逆时针角度' : '半径')
        Sketchup.vcb_label = label
        steps = if @vertices.empty?
                  @kind=='rectangle' ? '先在扫描上捕捉第一个角点' : '先在扫描上捕捉圆心'
                elsif @kind=='rectangle'
                  '单击对角点；或输入长,宽，例如 3m,200mm'
                elsif @kind=='arc' && @vertices.size==2
                  '逆时针选择终点方向；或输入角度，例如 90'
                else
                  '单击确定半径；或输入 500mm（半径，不是直径）'
                end
        Sketchup.set_status_text("#{NAMES[@kind]}：#{steps}。水平绘制；Esc 清除本次预览，右键结束。")
      end

      def point_at(x,y,view)
        return nil unless @session.options['visible']
        @source = @picker.pick(x,y,view)
        if @source
          point = @source.clone
          point.z = @session.options['plane'] ? @session.options['plane_z']*M_TO_IN : (@vertices.first || point).z
          point
        elsif !@vertices.empty?
          # After a real anchor is acquired, gaps in a scan must not prevent
          # placing the other corner/radius on the now-defined work plane.
          ray = view.pickray(x,y)
          point = Geom.intersect_line_plane(ray, [@vertices.first,Z_AXIS])
          point if point && (point-ray.first).dot(ray.last)>0
        end
      end

      def onMouseMove(_flags,x,y,view)
        return if PointCloud.drawing?
        @hover = point_at(x,y,view)
        view.tooltip = @source ? '扫描捕捉；红框为水平面实际落点' : (@hover ? '已确定的水平绘图平面' : '先在可见扫描点上捕捉起点')
        if @hover && !@vertices.empty?
          Sketchup.vcb_value = if @kind=='rectangle'
                                format('%.3f m, %.3f m',(@hover.x-@vertices.first.x).abs/M_TO_IN,(@hover.y-@vertices.first.y).abs/M_TO_IN)
                              elsif @kind=='arc' && @vertices.size==2
                                format('%.2f°',sweep(@hover)*180/Math::PI)
                              else
                                format('%.4f m',@hover.distance(@vertices.first)/M_TO_IN)
                              end
        end
        view.invalidate
      end

      def onLButtonDown(_flags,x,y,view)
        PointCloud.safely { accept_point(point_at(x,y,view),view) }
      end

      def accept_point(point,view)
        return UI.beep unless point
        point = point.clone
        point.z = @vertices.first.z unless @vertices.empty?
        if @vertices.empty?
          @vertices << point
        elsif @kind=='arc' && @vertices.size==1
          raise ArgumentError, '半径太小，请重新选取。' if point.distance(@vertices.first)<0.1.mm
          @vertices << point
        else
          commit_shape(point)
          @vertices.clear
          @hover = @source = nil
        end
        update_prompt
        view.invalidate
      rescue StandardError => error
        @session.message = error.message
        Sketchup.set_status_text(error.message)
        UI.beep
      end

      def sweep(point)
        a = @vertices[1]-@vertices[0]
        b = point-@vertices[0]
        (Math.atan2(b.y,b.x)-Math.atan2(a.y,a.x)) % (2*Math::PI)
      end

      def profile(point)
        center = @vertices.first
        return [] unless center
        if @kind=='rectangle'
          [center, Geom::Point3d.new(point.x,center.y,center.z), point, Geom::Point3d.new(center.x,point.y,center.z)]
        else
          radius = center.distance(@kind=='arc' && @vertices.size==2 ? @vertices[1] : point)
          angle = @kind=='polygon' ? Math.atan2(point.y-center.y,point.x-center.x) : 0
          angle = Math.atan2(@vertices[1].y-center.y,@vertices[1].x-center.x) if @kind=='arc' && @vertices.size==2
          span = @kind=='arc' && @vertices.size==2 ? sweep(point) : 2*Math::PI
          count = @kind=='polygon' ? @sides : [(@segments*span/(2*Math::PI)).ceil,2].max
          limit = @kind=='arc' ? count : count-1
          (0..limit).map { |i| Geom::Point3d.new(center.x+radius*Math.cos(angle+span*i/count),center.y+radius*Math.sin(angle+span*i/count),center.z) }
        end
      end

      def commit_shape(point)
        center = @vertices.first
        raise ArgumentError, '请先捕捉起点。' unless center
        if @kind=='rectangle'
          raise ArgumentError, '矩形的长和宽都应大于 0.1mm。' if (point.x-center.x).abs<0.1.mm || (point.y-center.y).abs<0.1.mm
        else
          radius = center.distance(@kind=='arc' ? @vertices[1] : point)
          raise ArgumentError, '半径应大于 0.1mm。' if radius<0.1.mm
          raise ArgumentError, '请选取不同的终点方向；完整圆请使用圆工具。' if @kind=='arc' && sweep(point)<0.001
        end
        model = @session.model
        raise ArgumentError, '请先退出群组编辑再绘制扫描轮廓。' if model.active_path
        model.start_operation("扫描参照绘制#{NAMES[@kind]}",true)
        begin
          group = model.entities.add_group
          group.name = "扫描绘制#{NAMES[@kind]}"
          group.set_attribute(DICT,'source',@session.cloud['source_name'])
          group.set_attribute(DICT,'shape',@kind)
          entities = group.entities
          if @kind=='circle'
            edges = entities.add_circle(center,Z_AXIS,radius,@segments)
            face = entities.add_face(edges)
          elsif @kind=='arc'
            axis = @vertices[1]-center
            span = sweep(point)
            edges = entities.add_arc(center,axis,Z_AXIS,radius,0,span,[(@segments*span/(2*Math::PI)).ceil,2].max)
            raise '未能创建圆弧。' if edges.empty?
          else
            face = entities.add_face(profile(point))
          end
          if @kind!='arc'
            raise '未能生成面，请增大尺寸后重试。' unless face && face.valid?
            face.reverse! if face.normal.z<0
          end
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
        model.selection.clear
        model.selection.add(group)
        @session.message = @kind=='arc' ? '已创建原生圆弧；开放曲线需补边闭合后才能成面。' : '已创建原生底面群组；点「推拉已画轮廓」可进入群组推拉。'
        PointCloud.publish
        group
      end

      def onUserText(text,view)
        PointCloud.safely do
          begin
            raise ArgumentError, '请先在扫描上单击起点。' if @vertices.empty?
            center = @vertices.first
            if @kind=='rectangle'
              values = text.split(/[,，;]/).map(&:strip)
              raise ArgumentError, '请输入长,宽，例如 3m,200mm。' unless values.size==2
              width,height = values.map(&:to_l)
              raise ArgumentError, '长和宽必须大于零。' unless width>0 && height>0
              sx = @hover && @hover.x<center.x ? -1 : 1
              sy = @hover && @hover.y<center.y ? -1 : 1
              accept_point(Geom::Point3d.new(center.x+sx*width,center.y+sy*height,center.z),view)
            elsif @kind=='arc' && @vertices.size==2
              degrees = Float(text.strip.sub(/[°度]\z/,''))
              raise ArgumentError, '圆弧角度应大于 0 且小于 360 度。' unless degrees.finite? && degrees>0 && degrees<360
              radius = center.distance(@vertices[1])
              start = Math.atan2(@vertices[1].y-center.y,@vertices[1].x-center.x)
              angle = start+degrees*Math::PI/180
              accept_point(Geom::Point3d.new(center.x+radius*Math.cos(angle),center.y+radius*Math.sin(angle),center.z),view)
            else
              radius = text.to_l
              raise ArgumentError, '请输入大于零的半径，例如 500mm。' unless radius>0
              direction = @hover ? @hover-center : X_AXIS
              direction = X_AXIS if direction.length<0.1.mm
              accept_point(center.offset(direction,radius),view)
            end
          rescue StandardError => error
            Sketchup.set_status_text(error.message)
            UI.beep
          end
        end
      end

      def onCancel(_reason,view)
        PointCloud.safely { @vertices.clear; @hover=@source=nil; update_prompt; view.invalidate }
      end

      def getMenu(menu,*_args)
        menu.add_item('重选起点') { onCancel(0,@session.model.active_view) }
        menu.add_item('结束工具（保留已画几何）') { PointCloud.safely { @session.model.select_tool(nil) } }
      end

      def resume(view)
        @picker.instance_variable_set(:@screen_key,nil)
        @hover=@source=nil
        update_prompt
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end

      def draw(view)
        PointCloud.with_draw do
          points = @hover && !@vertices.empty? ? profile(@hover) : []
          points << points.first if points.size>1 && @kind!='arc'
          screen = points.map { |p| (p-view.camera.eye).dot(view.camera.direction)>0 ? view.screen_coords(p) : nil }
          lines = screen.each_cons(2).select { |a,b| a && b }.flatten
          unless lines.empty?
            view.drawing_color='white'; view.line_width=5; view.draw2d(GL_LINES,lines)
            view.drawing_color=Sketchup::Color.new(190,28,38); view.line_width=2; view.draw2d(GL_LINES,lines)
          end
          if @hover
            p=view.screen_coords(@hover);x=p.x;y=p.y
            view.drawing_color=Sketchup::Color.new(190,28,38);view.line_width=2
            view.draw2d(GL_LINE_LOOP,[[x-5,y-5,0],[x+5,y-5,0],[x+5,y+5,0],[x-5,y+5,0]])
          end
        end
      end
    end
  end
end
