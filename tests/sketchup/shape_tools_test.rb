# encoding: UTF-8
# Run inside SketchUp. Uses real SU geometry and restores the existing model.
module ShapeToolsTest
  def self.run(output)
    pc=SHARE3DCAM::PointCloud
    model=Sketchup.active_model
    view=model.active_view
    original_path=model.active_path
    original_selection=model.selection.to_a
    camera=view.camera
    original_camera=Sketchup::Camera.new(camera.eye,camera.target,camera.up,camera.perspective?)
    if camera.perspective?
      original_camera.fov=camera.fov
    else
      original_camera.height=camera.height
    end
    original_tool=model.tools.active_tool
    original_groups=model.entities.grep(Sketchup::Group)
    checks=[]
    begin
      model.active_path=nil
      session=Struct.new(:model,:options,:cloud,:message).new(model,{'visible'=>true,'plane'=>false,'plane_z'=>7.0},{'source_name'=>'synthetic-test'},'')
      point=lambda{|x,y,z=2| Geom::Point3d.new(x.m,y.m,z.m)}
      assert=lambda{|condition,message| raise message unless condition; checks<<message}
      tool=pc::ShapeTool.new(session,'circle')
      tool.accept_point(point.call(0,0),view)
      tool.onUserText('500mm',view)
      circle=model.selection.first
      face=circle.entities.grep(Sketchup::Face).first
      assert.call(face && circle.entities.grep(Sketchup::Edge).size==48,'circle creates one native face and 48 edges')
      assert.call(face.normal.z>0,'circle normal faces upward')
      assert.call(face.vertices.all?{|v| (v.position.distance(point.call(0,0))-0.5.m).abs<0.01.mm},'circle radius is exactly 500mm')
      pc::CaptureTool.extrude_profile(session,circle,2.8)
      assert.call(circle.manifold? && (circle.bounds.depth-2.8.m).abs<0.01.mm,'circle becomes a closed vertical cylinder')
      assert.call((circle.bounds.min.z-2.m).abs<0.01.mm,'extrusion preserves floor elevation')
      view.camera=original_camera

      tool=pc::ShapeTool.new(session,'rectangle')
      tool.accept_point(point.call(3,0),view)
      tool.instance_variable_set(:@hover,point.call(2,-1))
      tool.onUserText('3m,200mm',view)
      rectangle=model.selection.first
      assert.call((rectangle.bounds.width-3.m).abs<0.01.mm && (rectangle.bounds.height-0.2.m).abs<0.01.mm,'rectangle accepts exact dimensions and negative mouse quadrant')
      assert.call(rectangle.entities.grep(Sketchup::Face).first.normal.z>0,'rectangle normal faces upward in all quadrants')

      tool=pc::ShapeTool.new(session,'polygon',sides:5)
      tool.accept_point(point.call(0,3),view)
      tool.accept_point(point.call(1,3,9),view)
      polygon=model.selection.first
      assert.call(polygon.entities.grep(Sketchup::Edge).size==5,'polygon uses requested side count')
      assert.call(polygon.entities.grep(Sketchup::Face).first.vertices.all?{|v| (v.position.z-2.m).abs<0.01.mm},'scan noise cannot tilt a polygon')

      tool=pc::ShapeTool.new(session,'arc')
      tool.accept_point(point.call(3,3),view)
      tool.onUserText('1m',view)
      tool.onUserText('90',view)
      arc=model.selection.first
      assert.call(arc.entities.grep(Sketchup::Face).empty? && arc.entities.grep(Sketchup::Edge).size==12,'quarter circle is an open native arc with 12 segments')
      assert.call(arc.entities.grep(Sketchup::Edge).first.curve.is_a?(Sketchup::ArcCurve),'arc retains editable ArcCurve metadata')

      before=model.entities.size
      tool=pc::ShapeTool.new(session,'rectangle')
      tool.accept_point(point.call(0,0),view)
      tool.accept_point(point.call(0,1),view)
      assert.call(model.entities.size==before,'zero width rectangle creates no geometry')
      tool.onCancel(0,view)
      assert.call(tool.instance_variable_get(:@vertices).empty?,'cancel clears unfinished preview')
      tool=pc::ShapeTool.new(session,'circle')
      tool.onUserText('1m',view)
      assert.call(model.entities.size==before,'typed radius before anchor creates no geometry')
      begin
        pc::ShapeTool.new(session,'polygon',sides:2)
        raise 'invalid sides were accepted'
      rescue ArgumentError
        checks<<'invalid polygon side count rejected'
      end

      session.options['plane']=true
      tool=pc::ShapeTool.new(session,'circle')
      picker=tool.instance_variable_get(:@picker)
      picker.define_singleton_method(:pick){|*_args| Geom::Point3d.new(1.m,2.m,9.m)}
      projected=tool.point_at(0,0,view)
      assert.call((projected.z-7.m).abs<0.01.mm,'scan anchor projects to configured drawing elevation')
      tool.accept_point(projected,view)
      picker.define_singleton_method(:pick){|*_args| nil}
      camera=Sketchup::Camera.new(point.call(1,2,20),point.call(1,2,7),Y_AXIS,false)
      camera.height=10.m;view.camera=camera
      fallback=tool.point_at(view.vpwidth/2,view.vpheight/2,view)
      assert.call(fallback && (fallback.z-7.m).abs<0.01.mm,'scan gaps use established work plane')
      session.options['visible']=false
      assert.call(tool.point_at(0,0,view).nil?,'hidden scan cannot supply a new point')

      File.write(output,JSON.pretty_generate({status:'PASS',sketchup:Sketchup.version,checks:checks}))
    rescue StandardError=>error
      File.write(output,JSON.pretty_generate({status:'FAIL',error:error.message,backtrace:error.backtrace.first(6),checks:checks}))
    ensure
      model.select_tool(nil)
      model.active_path=nil
      temporary=model.entities.grep(Sketchup::Group)-original_groups
      model.start_operation('清理绘制工具验收几何',true)
      model.entities.erase_entities(temporary) unless temporary.empty?
      model.commit_operation
      view.camera=original_camera
      model.active_path=original_path
      model.selection.clear
      model.selection.add(original_selection.select(&:valid?))
      model.select_tool(original_tool) if original_tool
    end
  end
end
