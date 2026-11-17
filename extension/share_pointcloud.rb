# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module SHARE3DCAM
  module PointCloud
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('赛尔点云绘图助手', 'share_pointcloud/main')
      extension.description = 'M系列Mac测试版：点云、Mesh、高斯参照、裁剪与捕捉绘图；中英文切换。Apple Silicon Mac test build: scan references and native drawing, Chinese/English.'
      extension.version = '0.11.0-mac.1'
      extension.creator = 'SHARE3DCAM · 赛尔电商中心'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
