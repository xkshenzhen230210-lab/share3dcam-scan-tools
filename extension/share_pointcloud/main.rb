# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'securerandom'
require 'tmpdir'

module SHARE3DCAM
  module PointCloud
    ROOT = File.dirname(__FILE__).freeze
    ENGINE = File.join(ROOT, 'bin', 'share_cloud_engine_080.exe').freeze
    DICT = 'SHARE3DCAM_PointCloud_v1'.freeze
    M_TO_IN = 1.0 / 0.0254
    require File.join(ROOT,'localization')

    # View drawing can pump Windows messages and re-enter timers/HtmlDialog callbacks.
    # Never change entities, attributes or live display buffers during those callbacks.
    def self.drawing?
      @drawing_depth.to_i > 0
    end

    def self.busy?
      drawing? || @action_running
    end

    def self.with_draw
      @drawing_depth = @drawing_depth.to_i + 1
      yield
    ensure
      @drawing_depth -= 1
      schedule_actions if !busy? && @pending_actions && !@pending_actions.empty?
    end

    def self.safely(&action)
      if busy?
        (@pending_actions ||= []) << action
        @deferred_count = @deferred_count.to_i + 1
        schedule_actions unless drawing?
        false
      else
        @action_running = true
        begin
          action.call
          true
        ensure
          @action_running = false
          schedule_actions if @pending_actions && !@pending_actions.empty?
        end
      end
    end

    def self.schedule_actions
      return if @action_timer
      @action_timer = UI.start_timer(0.05,false) do
        @action_timer = nil
        unless busy?
          pending = @pending_actions || []
          @pending_actions = []
          pending.each { |action| safely(&action) }
        end
      end
    end

    def self.report(error)
      warn("[赛尔点云] #{error.class}: #{error.message}\n#{error.backtrace&.first(6)&.join("\n")}")
      PointCloud.messagebox("操作未完成：#{error.message}")
    end

    def self.session
      model = Sketchup.active_model
      if !@session || @session.model != model || !@session.display_attached?
        if @session && !@session.display_attached? && @session.respond_to?(:forget_closed_model_overlay)
          @session.forget_closed_model_overlay
        end
        @session.deactivate if @session
        @session = Session.new(model)
        @session.restore
      end
      @session
    end

    def self.model_opened(model)
      # SketchUp can reuse the active Model wrapper when opening another SKP.
      # Its overlays are nevertheless cleared, so model equality is not a reset signal.
      @session.forget_closed_model_overlay if @session && @session.respond_to?(:forget_closed_model_overlay)
      @session.deactivate if @session
      @session = Session.new(model)
      @session.restore
      publish
    end

    def self.publish
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("receive(#{JSON.generate(session.info)})")
    end

    def self.panel
      if Sketchup.version.to_i < 24 || Sketchup.platform != :platform_win
        PointCloud.messagebox('此试用版支持 Windows SketchUp 2024–2026。')
        return
      end
      unless @dialog
        @dialog = UI::HtmlDialog.new(dialog_title: 'SHARE3DCAM · 扫描绘图 / Scan Tools', preferences_key: DICT,
                                    scrollable: true, resizable: true, width: 432, height: 620,
                                    style: UI::HtmlDialog::STYLE_DIALOG)
        @dialog.set_file(File.join(ROOT, 'panel.html'))
        @dialog.add_action_callback('action') do |_context, name, payload|
          safely do
            begin
              dispatch(name, payload || {})
            rescue StandardError => e
              session.import_message(:mesh, "网格导入未完成：#{e.message}") if name == 'import_mesh'
              session.message = "操作未完成：#{e.message}" unless name == 'import_mesh'
              report(e)
            ensure
              publish
            end
          end
        end
        @dialog.set_on_closed { @dialog = nil }
      end
      @dialog.show
      publish
    end

    def self.dispatch(name, data)
      s = session
      case name
      when 'ready' then nil
      when 'language' then set_language(data.fetch('language'))
      when 'import_mode'
        Sketchup.write_default(DICT,'compatible_import',data['enabled']==true)
      when 'import'
        path = PointCloud.openpanel('导入点云：LAS / LAZ / PLY / XYZ / TXT / PTS', '',
                            '点云|*.las;*.laz;*.ply;*.xyz;*.txt;*.pts||')
        s.import(path, data) if path
      when 'open_index'
        folder = PointCloud.select_directory(title:'选择已有点云索引文件夹（内含 cloud.json）',
                                     directory:Sketchup.read_default(DICT,'index_root',''))
        s.open_index(folder) if folder
      when 'open_gaussian_index'
        folder = PointCloud.select_directory(title:'选择已有高斯索引文件夹（内含 cloud.json）',
                                     directory:Sketchup.read_default(DICT,'gaussian_index_root',Sketchup.read_default(DICT,'index_root','')))
        if folder
          s.open_index(folder, expected_kind:'gaussian')
          Sketchup.write_default(DICT,'gaussian_index_root',folder)
        end
      when 'import_mesh'
        path = PointCloud.openpanel('导入网格模型', '', '网格模型|*.glb;*.obj||')
        s.import_mesh(path, data) if path
      when 'import_gaussian'
        path = PointCloud.openpanel('将高斯 PLY 导入 SketchUp 主视窗', '', '高斯 PLY|*.ply||')
        s.import(path, data, gaussian:true) if path
      when 'settings' then s.apply(data)
      when 'edit_clip_box' then s.edit_clip_box
      when 'reset_clip' then s.reset_clip
      when 'selection_clip' then s.selection_clip
      when 'fit' then s.fit
      when 'reference_zoom' then s.start_reference_zoom
      when 'free_keep' then s.start_free_crop(true)
      when 'free_remove' then s.start_free_crop(false)
      when 'free_undo' then s.undo_free_crop
      when 'free_reset' then s.apply('free_crop'=>[])
      when 'top'
        box = s.cloud ? s.bounds : s.model.bounds
        center = box.valid? ? box.center : ORIGIN
        eye = center.offset(Z_AXIS, box.valid? ? [box.diagonal, 1.m].max : 1.m)
        s.model.active_view.camera = Sketchup::Camera.new(eye, center, Y_AXIS, false)
        s.fit
      when 'use_level' then s.use_picked_elevation
      when 'level'
        s.require_cloud
        s.model.tools.push_tool(CaptureTool.new(s,'level'))
      when 'trace', 'measure', 'anchor'
        s.require_cloud
        s.apply(data) unless data.empty?
        raise '请先退出组件或群组编辑，再使用点云描图。' if s.model.active_path
        s.model.select_tool(CaptureTool.new(s, name))
        PointCloud.status('在主视图单击执行全量点捕捉；右键可结束、闭合或撤销上一点。')
      when 'native_pushpull'
        CaptureTool.native_pushpull(s)
      when 'draw_rectangle', 'draw_circle', 'draw_polygon', 'draw_arc'
        kind = name.delete_prefix('draw_')
        if s.cloud
          s.require_cloud
          raise '请先退出组件或群组编辑，再绘制扫描轮廓。' if s.model.active_path
          s.apply(data) unless data.empty?
          s.model.select_tool(ShapeTool.new(s,kind,segments:data.fetch('shape_segments',48),sides:data.fetch('polygon_sides',6)))
        else
          action = {'rectangle'=>'selectRectangleTool:', 'circle'=>'selectCircleTool:',
                    'polygon'=>'selectPolygonTool:', 'arc'=>'selectArcTool:'}.fetch(kind)
          Sketchup.send_action(action)
        end
        Sketchup.focus
      when 'native_line', 'native_offset'
        Sketchup.send_action(name=='native_line' ? 'selectLineTool:' : 'selectOffsetTool:')
        Sketchup.focus
      when 'extrude_profile'
        selection = s.model.selection
        group = selection.first if selection.size == 1
        if s.model.active_path&.size == 1 && (selection.empty? || group.is_a?(Sketchup::Face))
          group = s.model.active_path.last
        end
        unless group.is_a?(Sketchup::Group)
          raise '请先用选择工具单击一个已闭合成面的底面群组。'
        end

        CaptureTool.prompt_extrusion(s, group)
      when 'save' then s.save_portable
      when 'reload' then s.restore(true)
      when 'full_stats' then s.full_stats
      when 'export_full' then s.export_full
      else raise '未知操作'
      end
    end

    class Display < Sketchup::Overlay
      def initialize(session)
        super('share3dcam.pointcloud', '赛尔点云显示')
        @session = session
      end
      def draw(view)
        return unless @session.cloud && @session.options['visible']
        PointCloud.with_draw { draw_cloud(view) }
      end
      def draw_cloud(view)
        @session.note_draw
        @session.batches.each do |color, points|
          next if points.empty?
          view.drawing_color = color
          view.line_width = 1
          view.draw(GL_LINES, points)
        end
        if @session.options['box'] && @session.clip_box
          box = @session.clip_box
          lines = [[0,1],[1,3],[3,2],[2,0],[4,5],[5,7],[7,6],[6,4],[0,4],[1,5],[2,6],[3,7]]
          view.drawing_color = Sketchup::Color.new(210,35,45)
          view.line_width = 1
          view.draw(GL_LINES, lines.flat_map { |a,b| [box.corner(a), box.corner(b)] })
        end
      end
      def getExtents
        @session.bounds
      end
    end

    class Session
      attr_reader :model, :cloud, :points, :batches, :options, :bounds, :clip_box, :revision, :render_count
      attr_accessor :message
      def initialize(model)
        @model = model
        @options = {'visible'=>true, 'size'=>0, 'color'=>'rgb', 'box'=>false, 'gaussian_opacity'=>65.0,
                    'slice'=>false, 'slice_z'=>1.2, 'slice_width'=>0.1,
                    'x'=>0.0, 'y'=>0.0, 'z'=>0.0, 'angle'=>0.0,
                    'plane'=>false, 'plane_z'=>0.0, 'budget'=>50_000}
        @message = '选择要导入的数据。'
        @points = []; @batches = []; @bounds = Geom::BoundingBox.new; @revision = 0; @render_count = 0
        existing = @model.overlays.find { |o| o.overlay_id=='share3dcam.pointcloud' }
        @model.overlays.remove(existing) if existing
        @overlay = Display.new(self)
        raise '点云显示层未能注册，请重开模型后再试。' unless @model.overlays.add(@overlay)
        @overlay.enabled = true
      end

      def require_cloud
        raise '请先导入点云。' unless @cloud
      end

      def display_attached?
        @model.overlays.include?(@overlay)
      rescue TypeError
        false
      end

      def info
        {language: PointCloud.language, options: @options, elevation: @picked_elevation, message: @message, mesh_message: @mesh_message, busy: !!@job,
         compatible_import: Sketchup.read_default(DICT,'compatible_import',false),
         cloud: @cloud && {name:@cloud['source_name'], source:@cloud['valid_points'],
                          sample:@cloud['display_points'], visible:@points.size,
                          offset:@cloud['origin_m'], has_color:@cloud['has_color']}}
      end

      def read_elevation(point)
        local=point.z.to_f/M_TO_IN
        source=local-@options['z']+@cloud.fetch('origin_m',[0,0,0])[2]
        @picked_elevation={model_z:local,source_z:source,pose:%w[x y z angle].map {|k| @options[k]}}
        @message=format('模型 Z：%.4f m；源文件 Z：%.4f m。可设为绘图标高。',local,source)
        PointCloud.publish
      end
      def use_picked_elevation
        raise '请先在地面拾取标高。' unless @picked_elevation
        raise '参照位置已改变，请重新拾取标高。' unless @picked_elevation[:pose]==%w[x y z angle].map {|k| @options[k]}
        apply('plane'=>true,'plane_z'=>@picked_elevation[:model_z])
        active=@model.tools.active_tool
        @model.select_tool(nil) if active.is_a?(CaptureTool) && active.instance_variable_get(:@mode)=='level'
        @message=format('绘图标高已设为 %.4f m。请沿同一楼层轮廓描图。',@options['plane_z'])
      end

      def persist
        return unless @cache
        state={cache:@cache, options:@options,capture_coordinates:2}
        state[:camera]=camera_snapshot if respond_to?(:camera_snapshot)
        value=JSON.generate(state)
        @model.set_attribute(DICT, 'cloud', value) unless @model.get_attribute(DICT,'cloud')==value
      end

      def note_draw
        @render_count += 1
      end

      def restore(force=false)
        return if @cloud && !force
        data = @model.get_attribute(DICT, 'cloud')
        return unless data
        saved = JSON.parse(data)
        cache = saved.fetch('cache')
        cache = File.expand_path(cache, File.dirname(@model.path)) unless absolute?(cache)
        unless File.file?(File.join(cache, 'cloud.json'))
          @message = '未找到点云缓存。请把SKP与点云数据文件夹放在一起，或重新导入原文件。'
          return
        end
        load_cache(cache)
        @cache = saved.fetch('cache')
        options=saved['options'] || {}
        options['plane']=false unless saved['capture_coordinates']==2
        apply(options, false)
        restore_camera(saved['camera']) if saved['camera'] && respond_to?(:restore_camera)
        @message = '已恢复点云缓存，可继续描图。'
      rescue StandardError => e
        @message = "恢复失败：#{e.message}；请重新导入。"
      end

      def absolute?(path)
        path.match?(/\A(?:[A-Za-z]:[\\\/]|\\\\|\/)/)
      end

      def import(path, data, gaussian:false)
        raise '上一项导入仍在进行，请等待。' if @job
        unit = data['unit'].to_s
        raise '单位不正确' unless %w[m mm cm ft].include?(unit)
        limit = Integer(data['limit'])
        raise '显示上限为10000到100000点' unless (10_000..100_000).include?(limit)
        exe = ENGINE
        raise '转换器缺失，请完整安装RBZ。' unless File.file?(exe)
        parent=PointCloud.select_directory(title:'选择全量点云索引保存位置（建议空间充足的本地硬盘）',directory:Sketchup.read_default(DICT,'index_root',File.dirname(path)))
        return unless parent
        Sketchup.write_default(DICT,'index_root',parent)
        @options['budget']=limit
        cache = File.join(parent, (gaussian ? '高斯索引_' : '点云索引_') + SecureRandom.uuid)
        FileUtils.mkdir_p(cache)
        log = File.join(cache, 'process.log')
        compatible=data['compatible']==true
        Sketchup.write_default(DICT,'compatible_import',compatible)
        command=[exe,gaussian ? '--gaussian' : '--index','--source',path,'--out',cache,'--limit',limit.to_s,'--unit',unit]
        command << '--compatible-cpu' if compatible
        pid = Process.spawn(*command, out: log, err: log)
        @job = {pid:pid, cache:cache, start:Time.now, kind:gaussian ? :gaussian : nil}
        @message = gaussian ? '正在后台读取高斯 PLY…' : '后台读取点云中，可以继续查看SU模型；请勿关闭SU。'
        @timer = UI.start_timer(0.4, true) { PointCloud.safely { poll } }
      end

      def poll
        return unless @job
        job_kind = @job[:kind]
        # Reap once. If status.json is briefly locked after exit, the next tick
        # can still read it without calling waitpid again on a reaped child.
        @job[:exit_status] ||= Process.waitpid2(@job[:pid], Process::WNOHANG)&.last
        status = read_import_status
        return unless status

        cache = @job[:cache]
        if status['state'] == 'complete'
          mesh_name = @job[:mesh_name]
          finish_job
          if job_kind == :mesh
            import_prepared_mesh(File.join(cache, 'mesh.dae'), mesh_name)
            @mesh_message = "网格已导入为组件。转换了 #{status.fetch('triangles')} 个三角面和 #{status.fetch('textures')} 张贴图。"
            begin
              FileUtils.remove_entry_secure(cache)
            rescue SystemCallError => e
              warn("[赛尔点云] 网格临时文件未清理：#{e.message}")
            end
          else
            open_index(cache)
          end
        elsif status['state'] == 'error'
          finish_job
          import_message(job_kind, "导入失败：#{status.fetch('message','转换进程报告错误。')}")
        elsif @job[:exit_status]
          finish_job
          message = '转换进程已退出，未收到完成状态。'
          if job_kind != :mesh && File.file?(File.join(cache, 'cloud.json'))
            message += " 如需校验并继续加载，请用“打开已有索引”选择：#{cache}"
          else
            message += ' 请检查文件格式和磁盘空间后重新导入。'
          end
          import_message(job_kind, message)
        elsif job_kind == :mesh
          @mesh_message = '正在后台转换网格和贴图…'
        elsif job_kind == :gaussian
          @message = "正在准备高斯绘图参照，已处理 #{status.fetch('read_points',0)} 个高斯。"
        else
          @message = "#{status['phase']=='index' ? '第二遍分块建索引' : '第一遍扫描'}：#{status.fetch('read_points',0)}点；全量保留，原文件不修改。"
        end
        PointCloud.publish
      rescue StandardError => e
        finish_job
        import_message(job_kind, "导入未完成：#{e.message}")
        PointCloud.publish
      end

      def read_import_status
        file = File.join(@job[:cache], 'status.json')
        status = JSON.parse(File.read(file, encoding:'UTF-8'))
        @job.delete(:status_retry_started)
        status
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM, JSON::ParserError => e
        # No status file yet is normal while the converter starts.
        return {} if e.is_a?(Errno::ENOENT) && !@job[:exit_status] && !@job[:status_retry_started]

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @job[:status_retry_started] ||= now
        if now - @job[:status_retry_started] >= 5
          message = "暂时无法读取导入状态（#{e.class}）。"
          message += "如后台已生成完整索引，请选择“打开已有索引”：#{@job[:cache]}" unless @job[:kind] == :mesh
          raise message
        end
        # Retry on the next timer tick, without sleeping on SketchUp's UI thread.
        import_message(@job[:kind], '正在重试读取导入状态…')
        PointCloud.publish
        nil
      end

      def open_index(cache, expected_kind: nil)
        raise '上一项导入仍在进行，请等待。' if @job
        manifest = File.join(cache, 'cloud.json')
        raise '请选择包含 cloud.json 的索引文件夹。' unless File.file?(manifest)
        if expected_kind == 'gaussian'
          meta = JSON.parse(File.read(manifest, encoding:'UTF-8'))
          unless meta['schema'] == 3 && meta['kind'] == 'gaussian'
            raise '所选文件夹不是高斯索引。请选择高斯索引文件夹；普通点云请使用点云区的「打开已有索引」。'
          end
          unless %w[gaussians.bin harmonics.bin].all? { |name| File.file?(File.join(cache, name)) }
            raise '高斯索引文件不完整。请保留同一文件夹内的 cloud.json、gaussians.bin 和 harmonics.bin。'
          end
        end

        load_cache(cache)
        @options.merge!('slice'=>false,'x'=>0.0,'y'=>0.0,'z'=>0.0,'angle'=>0.0)
        rebuild
        persist
        fit
      end

      def import_mesh(path, data)
        raise '上一项导入仍在进行，请等待。' if @job
        raise '请先退出组件或群组编辑。' if @model.active_path
        suffix = File.extname(path).downcase
        raise '请选择 OBJ 或 GLB 文件。' unless %w[.obj .glb].include?(suffix)
        name = File.basename(path, File.extname(path))
        if suffix == '.glb'
          begin
            import_prepared_mesh(path, name)
            @mesh_message = 'GLB 已按原坐标导入为组件。'
            return
          rescue ArgumentError, IOError
            # Older SketchUp builds may not have a native GLB importer.
          end
        end

        exe = ENGINE
        raise '转换器缺失，请完整安装 RBZ。' unless File.file?(exe)
        cache = Dir.mktmpdir('share3dcam-mesh-')
        log = File.join(cache, 'process.log')
        command = [exe, '--mesh', '--source', path, '--out', cache, '--unit', data.fetch('unit', 'm'), '--up', data.fetch('up', 'z')]
        command << '--compatible-cpu' if Sketchup.read_default(DICT, 'compatible_import', false)
        pid = Process.spawn(*command, out:log, err:log)
        @job = {pid:pid, cache:cache, start:Time.now, kind: :mesh, mesh_name:name}
        @mesh_message = '正在后台转换网格和贴图…'
        @timer = UI.start_timer(0.4, true) { PointCloud.safely { poll } }
      end

      def import_message(kind, message)
        if kind == :mesh
          @mesh_message = message
        else
          @message = message
        end
      end

      def import_prepared_mesh(path, name)
        raise '请先退出组件或群组编辑。' if @model.active_path
        definition = @model.definitions.import(path, show_summary:false, merge_coplanar_faces:false)
        raise IOError, '无法读取网格，或文件中没有可导入的面。' unless definition && definition.entities.length.positive?

        @model.start_operation('导入网格模型', true)
        begin
          instance = @model.entities.add_instance(definition, Geom::Transformation.new)
          instance.name = name
          @model.commit_operation
        rescue StandardError
          @model.abort_operation
          raise
        end
        @model.active_view.zoom(instance)
        instance
      end

      def finish_job
        UI.stop_timer(@timer) if @timer
        Process.detach(@job[:pid]) if @job && !@job[:exit_status]
      rescue Errno::ECHILD
        nil
      ensure
        @job = nil; @timer = nil
      end

      def deactivate
        # A completed background import must never attach to a different model.
        finish_job if @job
      end

      def load_cache(cache)
        meta = JSON.parse(File.read(File.join(cache,'cloud.json'), encoding:'UTF-8'))
        n = Integer(meta.fetch('display_points'))
        raise '缓存版本不正确或概览超过10万点，请重新导入。' unless [1,2].include?(meta['schema']) && n.between?(1,100_000)
        xyz = File.binread(File.join(cache,'xyz.f32'))
        rgb = File.binread(File.join(cache,'rgb.u8'))
        raise '点云缓存不完整' unless xyz.bytesize==n*12 && rgb.bytesize==n*3
        values = xyz.unpack('e*')
        raise '点云缓存含无效坐标' unless values.all?(&:finite?)
        @base_xyz = values.each_slice(3).to_a
        @base = @base_xyz.map { |p| Geom::Point3d.new(*p.map { |v| v*M_TO_IN }) }
        @rgb = rgb.unpack('C*')
        @cloud = meta; @cache = File.expand_path(cache)
        @options['clip'] = nil
        rebuild
      end

      def apply(data, save=true)
        numeric = %w[size slice_z slice_width x y z angle plane_z gaussian_opacity]
        flags = %w[visible box slice plane]
        next_options = Marshal.load(Marshal.dump(@options))
        numeric.each do |key|
          next unless data.key?(key)
          value = Float(data[key])
          raise '参数必须是有限数值' unless value.finite? && value.abs <= 1_000_000
          next_options[key] = value
        end
        raise '标记尺寸须为0到50毫米；0表示快速细点' unless next_options['size'].between?(0,50)
        raise '切片厚度须大于0' unless next_options['slice_width'] > 0
        raise '高斯不透明度须为 10% 至 100%' unless next_options['gaussian_opacity'].between?(10,100)
        flags.each { |k| next_options[k]=data[k]==true if data.key?(k) }
        if data.key?('color')
          raise '未知显示模式' unless %w[rgb height gray].include?(data['color'])
          next_options['color'] = data['color']
        end
        if data.key?('clip')
          clip = data['clip']
          if clip
            raise '裁剪盒需要六个有限数值' unless clip.is_a?(Array) && clip.size==6
            clip = clip.map { |v| Float(v) }
            raise '裁剪盒最小值不能大于最大值' unless clip.all?(&:finite?) && (0..2).all? { |i| clip[i]<=clip[i+3] }
          end
          next_options['clip'] = clip
        end
        next_options['free_crop']=validate_free_crop(data['free_crop']) if data.key?('free_crop')
        @options = next_options
        rebuild if @cloud
        persist if save
      end

      def rebuild
        angle=@options['angle']*Math::PI/180.0
        cosine=Math.cos(angle);sine=Math.sin(angle)
        groups = {}; points = []; bounds = Geom::BoundingBox.new
        clip = @options['clip']; slice = @options['slice']
        identity = %w[x y z angle].all? { |k| @options[k]==0 }
        zmin,zmax = @cloud['bounds_local_m'].map { |b| b[2] }
        radius=(@options['size'].zero? ? 5 : @options['size'])*0.001*M_TO_IN/2
        @base_xyz.each_with_index do |(bx,by,bz),i|
          px=identity ? bx : bx*cosine-by*sine+@options['x']
          py=identity ? by : bx*sine+by*cosine+@options['y']
          pz=identity ? bz : bz+@options['z']
          next if !@frame_exact && clip && (px<clip[0] || py<clip[1] || pz<clip[2] || px>clip[3] || py>clip[4] || pz>clip[5])
          next if !@frame_exact && slice && (pz-@options['slice_z']).abs > @options['slice_width']/2
          qx=px*M_TO_IN;qy=py*M_TO_IN;qz=pz*M_TO_IN
          q=identity ? @base[i] : Geom::Point3d.new(qx,qy,qz)
          points << q; bounds.add(q)
          rgb = case @options['color']
                when 'gray' then [65,68,72]
                when 'height'
                  t = [[(bz-zmin)/[zmax-zmin,0.001].max,0].max,1].min
                  [(t*255).to_i, (255*(1-(2*t-1).abs)).to_i,((1-t)*255).to_i]
                else @rgb[i*3,3]
                end
          key = ((rgb[0]/64).floor<<6) | ((rgb[1]/64).floor<<3) | (rgb[2]/64).floor
          entry = (groups[key] ||= [[],0,0,0,0])
          entry[0].concat([Geom::Point3d.new(qx-radius,qy,qz),Geom::Point3d.new(qx+radius,qy,qz),
                           Geom::Point3d.new(qx,qy-radius,qz),Geom::Point3d.new(qx,qy+radius,qz),
                           Geom::Point3d.new(qx,qy,qz-radius),Geom::Point3d.new(qx,qy,qz+radius)])
          entry[1]+=rgb[0];entry[2]+=rgb[1];entry[3]+=rgb[2];entry[4]+=1
        end
        # Keep individual native draw submissions small, including monochrome clouds.
        batches = groups.values.flat_map do |ps,r,g,b,n|
          color=Sketchup::Color.new((r/n).round,(g/n).round,(b/n).round)
          ps.each_slice(4092).map { |batch| [color,batch] }
        end
        clip_box = nil
        if clip
          clip_box = Geom::BoundingBox.new
          clip_box.add(Geom::Point3d.new(*clip[0,3].map { |v| v*M_TO_IN }))
          clip_box.add(Geom::Point3d.new(*clip[3,3].map { |v| v*M_TO_IN }))
        end
        if bounds.empty?
          bounds.add(ORIGIN); bounds.add(Geom::Point3d.new(1,1,1))
          @message = '当前裁剪或切片内没有显示点，请调整范围或恢复全部。'
        end
        # Native calls above may pump UI messages; publish only a complete snapshot.
        @points,@bounds,@batches,@clip_box=points,bounds,batches,clip_box
        @revision += 1
        @model.active_view.invalidate
      end

      def reset_clip
        require_cloud
        apply('clip'=>nil,'slice'=>false,'box'=>false)
        @message = '已恢复全部点云范围。'
      end

      def edit_clip_box
        require_cloud
        clip = @options['clip']
        unless clip
          # Bounds already include the point cloud's alignment in model space.
          clip = (@bounds.min.to_a + @bounds.max.to_a).map { |value| value / M_TO_IN }
        end
        clip = clip.dup
        3.times do |axis|
          next if clip[axis + 3] - clip[axis] >= ClipBoxTool::MIN_SPAN_M

          center = (clip[axis] + clip[axis + 3]) * 0.5
          clip[axis] = center - ClipBoxTool::MIN_SPAN_M * 0.5
          clip[axis + 3] = center + ClipBoxTool::MIN_SPAN_M * 0.5
        end
        apply('clip'=>clip, 'box'=>true)
        @model.select_tool(ClipBoxTool.new(self))
      end

      def selection_clip
        require_cloud
        raise '请先退出组件或群组编辑，再按选中实体裁剪。' if @model.active_path
        raise '请先选中一个原生群组或实体，使用其包围盒裁剪点云。' if @model.selection.empty?
        b = Geom::BoundingBox.new
        @model.selection.each { |e| b.add(e.bounds) }
        apply('clip'=>(b.min.to_a+b.max.to_a).map { |v| v/M_TO_IN },'box'=>true)
      end

      def fit
        @model.active_view.zoom_extents
      end

      def save_portable
        title = @cloud ? '保存 SKP 并收拢参照数据' : '另存为 SKP'
        path = PointCloud.savepanel(title, '', '参照绘图工程.skp')
        return unless path

        path += '.skp' unless File.extname(path).downcase == '.skp'
        return save_to(path) if @cloud

        raise 'SKP 没有保存成功。' unless @model.save(path)

        @message = '已保存 SKP。'
      end

      def save_to(path)
        require_cloud
        name = "#{File.basename(path,'.skp')}_点云数据"
        folder = File.join(File.dirname(path),name)
        FileUtils.mkdir_p(folder)
        source = absolute?(@cache) ? @cache : File.expand_path(@cache,File.dirname(@model.path))
        %w[cloud.json xyz.f32 rgb.u8].each do |file|
          a=File.join(source,file);b=File.join(folder,file)
          FileUtils.cp(a,b) unless File.expand_path(a)==File.expand_path(b)
        end
        previous = @cache
        @cache = name
        persist
        unless @model.save(path)
          @cache = previous;persist
          raise 'SKP没有保存成功，原缓存仍保留。'
        end
        @message = '已保存SKP与同名点云数据文件夹。交付时请把两者一起复制；原点云不包含在显示缓存内。'
      end
    end

    require File.join(ROOT,'full_session')
    require File.join(ROOT,'full_viewport')
    require File.join(ROOT,'resident_viewport')

    class AppEvents < Sketchup::AppObserver
      def onOpenModel(model)
        refresh(model)
      end
      def onNewModel(model)
        refresh(model)
      end
      def refresh(model)
        UI.start_timer(0.1,false) do
          PointCloud.safely do
            begin
              PointCloud.model_opened(model) if Sketchup.active_model==model
            rescue StandardError => e
              warn("[赛尔点云] 自动恢复失败：#{e.message}")
            end
          end
        end
      end
    end

    require File.join(ROOT,'capture_tool')
    require File.join(ROOT,'shape_tool')
    require File.join(ROOT,'clip_box_tool')
    require File.join(ROOT,'reference_navigation')
    require File.join(ROOT,'navigation_events')
    require File.join(ROOT,'free_crop')
    CaptureTool.include(ReferenceWheelZoom)
    ShapeTool.include(ReferenceWheelZoom)
    ClipBoxTool.include(ReferenceWheelZoom)
    unless @command_registered
      command = UI::Command.new('赛尔点云绘图助手 / SHARE3DCAM Scan Tools') { PointCloud.panel }
      command.tooltip = PointCloud.tr('导入点云、裁剪切片与捕捉描图')
      command.small_icon = File.join(ROOT,'icon.svg')
      command.large_icon = File.join(ROOT,'icon.svg')
      @toolbar_command=command
      UI.menu('Extensions').add_item(command)
      toolbar = UI::Toolbar.new('赛尔点云绘图助手');toolbar.add_item(command);toolbar.restore
      @toolbar = toolbar
      @command_registered = true
      UI.start_timer(1,false) { safely { session } }
      file_loaded(__FILE__)
    end
    unless @observer_registered
      @app_observer = AppEvents.new
      Sketchup.add_observer(@app_observer)
      @observer_registered = true
    end
  end
end
