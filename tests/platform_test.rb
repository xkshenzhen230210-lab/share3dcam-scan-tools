require 'minitest/autorun'
require 'tmpdir'
require_relative '../extension/share_pointcloud/platform'
class PlatformTest < Minitest::Test
  P = SHARE3DCAM::PointCloud::Platform
  def test_native_arm_only_and_windows_unchanged
    assert P.supported?(:platform_osx, 'arm64')
    assert P.supported?(:platform_osx, 'aarch64')
    refute P.supported?(:platform_osx, 'x86_64')
    assert P.supported?(:platform_win, 'x64')
  end
  def test_unicode_and_space_paths_are_not_shell_commands
    Dir.mktmpdir('室内 教学') do |root|
      path=P.engine_path(root,:platform_osx)
      assert_equal File.join(root,'bin','macos-arm64','share_cloud_engine'),path
      assert_equal File.join(root,'bin','share_cloud_engine_080.exe'),P.engine_path(root,:platform_win)
      FileUtils.mkdir_p(File.dirname(path));File.write(path,'test');File.chmod(0600,path)
      P.prepare_engine!(path,:platform_osx)
      assert File.executable?(path) unless Gem.win_platform?
      assert_equal File.join(root,'Library','Caches','SHARE3DCAM','PointCloudSessions'),P.session_root(:platform_osx,{'HOME'=>root})
    end
  end
  def test_missing_converter_is_an_actionable_error
    assert_raises(RuntimeError){P.prepare_engine!('/missing/share_cloud_engine',:platform_osx)}
  end
end
