# Windows 安装到 iPhone

适用条件：iPhone 的系统为 iOS 16 或以上；有 Windows、数据线、GitHub 账号和 Apple 账号。没有 Mac 也能使用此流程。首个未签名真机 IPA 已通过云端编译及校验，尚待你在手机上签名安装和连接相机。

## 1. 下载已经编译好的包

[查看 0.2 分支的成功构建](https://github.com/a769568933/gx85-monitor-ios/actions?query=branch%3Acodex%2Fgx85-controls)，下载其中 `GX85Monitor-unsigned-IPA`。登录自己的 GitHub 账号后下载 ZIP，解压得到 `GX85Monitor-unsigned.ipa`。已有可用签名工具时直接导入新版 IPA；下文保留 AltStore 安装参考，不要求重装 SideStore 或 iLoader。

工程已在 [gx85-monitor-ios 私有仓库](https://github.com/a769568933/gx85-monitor-ios)，不需要再上传源码。产物保存 14 天，下载过期或需要重建时执行第 2 步。

工程不需要配置签名密码、开发者证书或其他 secrets。Apple 账号只由你在安装工具中使用。

## 2. 云端编译并下载 IPA

1. 在 GitHub 仓库打开 **Actions**。
2. 如 GitHub 提示启用工作流，允许在自己的仓库启用。
3. 选择 **Build GX85 iPhone App**，点 **Run workflow**，分支选择 **codex/gx85-controls**（0.2 开发版）。
4. 工作流先运行协议及 iPhone 测试，再生成真机包。测试或编译失败时不会提供成功的 IPA；可以下载验证日志用于修复。
5. 工作流全部成功后，在运行页面的 Artifacts 中下载 **GX85Monitor-unsigned-IPA**。
6. 解压下载的 ZIP，得到 **GX85Monitor-unsigned.ipa**。它尚未签名，需要下面的安装工具处理，不能直接点开安装。

没有看到 Run workflow 时，检查工作流是否已提交到默认分支；没有看到 Actions 时，检查仓库或组织的 Actions 设置。macOS 环境由 GitHub 提供，具体 Xcode 版本记录在工作流日志中。

## 3. Windows 安装 AltStore Classic

遵循 [AltStore 官方 Windows 安装说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)。使用 **AltStore Classic / AltServer**，不要把它与面向特定地区的 AltStore PAL 混淆。

按官方说明安装当前所需的 Apple 驱动、iTunes/iCloud 和 AltServer。驱动来源与版本要求可能变化，以官方页面为准。

用数据线连接并解锁 iPhone，在手机上信任此电脑。在 AltServer 中选择安装 AltStore 到这部 iPhone，由你自己输入 Apple 账号信息。你不需要把密码发给本项目或助手。

根据手机提示，在设置中信任自己的开发者应用；iOS 16 或以上通常还需在设置 → 隐私与安全中启用开发者模式，并按提示重启确认。

## 4. 安装 GX85 Monitor

把 `.ipa` 保存到 iPhone 的“文件”App。在手机 AltStore 的 My Apps 中点 `+`，选择该 IPA，保持 AltServer 可用，让工具为你的手机签名并安装。

初次签名安装时，手机和 Windows 需按 AltStore 的要求连接。建议此时使用普通家庭网络；安装完成后再把 iPhone Wi-Fi 切换到 GX85。

免费 Apple ID 的侧载签名一般七天到期，需定期在 AltStore 刷新。刷新需要按其要求让手机访问 AltServer；用相机 Wi-Fi 监看时无法同时依赖家庭 Wi-Fi 刷新，结束监看后切回即可。签名到期无法打开 App 时，先刷新或重新签名安装。

## 5. 首次连接相机

相机开启“遥控拍摄与查看”，手机加入相机 Wi-Fi。关闭原厂 Image App，再打开 GX85 Monitor。

首次本地网络提示请选择允许。拒绝过时，到设置 → 隐私与安全 → 本地网络中允许 GX85 Monitor。相机出现连接确认时选“是”。

若相机拒绝握手，检查是否仍被原厂 App 控制，再参考 [相机标识诊断](PROTOCOL.md)。

## 如果遇到问题

- **云端编译失败**：保存失败步骤日志或 `GX85Monitor-validation` 下载包；源码完成不等于已经编译通过。
- **安装失败**：按 AltStore 官方说明检查驱动、开发者模式、账号可用应用名额与签名状态。
- **控制已连接但没画面**：查看诊断页的数据包数和无法解码帧数。零包可能是相机未启流/端口不匹配；有包无图需要核实实际流格式。
- **拍照结果未知**：先查看相机是否已有照片，确认后再决定是否再次点击；App 不会自动重发。

安装和真机兼容性都需在你的当前手机上确认。本说明不代表 App 已发布到 App Store。
