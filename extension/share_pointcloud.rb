# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module SHARE3DCAM
  module PointCloud
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('赛尔点云绘图助手', 'share_pointcloud/main')
      extension.description = 'M系列Mac测试版：点云、Mesh、高斯参照、捕捉绘图与 STL 转换。Apple Silicon Mac test build: scan references, native drawing and STL conversion, Chinese/English.'
      extension.version = '0.11.1-mac.1'
      extension.creator = 'SHARE3DCAM · 赛尔电商中心'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
