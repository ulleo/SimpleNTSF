# SimpleNTFS

SimpleNTFS 是一个 SwiftUI macOS 卷挂载管理工具，保存卷 UUID 与目标挂载点，显示实际挂载状态，并协调挂载、卸载和重新挂载。应用管理的是文件系统卷；同一块物理硬盘可以包含多个卷。

## 下载

[下载 v1.3.0（Apple Silicon）](https://github.com/ulleo/SimpleNTSF/releases/download/v1.3.0/SimpleNTFS.zip)，解压后将 `SimpleNTFS.app` 放入“应用程序”。发布包未进行 Developer ID 签名或 Apple 公证；macOS 可能阻止首次打开。版本变化和 SHA-256 校验文件见 [发布页](https://github.com/ulleo/SimpleNTSF/releases/tag/v1.3.0)。

## 支持范围

构建目标为 **macOS 12.0+、Apple Silicon（arm64）**。当前实现识别以下文件系统：

| 文件系统 | 挂载方式 |
| --- | --- |
| NTFS | 调用 `/opt/homebrew/sbin/mount_ntfs` |
| exFAT | 系统 `mount -t exfat` |
| FAT32 | 系统 `mount -t msdos` |
| APFS | 系统 `mount -t apfs` |
| HFS+ | 系统 `mount -t hfs` |

NTFS 需要自行安装与系统兼容的驱动，并确保上述 `mount_ntfs` 路径存在。macFUSE 本身不包含 NTFS 文件系统驱动，安装方法请参考 [macFUSE 官方说明](https://macfuse.github.io/) 和 [ntfs-3g 的 macOS Homebrew tap](https://github.com/gromgit/homebrew-fuse)。本应用不会安装驱动或修改系统扩展设置。

其他格式使用系统命令；不支持的格式会明确拒绝挂载。APFS 发现会关联合成卷与物理存储，无法确认是否外置的卷会显示扫描说明。自动化样例包括合成数据和匿名化的 macOS 27 实机输出。当前已在 macOS 27 验证 NTFS 的挂载、卸载和重新挂载，以及 HFS+、exFAT 的信息查询；文件写入、其他格式挂载和 macOS 12 运行仍待验收。

## 使用与失败恢复

1. 打开应用，添加扫描到的卷或手动填写卷 UUID。
2. 设置位于当前用户目录内的目标挂载点，例如 `~/Mounted/Archive`。路径可以包含空格、冒号；修改目标路径不会立即移动实际挂载点。
3. 根据界面状态执行挂载、卸载或重新挂载。卸载只针对选中的卷，不自动强制卸载整块硬盘，也不自动重试。
4. 需要配置命令权限时，使用界面的权限配置入口，核对系统管理员提示后授权。

挂载、卸载和重新挂载直接执行，无需额外确认。单卷与批量结果以窗口内通知显示，成功通知 4 秒、失败通知 10 秒后自动收起；单卷操作详情保留在对应卷的“上次操作”中。

查询失败或超时会显示“状态未确认”，已有信息仅作参考。此时挂载、卸载和重新挂载暂不可用；检查连接后点击“刷新”重试。首次查询失败时不会编造未挂载状态。

重新挂载先卸载再挂载；第二步失败不会反复重试，而是核实实际状态后报告结果。批量操作继续处理其余可操作卷，最后汇总成功、失败及跳过原因；状态未确认的卷会跳过。命令超时也可能已经改变磁盘状态，因此操作会在核实后才解除忙碌提示。

驱动也可能在命令返回成功后才完成挂载。应用会在有限时间内继续查询，确认卷到达请求的挂载状态和目标路径后才报告成功；期间不重复执行挂载命令。核实超时会显示“状态未确认”，需刷新后再操作。

## 配置与权限

挂载配置仍保存在 `~/.SimpleNTFS/ntfs-disks.conf`，旧文件无需迁移：

```text
# 格式：UUID:目标挂载点
E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2:/Users/example/Mounted/Archive
```

UUID 不区分大小写。以第一个冒号分隔 UUID 与路径，路径中的后续冒号及末尾空格会保留；支持已有的 CRLF 换行和 UUID 两侧格式空白。重复 UUID 加载时采用第一条有效配置；编辑会合并该 UUID 的重复项，删除会移除全部匹配项，其他配置和注释保留。读取或写入失败不会冒充保存成功。

权限仍使用 `/etc/sudoers.d/simplentfs`。应用核对当前用户、完整命令项及兼容标签；旧的 `mount_ntfs` 授权不会被误认作系统 `mount`，影响命令辅助程序的旧 `NOEXEC` 规则也会被指出。配置时会请求管理员授权、校验规则并核对安装结果。

“配置内容符合预期”不等于命令已获实际授权；运行时明确的 sudo 拒绝会更新提示。权限文件不可读、规则不兼容、取消和结果未确认分别报告。文件使用 `root:wheel`、`0440`，普通用户可能无法读取；应用不会为读取状态而放宽权限。自定义 sudoers 的复杂规则需要自行管理，本应用不完整解析系统的有效 sudo 策略。

## 构建

安装可用的 Apple Command Line Tools 或 Xcode 后，在仓库目录运行：

```bash
./build.sh
```

默认写入 `.build/SimpleNTFS` 和 `apps/SimpleNTFS.app`。仅在编译成功后更新产物，不清空整个构建目录。脚本自动收集源码，保留 `arm64-apple-macos12.0` 目标，不额外开启 Swift 6 严格并发模式。

可通过 `SDKROOT` 指定 SDK。本次环境的默认 SDK 27 缺少 SwiftUI 宏插件，使用已安装的 SDK 26.5 编译通过；其他环境请使用本机有效的 SDK 路径：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./build.sh
```

需要隔离打包时，同时指定构建目录与 `.app` 输出位置，避免替换现有应用：

```bash
validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/simplentfs-validation.XXXXXX")"
SIMPLENTFS_BUILD_DIR="$validation_dir/build" \
SIMPLENTFS_APP_DIR="$validation_dir/SimpleNTFS.app" \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
./build.sh
```

打包不会启动应用。这里的本地产物未进行发行签名或公证；启动应用会执行实际磁盘查询。

## 自动化测试

```bash
./test.sh
# 仅运行指定行为测试；未知名称会报错退出
./test.sh ConfigurationCompatibilityTests RefreshRaceTests
# 测试也接受 SDKROOT
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./test.sh
```

测试将编译产物放入临时目录并自动清理，不替换已有应用。配置测试使用临时文件；磁盘、权限和扫描测试使用固定结果；命令执行器使用无副作用的真实测试子进程。普通测试不运行真实 `diskutil` 查询、挂载、卸载或管理员提示。

回归覆盖配置读写与旧格式、刷新竞争、未知状态恢复、延迟挂载核实、单卷与批量结果、命令双流大输出和超时清理、卷发现、文件系统能力与权限规则。plist 样例的来源限制见 [样例说明](Tests/Fixtures/Volumes/README.md)。完整计划和验收记录见 [架构修改计划](docs/architecture-plan.md)。

## 尚待人工验收

初始代码、自动化验证与 Standards / Spec 两轴审查已完成。后续 2026-10-19 实机测试发现并修复了驱动延迟挂载导致的成功误报，NTFS 挂载循环已通过，详见[实机验收记录](docs/architecture-plan.md)。真实 plist 样例当前覆盖 macOS 27 的 NTFS、HFS+、exFAT 详情；macOS 12 运行兼容性仍待验证。

以下独立验收尚未完成：

- HFS+、exFAT、APFS、FAT32 的真实挂载、卸载及重新挂载。
- 真实文件读写需另行明确测试目录和允许的文件操作；不默认格式化或修改现有文件。
- 实际管理员授权、取消及重新安装 sudoers 后的权限效果；本次使用现有授权验证了 NTFS 驱动。
- macOS 12 上运行及真实 diskutil plist 捕获，以及其他文件系统真实介质验证；合成样例不代表真实字段结构已验证。

自动化测试通过和最低部署目标编译成功，均不替代上述实机验收。
