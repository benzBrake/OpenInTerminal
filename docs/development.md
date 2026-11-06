# 开发者指南

[返回 README](../README.md)

以下命令均在仓库根目录执行。

## 本地构建：WSLC 容器

需要 Windows 11 和已经可用的 `wslc`。无需在 Windows 安装 Visual Studio、CMake、MinGW、Node.js 或 Windows SDK。

在项目目录执行：

```powershell
.\scripts\build.ps1
# 首次下载固定版本的 Inno Setup 编译器到 .cache，并校验 SHA256 和签名
$iscc = .\scripts\get-inno.ps1
.\scripts\build-installer.ps1 -IsccPath $iscc
```

Inno Setup 只在 Windows 上执行最后的 EXE 打包，不参与 C++ 编译。也可以自行安装 Inno Setup 6.3 或更新版本，随后直接运行 `scripts/build-installer.ps1`，或用 `-IsccPath` 指定编译器。`get-inno.ps1` 使用当前用户安装，不需要管理员权限；编译器位于项目缓存目录，Windows 应用列表中会有其卸载入口。

默认产物为 `dist/installer/OpenInTerminal-版本号-x64-setup-dev.exe`。版本默认读取 `CMakeLists.txt` 并补第四段，也可用 `-Version 0.1.1.0` 指定。生成 ARM64 安装器时需提供真正的 ARM64 二进制：`-Architecture arm64 -BinaryDirectory <目录>`；本地 wslc 路线目前仅编译 x64，ARM64 由 CI 构建。

## 从源码安装与卸载

开发者也可以从源码构建后使用脚本安装（需要开启 Windows“开发人员模式”）。以下命令在源码根目录执行，不适用于仅下载了 Releases 安装包的情况：

```powershell
.\scripts\build.ps1
.\scripts\package.ps1
.\scripts\install.ps1
# 还需在 Directory Opus / “显示更多选项”中使用时：
.\scripts\install.ps1 -IncludeClassicMenu
```

脚本将包复制到 `%LOCALAPPDATA%\Programs\OpenInTerminal\<构建哈希>` 后注册。更新时重新运行构建、打包、安装三条命令；相同版本的开发包更换目录时会先移除旧注册，注册失败则尝试恢复旧包。使用新菜单前先关闭已有菜单并重新打开资源管理器窗口。

移除通过开发脚本注册的本扩展（Inno 安装请使用其卸载入口）：

```powershell
.\scripts\uninstall.ps1
```

旧 `windowsterminal-shell` 创建的菜单由其自己的 `uninstall.ps1` 管理。如果经典菜单同时出现旧版“管理员”分组，可卸载旧脚本菜单后再安装本扩展的经典菜单入口。

## Terminal 配置发现

默认配置文件位置：

