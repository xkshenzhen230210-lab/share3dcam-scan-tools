# encoding: UTF-8
module SHARE3DCAM
  module PointCloud
    # Native zoom cannot hit-test pixels supplied by a C Overlay. Route the
    # explicit Zoom command through the reference-aware camera tool, without
    # replacing selection, orbit, pan or a native geometry tool.
    class ReferenceZoomEvents < Sketchup::ToolsObserver
      ZOOM_TOOL_ID = 10509

      def initialize(session)
        @session = session
        @generation = 0
      end

      def cancel
        @generation += 1
        UI.stop_timer(@timer) if @timer
        @timer = nil
      end

      def onActiveToolChanged(tools, _name, id)
        cancel
        return unless id == ZOOM_TOOL_ID && @session.reference_navigation_available?

        generation = @generation
        @timer = UI.start_timer(0.01, false) do
          @timer = nil
          PointCloud.safely do
            next unless generation == @generation
            next unless Sketchup.active_model == @session.model
            next unless PointCloud.instance_variable_get(:@session).equal?(@session)
            next unless @session.reference_navigation_available?
            next unless tools.active_tool_id == ZOOM_TOOL_ID

            @session.model.tools.push_tool(ReferenceZoomTool.new(@session, return_to_previous: false))
          end
        end
      end
    end

    module ReferenceNavigationSession
      def initialize(model)
        super
        attach_reference_navigation
      end

      def attach_reference_navigation
        return if @reference_zoom_events

        @reference_zoom_events = ReferenceZoomEvents.new(self)
        @model.tools.add_observer(@reference_zoom_events)
      end

      def reference_navigation_available?
        resident? && @resident_attached && @options['visible']
      end

      def start_reference_zoom
        raise '请先显示已载入的点云或高斯参照。' unless reference_navigation_available?

        @model.tools.push_tool(ReferenceZoomTool.new(self))
      end

      def deactivate
        if @reference_zoom_events
          @reference_zoom_events.cancel
          @model.tools.remove_observer(@reference_zoom_events)
          @reference_zoom_events = nil
        end
        super
      end
    end
    Session.prepend(ReferenceNavigationSession)
  end
end
