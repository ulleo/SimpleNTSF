# SimpleNTFS - macOS NTFS 硬盘管理工具

## 📋 项目概述

SimpleNTFS 是一个 macOS 平台的 NTFS 硬盘管理工具，基于 SwiftUI 构建，提供图形化界面来挂载、卸载和管理 NTFS 格式的硬盘。

### 💡 为什么需要这个工具？

macOS 默认对 NTFS 格式硬盘只读不写，无法直接写入数据。早期 macOS 曾提供过挂载 NTFS 的方法，但随着系统更新，苹果移除了自带的 NTFS 写入支持。为了在 macOS 上实现 NTFS 硬盘的读写，需要借助第三方内核扩展 —— 这就是 **macFUSE** 和 **ntfs-3g** 的作用。

SimpleNTFS 的初衷就是提供一个简单、直观的工具，让你无需手动敲命令就能轻松管理 NTFS 硬盘的挂载。

## ⚙️ 前置条件

使用前需要安装以下依赖：

### 1. 安装 macFUSE

macFUSE 是 macOS 的文件系统扩展框架，提供 NTFS 挂载支持。

**方式一：Homebrew 安装（推荐）**
```bash
brew install --cask macfuse
```

**方式二：官网下载**
访问 [https://macfuse.github.io/](https://macfuse.github.io/) 下载安装包

> ⚠️ 安装后首次使用可能需要重启系统

### 2. 安装 ntfs-3g

ntfs-3g 是开源的 NTFS 驱动，提供读写支持。

```bash
brew tap gromgit/homebrew-fuse
brew install ntfs-3g-mac
```

---

## 🎯 核心功能

- ✅ **挂载/卸载 NTFS 硬盘** - 读写模式挂载
- ✅ **配置管理** - 保存硬盘配置（UUID + 挂载点）
- ✅ **免密码配置** - sudoers 配置向导
- ✅ **图形化界面** - SwiftUI 原生应用
- ✅ **硬盘扫描** - 自动检测已连接的 NTFS 硬盘

## 🛠️ 依赖

- **macFUSE** - 提供 NTFS 挂载支持
- **macOS 12.0+** - 最低系统要求
- **Apple Silicon** - arm64 架构

## 📦 编译

```bash
cd ~/Project/SimpleNTFS
./build.sh
```

编译后的应用在 `apps/SimpleNTFS.app`

## 🚀 使用

1. 打开 `apps/SimpleNTFS.app`
2. 首次使用点右上角"配置免密码权限"
3. 输密码完成配置
4. 点"➕ 新增硬盘"添加配置
5. 点"挂载"开始使用

## 📝 配置文件

位置：`~/.SimpleNTFS/ntfs-disks.conf`

格式：
```
UUID:挂载点路径
E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2:/Users/ulleo/Mounted/ntfs1
```

## ⚠️ 注意

- 需要安装 macFUSE
- 挂载点目录需可写
- 卸载前确保无文件占用