| 版本         | settings.json                                                                                       |
| ------------ | --------------------------------------------------------------------------------------------------- |
| 正式版       | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`        |
| Preview      | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json` |
| Canary       | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json`  |
| 非商店版回退 | `%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json`                                         |

启动使用对应版本的应用执行别名 `wt.exe`；受保护的安装目录仅用于读取图标。直接启动 `WindowsApps` 内的 `WindowsTerminal.exe` 在部分系统中会返回“拒绝访问”。

## 诊断

```powershell
# 查看实际配置来源、启动程序和过滤后的 profiles
.\dist\x64\OpenInTerminalCli.exe --list
# 验证已安装的包能否激活 COM，并检查每个图标能否被 Explorer 提取
.\dist\x64\OpenInTerminalCli.exe --diagnose
# 仅打印参数，不启动终端
.\dist\x64\OpenInTerminalCli.exe --command '{profile-guid}' 'C:\目录 & (test)'
# 真正调用已安装菜单的第 0 个 profile，打开指定目录
.\dist\x64\OpenInTerminalCli.exe --invoke 0 'C:\'
```

配置解析错误不会让 Explorer 崩溃。启动参数直接交给 Windows Terminal，避免经过 cmd、PowerShell、VBS 拼接；正确引用中文、空格、尾部反斜杠及 UNC 路径，并转义 Terminal 自己解析的分号。

## GitHub Actions

`.github/workflows/build.yml` 包含两条构建路线：

- Windows Server 2025：MSVC 构建 x64、ARM64；x64 运行核心、COM 测试及安装/重装/卸载、实机注册失败回滚测试；两种架构都运行部署失败/恢复测试，生成 Inno EXE、开发版目录、安装/卸载脚本和未签名 MSIX。安装测试只在一次性 runner 上开启开发人员模式。
- Ubuntu：通过同一个 Dockerfile 运行原生测试及 MinGW 交叉编译，检查本地容器路线。

MSVC 静态链接 C++ 运行库；MinGW 静态链接其运行库。DLL 只依赖 Windows 系统 DLL。CI 的 ARM64 产物为交叉编译，未在 ARM64 机器上运行测试。

未配置签名时，CI 生成需要开发人员模式的 `*-setup-dev.exe`。正式分发可设置以下 GitHub 仓库配置：

- Secret `MSIX_CERTIFICATE_BASE64`：代码签名 PFX 文件的 Base64 内容。
- Secret `MSIX_CERTIFICATE_PASSWORD`：PFX 密码，无密码时可留空。
- Variable `MSIX_PUBLISHER`：证书的 Subject，默认 `CN=OpenInTerminal`。

配置后，CI 用 Windows SDK 的 SignTool 签名并验证 MSIX，将它嵌入不带 `-dev` 后缀的 Inno 安装器。证书必须受目标设备信任；CI 不生成自签名证书来代替正式签名。保持 Publisher 稳定，每次正式更新递增包版本；从不同 Publisher 的开发版迁移，或从签名版切回开发版时，先卸载旧版。

### 发布 Release

`.github/workflows/release.yml` 在推送 `v*` 标签时自动发布，也支持在 Actions → Release → Run workflow 中填写已有标签手动发布。标签格式为 `v主版本.次版本.修订号`（例如 `v0.1.0`），可带 `-rc.1` 等预发布后缀；带后缀的版本自动标记为 GitHub Pre-release。标签中的三段版本必须与该标签提交的 `CMakeLists.txt` 中 `project` 版本一致，安装包版本补第四段 `.0`。

```powershell
# 先提交版本号和待发布的代码，再创建、推送标签
git tag v0.1.0
git push origin v0.1.0
```

Release 流程复用上述 Windows 和容器构建，全部构建和测试通过后才创建 Release，自动生成更新说明，并上传 x64、ARM64 安装 EXE、开发包 ZIP、MSIX 和 `SHA256SUMS.txt`。ZIP 包含 package 目录、安装/卸载脚本和 README。未配置证书也可发布，安装器保留 `-dev` 后缀。发布失败后可重跑失败任务；如果同名 Release 已存在，创建步骤会报错，不覆盖已发布版本。

本地已有签名 MSIX 时，也可以复用它打包，不需要在本机安装 Windows SDK：

```powershell
# package 目录应是生成该 MSIX 时使用的原始文件，内容必须一致
.\scripts\build-installer.ps1 -PackageDirectory .\dist\package `
    -SignedMsixPath .\dist\OpenInTerminal-x64.msix -IsccPath $iscc
```

## 结构与参考

`src/core.cpp` 负责 JSONC、profile 过滤及参数引用；`src/windows.cpp` 负责 Terminal 发现、图标和启动；`src/shell_extension.cpp` 负责 COM、子菜单和目录选择；`packaging/AppxManifest.xml` 注册现代菜单。

参考微软官方文档：[现代文件资源管理器菜单](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)、[IExplorerCommand 子菜单](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-iexplorercommand-enumsubcommands)、[Terminal 参数解析](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalApp/AppCommandlineArgs.cpp)。
