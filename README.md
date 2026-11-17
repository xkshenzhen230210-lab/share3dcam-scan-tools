# SHARE3DCAM 扫描绘图助手 · M 系列 Mac 测试分支

[中文](README.md) | [English](README.en.md)

<img src="extension/share_pointcloud/share3dcam-logo.png" width="260" alt="SHARE3DCAM">

**赛尔电商中心 · 0.11.0-mac.1 · 中文 / English · MIT 开源**

本分支为 Apple Silicon 原生版，目标 SU 2024–2026，Intel Mac / Rosetta 不支持。
点云全量显示和高斯渲染使用 Metal，绘图、裁剪、工程管理及中英界面共用现有实现。

已在 macOS 15 的 arm64 构建机完成编译、9 组独立转换器格式测试、9 项 Metal GPU
测试和 32 组界面组合检查。**尚未通过 Mac 版 SketchUp 内安装、实际绘图及保存复开的验收。**
测试包使用临时签名，未进行 Apple 开发者签名与公证。

- [中文安装与操作说明](docs/Mac安装与操作说明.md)
- [English installation and operation](docs/Mac_Installation_and_Operation.md)
- [通过的构建与测试记录](https://github.com/xkshenzhen230210-lab/share3dcam-scan-tools/actions/runs/44038413085)
- 安装包在上述 Actions 记录的 Artifacts 中；完整解压后从 SU 扩展程序管理器安装 RBZ。

## 实现范围

点云 LAS/LAZ/PLY/XYZ/TXT/PTS；Mesh GLB/OBJ 与贴图；标准 3DGS PLY 和已有索引；
全量主视窗参照、标高与捕捉、闭合成面与向上拉伸、矩形/圆/多边形/圆弧、
立体剪切盒、水平切片、自由裁剪、工程保存与参照收拢。

格式边界、硬件限制与待完成验收项目见安装说明。未实现 OSGB 导入。

## 构建

原生 arm64 macOS：安装 requirements-macos.txt 中依赖，依次运行
`python tools/build_macos.py`、`python tools/check_macos_frozen.py`、
`python tools/check_macos_native.py`、`python tools/mac_release.py`。
完整自动化流程见 `.github/workflows/macos-arm64.yml`。

Windows 0.10.0 正式源码与原有试用包继续保留在 main 分支及 Releases，本分支未替换它们。
