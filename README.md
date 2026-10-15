# GX85 Monitor

为松下 DMC-GX85 制作的 iPhone 无线监看与遥控拍摄 App。界面参考 iPhone 原生相机：黑色背景、大快门、完整居中的取景画面；支持竖屏、两种横屏和全屏监看。

**0.2.0 / build 2** 新增录像、曝光参数、点按对焦、相机相册及原件导出。自动测试与云端编译记录见 [0.2 验证进度](docs/validation-v0.2-progress.md)，GX85 实际行为见 [待验清单](docs/DEVICE_TEST.md)。模拟器通过不等于相机实测通过。

[查看 0.2 开发分支构建与安装包](https://github.com/a769568933/gx85-monitor-ios/actions?query=branch%3Acodex%2Fgx85-controls)。选择成功运行的 `GX85Monitor-unsigned-IPA` 产物。旧版记录保留于 [0.1 验证记录](docs/VALIDATION.md)。

解压 ZIP 后得到 `GX85Monitor-unsigned.ipa`，用 Windows 上的 AltServer / 手机上的 AltStore Classic 签名安装。包面向 ARM64 iPhone，最低 iOS 16。GitHub 下载需要登录能访问此私有仓库的账号；构建产物保存 14 天，过期后可手动重新运行工作流。

## 可以做什么

- 连接相机 Wi-Fi 后接收实时画面，保持原始构图比例。
- 遥控拍照；照片保存在相机存储卡。
- 手动选择照片/视频操作，录像开始与停止由相机状态确认；HTTP ok 不作为照片生成证明。
- 使用相机提供的选项调整快门、光圈、ISO，写入后读回；不允许的选项禁用。
- 点按画面对焦，忽略黑边与覆盖控件。
- 相机相册分页浏览与预览，下载可用原件，保存到 iPhone 照片或文件；大视频直接下载到临时文件。
- 标记暂停的画面，尝试恢复视频流或重建控制连接。
- 进入后台停止监看，返回前台在仍需连接时恢复。
- 旋转手机调整界面，保持同一个相机会话。
- 查看和主动分享诊断记录。

物理拨盘自动识别尚待 GX85 数据包验证，当前保留手动照片/视频选择，并同步确认的录制状态。RAW、AVCHD、4K 等格式是否能导出取决于相机是否提供无线原件；只有预览图时不冒充原片，不转码。单项原件上限 8 GiB。无线画面的帧率与清晰度取决于相机和网络，需在相同条件下与原厂 App 对比。本项目不修改相机固件。

## 只有 Windows 怎么安装

工程已经上传到 [私有仓库](https://github.com/a769568933/gx85-monitor-ios)。按照 [Windows 安装说明](docs/WINDOWS_INSTALL.md) 下载现有 IPA，在 Windows 上用 AltStore Classic 签名安装。

这个流程需要你的 GitHub 账号、Apple 账号、iPhone 和数据线。账号密码只由你在安装工具中填写。免费 Apple 账号安装的 App 需要定期刷新签名。

## 有 Mac 时

打开 `GX85Monitor.xcodeproj`，选择 GX85Monitor scheme。Xcode 里选择自己的签名 Team 和 iPhone，然后运行。使用 iOS 16 或以上系统。

运行核心测试：

```sh
swift test --package-path GX85Core
```

iOS 测试由共享方案和 `.github/workflows/ios-build.yml` 运行；未签名真机 IPA 由 `bash scripts/build-ipa.sh` 打包。

## 连接相机

1. GX85：设置 → Wi-Fi → Wi-Fi 功能 → 新连接 → 遥控拍摄与查看。
2. iPhone：设置 → Wi-Fi → 加入相机显示的网络。网络没有互联网是正常现象。
3. 关闭原厂 Image App，打开 GX85 Monitor，点连接并允许本地网络访问；首次连接在相机上选“是”。
4. 看到实时画面后使用快门。拍照指令超时会显示结果未知，不自动重拍。

默认相机地址 `192.168.54.1`，监看接收端口 `49152`；可在未连接时修改。部分相机握手需要自身 UDN 标识，App 会先尝试单播识别。若失败，参见 [协议与兼容性说明](docs/PROTOCOL.md)，用 Windows 诊断脚本读取后填入。

## 项目文件

- `GX85Core`：协议、组帧和恢复策略及核心测试。
- `GX85Monitor`：iPhone 界面、网络接收、解码和会话管理。
- `GX85MonitorTests`：控制请求、会话及布局测试。
- `GX85Monitor.xcodeproj`：可在 Xcode 打开的工程。
- `scripts`：工程生成、静态检查、云端打包和相机标识诊断。
- `docs/DEVICE_TEST.md`：真机验证清单。

本项目独立实现相机兼容接口，不使用其他项目的源代码。协议参考来源见 [PROTOCOL.md](docs/PROTOCOL.md)。
