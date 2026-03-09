# SimpleNTFS - macOS NTFS 硬盘管理工具

## 📋 项目概述

SimpleNTFS 是一个 macOS 原生的 NTFS 硬盘管理工具，提供图形化界面来挂载、卸载和管理 NTFS 格式的硬盘。

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
cd ~/SimpleNTFS
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
