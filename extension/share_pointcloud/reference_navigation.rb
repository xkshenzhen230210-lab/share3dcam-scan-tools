# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    # Overlay pixels cannot be hit by SketchUp's native zoom tool. Use the
    # renderer's original-point hit instead; only the camera is changed.
    module ReferenceNavigation
      extend self
      WHEEL_RATE = 0.18
      DRAG_RATE = 0.004

      def available?(session)
        session.cloud && session.options['visible'] && session.respond_to?(:resident?) && session.resident?
      end

      def capture(view)
        camera = view.camera
        {eye: camera.eye.to_a.map(&:to_f), target: camera.target.to_a.map(&:to_f),
         up: camera.up.to_a.map(&:to_f), perspective: camera.perspective?,
         fov: camera.fov.to_f, height: camera.perspective? ? nil : camera.height.to_f}
      end

      def direction(saved)
        v = 3.times.map { |i| saved[:target][i] - saved[:eye][i] }
        length = Math.sqrt(v.sum { |n| n*n })
        raise '当前视角方向无效，请先定位全部。' unless length.finite? && length > 1e-9
        v.map { |n| n/length }
      end

      # This math is independent of SketchUp objects and does not mutate input.
      # A positive scale approaches the anchor without crossing it. There is no
      # whole-model size limit, and the perspective field of view never changes.
      def scaled(saved, point, scale)
        raise '缩放比例无效。' unless scale.finite? && scale > 0
        d = direction(saved)
        origin = saved[:perspective] ? saved[:eye] : saved[:target]
        shift = 3.times.map { |i| point[i].to_f - origin[i] }
        unless saved[:perspective]
          depth = 3.times.sum { |i| shift[i]*d[i] }
          shift = 3.times.map { |i| shift[i] - d[i]*depth }
        end
        shift.map! { |n| n*(1-scale) }
        result = saved.merge(
          eye: 3.times.map { |i| saved[:eye][i]+shift[i] },
          target: 3.times.map { |i| saved[:target][i]+shift[i] })
        result[:height] = saved[:height]*scale unless saved[:perspective]
        raise '缩放超出数值精度，请退后重试。' unless
          (result[:eye]+result[:target]).all?(&:finite?) &&
          (saved[:perspective] || (result[:height].finite? && result[:height] > 1e-9))
        result
      end

      def apply(view, saved, point, scale)
        result = scaled(saved, point.to_a, scale)
        # Reuse the current camera so aspect ratio and other lens properties
        # stay intact. Do not rebuild a default-lens camera for every wheel tick.
        camera = view.camera
        camera.set(result[:eye], result[:target], result[:up])
        camera.height = result[:height] unless result[:perspective]
        view.camera = camera
        view.invalidate
        result
      end

      def ray_anchor(view, x, y, depth)
        camera = view.camera
        origin, ray = view.pickray(x, y)
        forward = camera.direction.normalize
        denominator = ray.dot(forward)
        return nil unless denominator > 1e-9
        distance = (depth-(origin-camera.eye).dot(forward))/denominator
        return nil unless distance.finite? && distance >= 0
        origin.offset(ray, distance*ray.length)
      end

      def anchor(session, view, x, y, previous=nil)
        camera = view.camera
        forward = camera.direction.normalize
        native = session.model.raytest(view.pickray(x,y), true)
        points = [native && native[0], session.resident_pick(x,y,view)].compact
        hits = points.map { |p| [p, (p-camera.eye).dot(forward).to_f] }
        hits.select! { |_p, depth| depth.finite? && depth > 1e-6 }
        return hits.min_by(&:last).first unless hits.empty?

        # A sparse or blank pixel still zooms on a plane through the previous
        # hit, not on an invisible native origin or a fabricated model surface.
        box = session.clip_box || session.bounds
        candidates = [previous, box && !box.empty? ? box.center : nil, camera.target].compact
        depth = candidates.map { |p| (p-camera.eye).dot(forward).to_f }
                          .find { |value| value.finite? && value > 1e-6 }
        depth ||= 1.0/0.0254
        ray_anchor(view,x,y,depth)
      end

      def wheel(session, view, delta, x, y, previous=nil)
        return nil if delta.to_f.zero?
        point = anchor(session,view,x,y,previous)
        return nil unless point
        # The API supplies +1 / -1. Bound a single anomalous input event, not
        # the accumulated viewing range.
        step = [[delta.to_f,-6.0].max,6.0].min
        apply(view,capture(view),point,Math.exp(-step*WHEEL_RATE))
        point
      end
    end

    module ReferenceWheelZoom
      def onMouseWheel(_flags, delta, x, y, view)
        return false unless ReferenceNavigation.available?(@session)
        return true if PointCloud.busy? || @drag
        @reference_zoom_anchor = ReferenceNavigation.wheel(@session,view,delta,x,y,@reference_zoom_anchor)
        true
      rescue StandardError => e
        PointCloud.report(e)
        true
      end
    end

    class ReferenceZoomTool
      include ReferenceWheelZoom
      STATUS = '参照缩放：对准扫描表面滚轮或上下拖动。按住滚轮转动；Shift 拖动调整视角。'.freeze

      def initialize(session, return_to_previous: true)
        @session = session
        @return_to_previous = return_to_previous
      end

      def activate
        show_status
      end

      def show_status
        exit_hint = @return_to_previous ? 'Esc 返回原工具。' : 'Esc 结束当前拖动；选择其他工具退出。'
        PointCloud.status(STATUS + exit_hint)
        PointCloud.vcb_label('视角')
        camera = @session.model.active_view.camera
        Sketchup.vcb_value = camera.perspective? ? format('%.2f°',camera.fov) : PointCloud.tr('平行投影')
      end

      def enableVCB?; true; end

      def resume(view)
        @drag = nil
        show_status
        view.invalidate
      end

      def suspend(view)
        @drag = nil
        view.invalidate
      end

      def deactivate(view)
        @drag = nil
        view.invalidate
      end

      def onMouseWheel(flags, delta, x, y, view)
        @drag = nil
        super
      end

      def onLButtonDown(flags,x,y,view)
        return unless ReferenceNavigation.available?(@session)
        if (flags & CONSTRAIN_MODIFIER_MASK) != 0
          unless view.camera.perspective?
            PointCloud.status('视角调整用于透视投影；当前平行投影请直接滚轮或拖动缩放。')
            return
          end
          @drag = {camera:ReferenceNavigation.capture(view), y:y.to_f, fov:true}
          return
        end
        point = ReferenceNavigation.anchor(@session,view,x,y,@reference_zoom_anchor)
        return unless point
        @reference_zoom_anchor = point
        @drag = {camera:ReferenceNavigation.capture(view), point:point, y:y.to_f}
      rescue StandardError => e
        PointCloud.report(e)
      end

      def onMouseMove(_flags,_x,y,view)
        unless @drag
          view.tooltip = PointCloud.tr('对准要查看的扫描表面，滚轮或向上拖动放大')
          return
        end
        if @drag[:fov]
          set_fov(view, [[@drag[:camera][:fov]+(y.to_f-@drag[:y])*0.08,1.0].max,120.0].min)
          return
        end
        exponent = [[(y.to_f-@drag[:y])*ReferenceNavigation::DRAG_RATE,-12.0].max,12.0].min
        ReferenceNavigation.apply(view,@drag[:camera],@drag[:point],Math.exp(exponent))
      rescue StandardError => e
        @drag = nil
        PointCloud.report(e)
      end

      def onLButtonUp(flags,x,y,view)
        onMouseMove(flags,x,y,view) if @drag
        @drag = nil
      end

      def set_fov(view,degrees)
        camera = view.camera
        camera.fov = degrees
        view.camera = camera
        Sketchup.vcb_value = format('%.2f°',degrees)
        view.invalidate
      end

      def onUserText(text,view)
        unless view.camera.perspective?
          PointCloud.status('视角输入用于透视投影；平行投影请使用滚轮缩放。')
          return
        end
        degrees = Float(text.strip.sub(/(?:deg|°|度)\s*\z/i,''))
        raise ArgumentError unless degrees.finite? && degrees.between?(1,120)
        @drag = nil
        set_fov(view,degrees)
      rescue ArgumentError, TypeError
        PointCloud.status('视角请输入 1–120 度，例如 35 或 35度。')
      end

      def finish
        @drag = nil
        if @return_to_previous
          @session.model.tools.pop_tool
        else
          @session.model.select_tool(nil)
        end
      end

      def onCancel(reason,view)
        if reason == 0
          @drag = nil
          @return_to_previous ? finish : show_status
        end
        view.invalidate
      end

      def getMenu(menu)
        menu.add_item(PointCloud.tr('结束参照缩放')) { finish }
      end
    end
  end
end
