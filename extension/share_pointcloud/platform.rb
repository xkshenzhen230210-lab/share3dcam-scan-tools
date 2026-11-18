# encoding: UTF-8
require 'rbconfig'
require 'tmpdir'
module SHARE3DCAM
  module PointCloud
    module Platform
      def self.supported?(platform=Sketchup.platform, cpu=RbConfig::CONFIG['host_cpu'])
        platform == :platform_win || (platform == :platform_osx && %w[arm64 aarch64].include?(cpu))
      end
      def self.engine_path(root, platform=Sketchup.platform)
        File.join(root, 'bin', *(platform == :platform_osx ? ['macos-arm64','share_cloud_engine'] : ['share_cloud_engine_080.exe']))
      end
      def self.library_path(root, platform=Sketchup.platform)
        File.join(root, 'bin', *(platform == :platform_osx ? ['macos-arm64','libshare_cloud_resident.dylib'] : ['share_cloud_resident_097.dll']))
      end
      def self.session_root(platform=Sketchup.platform, env=ENV)
        base=platform == :platform_osx ? File.join(env.fetch('HOME',Dir.home),'Library','Caches') : env.fetch('LOCALAPPDATA',File.join(Dir.home,'AppData','Local'))
        File.join(base,'SHARE3DCAM','PointCloudSessions')
      end
      def self.prepare_engine!(path, platform=Sketchup.platform)
        raise '转换器缺失，请完整安装RBZ。' unless File.file?(path)
        # RBZ extractors may not preserve Unix execute permissions. Only adjust
        # the converter bundled inside this extension, never a user input path.
        File.chmod(0700,path) if platform == :platform_osx && !File.executable?(path)
        path
      end
    end
  end
end
