# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module SHARE3DCAM
  module PointCloud
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('赛尔点云绘图助手', 'share_pointcloud/main')
      extension.description = '全量点云索引、分块显示、裁剪导出、全量捕捉描线和测距。Windows SU2024–2026试用版。'
      extension.version = '0.10.0'
      extension.creator = 'SHARE3DCAM · 赛尔电商中心'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
