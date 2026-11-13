# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    # The six face handles edit the same model-space bounds used by the GPU,
    # numeric fields, range statistics and full-resolution export.
    class ClipBoxTool
      MIN_SPAN_M = 0.001
      HANDLE_RADIUS = 8
      HIT_RADIUS = 13
      AXES = [X_AXIS, Y_AXIS, Z_AXIS].freeze
      COLORS = [[191, 35, 51], [25, 119, 68], [29, 84, 179]].freeze
      LABELS = %w[X− Y− Z− X+ Y+ Z+].freeze
      STATUS = '拖动彩色手柄调整剪切面。按住滚轮转动视角；Esc 结束编辑并保留剪切。'.freeze

      def initialize(session)
        @session = session
      end

      def activate
        PointCloud.status(STATUS)
        @session.model.active_view.invalidate
      end

      def resume(view)
        PointCloud.status(STATUS)
        view.invalidate
      end

      def suspend(view)
        finish_drag
        @hover = nil
        view.invalidate
      end

      def deactivate(view)
        finish_drag
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        return if PointCloud.busy?

        if @drag
          PointCloud.safely { resize_at(x, y, view) }
        else
          handle = pick_handle(x, y, view)
          index = handle && handle[:index]
          view.invalidate unless @hover == index
          @hover = index
          view.tooltip = PointCloud.tr(handle ? "拖动 #{LABELS[index]} 剪切面" : '拖动彩色手柄；转动视角可调整其他方向')
        end
      end

      def onLButtonDown(_flags, x, y, view)
        return if PointCloud.busy?

        handle = pick_handle(x, y, view)
        return unless handle

        index = handle[:index]
        axis = AXES[index % 3]
        start = axis_position(handle[:world], axis, view.pickray(x, y))
        return unless start

        clip = @session.options['clip']
        @drag = {index:index, origin:handle[:world], axis:axis, start:start, original:clip, current:clip}
        view.invalidate
      end

      def onLButtonUp(_flags, x, y, view)
        return unless @drag

        PointCloud.safely do
          resize_at(x, y, view)
          finish_drag
          view.invalidate
        end
      end

      def onCancel(reason, view)
        PointCloud.safely do
          if @drag
            drag = @drag
            @drag = nil
            if @session.options['clip'] == drag[:current]
              @session.apply('clip'=>drag[:original])
              PointCloud.publish
            end
          elsif reason == 0
            @session.model.select_tool(nil)
          end
          view.invalidate
        end
      end

      def draw(view)
        PointCloud.with_draw do
          active = @drag ? @drag[:index] : @hover
          # Draw the nearest handle last when a face projects over its opposite.
          handles(view).sort_by { |handle| -handle[:depth] }.each do |handle|
            index = handle[:index]
            screen = handle[:screen]
            radius = HANDLE_RADIUS + (index == active ? 2 : 0)
            corners = [[-1,-1], [1,-1], [1,1], [-1,1]].map do |dx, dy|
              Geom::Point3d.new(screen.x + dx * radius, screen.y + dy * radius, 0)
            end
            view.drawing_color = Sketchup::Color.new(*COLORS[index % 3])
            view.draw2d(GL_QUADS, corners)
            view.drawing_color = 'white'
            view.line_width = 2
            view.draw2d(GL_LINE_LOOP, corners)
            view.draw_text([screen.x + radius + 4, screen.y - radius, 0], LABELS[index], color:'black')
          end
        end
      end

      private

      def handles(view)
        clip = @session.options['clip']
        return [] unless clip

        center = 3.times.map { |axis| (clip[axis] + clip[axis + 3]) * 0.5 * M_TO_IN }
        camera = view.camera
        eye = camera.eye
        direction = camera.direction
        6.times.filter_map do |index|
          axis = index % 3
          coords = center.dup
          coords[axis] = clip[index] * M_TO_IN
          world = Geom::Point3d.new(*coords)
          depth = (world - eye).dot(direction)
          next if camera.perspective? && depth <= 0

          screen = view.screen_coords(world)
          next unless screen.x.between?(0, view.vpwidth) && screen.y.between?(0, view.vpheight)
          next unless axis_position(world, AXES[axis], view.pickray(screen.x, screen.y))

          {index:index, world:world, screen:screen, depth:depth}
        end
      end

      def pick_handle(x, y, view)
        candidates = handles(view).filter_map do |handle|
          screen = handle[:screen]
          distance = (x - screen.x)**2 + (y - screen.y)**2
          [distance, handle[:depth], handle] if distance <= HIT_RADIUS**2
        end
        candidates.min_by { |distance, depth, _handle| [distance, depth] }&.last
      end

      def axis_position(origin, axis, ray)
        ray_direction = ray[1].normalize
        alignment = axis.dot(ray_direction)
        denominator = 1.0 - alignment * alignment
        # A nearly end-on axis has no stable screen direction. Orbit to edit it.
        return if denominator < 0.01

        offset = ray[0] - origin
        (offset.dot(axis) - alignment * offset.dot(ray_direction)) / denominator
      end

      def resize_at(x, y, view)
        drag = @drag
        return unless drag && @session.options['clip'] == drag[:current]

        position = axis_position(drag[:origin], drag[:axis], view.pickray(x, y))
        return unless position&.finite?

        index = drag[:index]
        clip = drag[:original].dup
        value = clip[index] + (position - drag[:start]) / M_TO_IN
        clip[index] = if index < 3
                        [value, clip[index + 3] - MIN_SPAN_M].min
                      else
                        [value, clip[index - 3] + MIN_SPAN_M].max
                      end
        return if clip == drag[:current]

        @session.apply({'clip'=>clip}, false)
        drag[:current] = @session.options['clip']
      end

      def finish_drag
        drag = @drag
        @drag = nil
        return unless drag && drag[:original] != drag[:current]
        return unless @session.display_attached? && @session.options['clip'] == drag[:current]

        @session.persist
        PointCloud.publish
      end
    end
  end
end
