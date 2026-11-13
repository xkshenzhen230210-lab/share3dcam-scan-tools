# encoding: UTF-8
module SHARE3DCAM
 module PointCloud
  module FreeCropSession
   def free_crop_stages; @options['free_crop'] || []; end
   def validate_free_crop(stages)
    raise '自由裁剪记录无效。' unless stages.is_a?(Array) && stages.length<=32
    stages.each do |stage|
     raise '自由裁剪参数无效。' unless stage.is_a?(Hash) && [true,false].include?(stage['keep']) && stage['matrix'].is_a?(Array) && stage['matrix'].length==16 && stage['polygon'].is_a?(Array) && stage['polygon'].length.between?(6,512) && stage['polygon'].length.even?
     raise '自由裁剪坐标无效。' unless (stage['matrix']+stage['polygon']).all? {|v| v.is_a?(Numeric)&&v.finite? }
    end
    stages
   end
   def resident_options
    super
    return unless @resident && ResidentAPI.pc_status(@resident)==2
    signature=JSON.generate(free_crop_stages)
    return if @free_crop_resident==@resident && @free_crop_signature==signature
    raise '恢复裁剪失败。' unless ResidentAPI.pc_crop_reset(@resident)==0
    validate_free_crop(free_crop_stages).each do |stage|
     raise '自由裁剪未完成。' unless ResidentAPI.pc_crop_polygon(@resident,stage['matrix'].pack('d*'),stage['polygon'].pack('d*'),stage['polygon'].length/2,stage['keep'] ? 1 : 0)==0
    end
    @free_crop_resident=@resident;@free_crop_signature=signature
   end
   def poll_resident
    resident_options if @resident && ResidentAPI.pc_status(@resident)==2 && @free_crop_resident!=@resident
    super
   end
   def start_free_crop(keep)
    raise '请先显示并载入点云或高斯。' unless reference_navigation_available?
    @model.tools.push_tool(FreeCropTool.new(self,keep))
   end
   def apply_free_polygon(points,keep,view)
    raise '自由裁剪最多32次，请撤销或恢复后重试。' if free_crop_stages.length>=32
    matrix="\0".b*128
    raise '视图还未准备好，请稍后重试。' unless ResidentAPI.pc_crop_matrix(@resident,matrix)==0
    polygon=points.flat_map {|x,y| [2.0*x/view.vpwidth-1,1-2.0*y/view.vpheight] }
    stage={'matrix'=>matrix.unpack('d*'),'polygon'=>polygon,'keep'=>keep}
    apply('free_crop'=>free_crop_stages+[stage])
    @message='自由裁剪已应用，可继续圈选、撤销或恢复。';PointCloud.publish
   end
   def undo_free_crop; apply('free_crop'=>free_crop_stages[0...-1]); end
   def reset_clip
    apply('free_crop'=>[]) if @cloud
    super
   end
   def full_stats
    raise '自由裁剪为显示范围；请先恢复自由裁剪，再统计剪切盒范围。' unless free_crop_stages.empty?
    super
   end
   def export_full
    raise '当前为自由显示裁剪；请恢复自由裁剪后再导出剪切盒范围，避免导出范围不一致。' unless free_crop_stages.empty?
    super
   end
  end
  class FreeCropTool
   def initialize(session,keep);@session=session;@keep=keep;@points=[];end
   def activate
    @camera=@session.camera_snapshot
    Sketchup.set_status_text('自由裁剪：逐点单击围出范围；Enter应用，Backspace退点，Esc取消。沿当前视线贯穿裁剪。')
   end
   def onLButtonDown(_flags,x,y,view)
    @points<<[x.to_f,y.to_f];view.invalidate
   end
   def onMouseMove(_flags,x,y,view);@hover=[x,y];view.invalidate;end
   def draw(view)
    return if @points.empty?
    points=(@points+(@hover ? [@hover] : [])+[@points.first]).map {|x,y| Geom::Point3d.new(x,y,0)}
    view.drawing_color=Sketchup::Color.new(190,30,45);view.line_width=2;view.draw2d(GL_LINE_STRIP,points)
   end
   def finish(view)
    raise '请至少圈选三个不同的点。' if @points.length<3
    area=@points.each_with_index.sum {|p,i| q=@points[(i+1)%@points.length];p[0]*q[1]-q[0]*p[1] }.abs
    raise '圈选范围太小或交叉，请重新圈选。' if area<8
    raise '圈选期间视角已改变，请按Esc后重新圈选。' unless @camera==@session.camera_snapshot
    PointCloud.safely {@session.apply_free_polygon(@points,@keep,view);@session.model.tools.pop_tool}
   rescue StandardError=>e
    Sketchup.set_status_text(e.message)
   end
   def onReturn(view);finish(view);end
   def onKeyDown(key,_repeat,_flags,view)
    if key==VK_BACK;@points.pop;view.invalidate;true
    elsif key==VK_RETURN;finish(view);true
    else false;end
   end
   def onCancel(reason,view);@session.model.tools.pop_tool if reason==0;view.invalidate;end
   def deactivate(view);view.invalidate;end
   def getMenu(menu)
    menu.add_item(@keep ? '保留圈内并应用' : '移除圈内并应用') {finish(@session.model.active_view)}
    menu.add_item('取消') {@session.model.tools.pop_tool}
   end
  end
  Session.prepend(FreeCropSession)
 end
end
