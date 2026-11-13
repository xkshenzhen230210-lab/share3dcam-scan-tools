# encoding: UTF-8
module BilingualTest
  def self.run(output)
    pc=SHARE3DCAM::PointCloud
    model=Sketchup.active_model
    previous=pc.language
    signature=lambda {[model.entities.map(&:entityID),model.active_path,model.selection.to_a]}
    before=signature.call
    checks=[]
    assert=lambda {|test,name| raise name unless test;checks<<name}
    begin
      pc.set_language('en')
      assert.call(Sketchup.read_default(pc::DICT,'language')=='en','English preference persisted')
      assert.call(pc.session.info[:language]=='en','language included in panel state')
      assert.call(pc.tr('圆')=='Circle','drawing tool translated')
      assert.call(pc.tr('半径')=='Radius','dimension prompt translated')
      assert.call(pc.tr('导入未完成：请先退出组件或群组编辑。')=='Import incomplete: Exit component or group editing first.','nested error translated')
      assert.call(pc.tr('已向上拉伸 2.8 米，生成可编辑的 SU 实体群组。')=='Extruded upward by 2.8 m into an editable SketchUp solid group.','dynamic height translated without changing value')
      assert.call(pc.tr('客户资料/室内测试.ply')=='客户资料/室内测试.ply','unknown filenames unchanged')
      s=pc.session
      menu=Object.new
      menu.define_singleton_method(:add_item){|text,&_block| (@labels||=[])<<text}
      menu.define_singleton_method(:labels){@labels}
      pc::ShapeTool.new(s,'circle').getMenu(menu)
      assert.call(menu.labels==['Pick start point again','Finish tool (keep geometry)'],'right-click menu translated')
      pc.set_language('zh-CN')
      assert.call(pc.tr('圆')=='圆','Chinese restored')
      assert.call(Sketchup.read_default(pc::DICT,'language')=='zh-CN','Chinese preference persisted')
      assert.call(signature.call==before,'switching language preserves model, edit context and selection')
      File.write(output,JSON.pretty_generate({status:'PASS',sketchup:Sketchup.version,checks:checks}))
    rescue StandardError=>error
      File.write(output,JSON.pretty_generate({status:'FAIL',error:error.message,backtrace:error.backtrace.first(5),checks:checks}))
    ensure
      pc.set_language(previous)
    end
  end
end
