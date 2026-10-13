# GX85 Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付能连接 GX85、实时监看及遥控拍照的 iPhone 原生工程，并准备适用于 Windows 用户的云端编译和侧载流程。

**Architecture:** 独立 Swift Package 提供相机命令、回应解析和 JPEG 帧组装。iOS 层接收 UDP、解码最新画面并管理会话；SwiftUI 仅呈现状态和发送操作，旋转不重建会话。云端先运行测试，再生成供用户签名的真机 IPA。

**Tech Stack:** Swift 5.9 语言兼容模式、SwiftUI、Foundation、Network、ImageIO、XCTest、Xcode、GitHub Actions macOS runner。无第三方运行时依赖。

**Spec:** [已确认的设计规格](../specs/2026-10-13-gx85-iphone-design.md)

## Global Constraints

- 默认支持 iOS 16 及以上；手机系统更旧时先调整规格。
- UI 参考 iPhone 原生相机，监看画面尽量做大，同时支持横版和竖版。
- 取景 aspect-fit，保持完整画面；竖版控制区约 120–136 pt，横版约 88–104 pt，触摸范围至少 44 × 44 pt。
- 默认相机 IPv4 地址 `192.168.54.1`，UDP 端口 49152；手动加入相机 Wi-Fi。
- 先绑定 UDP 再启流；单播通信，无广播发现、无照片库权限。
- JPEG 缓存上限 2 MiB；一个解码任务、一个可覆盖的待处理新帧。
- 保活周期两秒；三次连续失败触发恢复；两秒无画面标记暂停，三秒触发流恢复评估。
- 自动恢复按 1、2、4、8 秒退避，最多四次；主动断开取消恢复。
- 快门指令超时不自动重发；照片保存在相机存储卡。
- 第一版不包含触摸对焦、曝光调整、录像、相册下载、LUT、峰值对焦或多机控制。
- 无 Mac 的 Windows 环境不能声称已通过 Xcode 编译；云端构建与 GX85 真机结果分别记录。
- 未签名 IPA 必须经用户签名安装；不请求、收集或保存 Apple 账号密码。

## Review Focus

1. 相机 HTTP 返回 200 但正文拒绝、等待确认或损坏：不能显示连接成功（任务 1、4）。
2. UDP 来自错误设备、跨包边界、旧流残余或未完成超大帧：不能显示错误画面或无限积累内存（任务 2、3）。
3. 主动断开/退后台后迟到的网络回应：不能复活会话或触发重连（任务 4）。
4. 拍照成功但响应丢失，以及拍照导致短暂停流：不能自动重拍，也不能立即重建整个会话（任务 4）。
5. 左右横屏、安全区及取景比例改变：不能裁切构图、挡住快门或重启流（任务 5）。

## File Structure

- `GX85Core/Package.swift`：共享核心及 macOS 可执行的纯逻辑测试。
- `GX85Core/Sources/GX85Core/{CameraEndpoint,LumixCommand,LumixResponse,JPEGFrameAssembler,LatestFrameMailbox,SessionPolicy}.swift`：校验、协议、组帧、有界待处理帧和恢复策略。
- `GX85Core/Tests/GX85CoreTests/{ProtocolTests,JPEGFrameAssemblerTests,LatestFrameMailboxTests,SessionPolicyTests}.swift`：不依赖相机的测试。
- `GX85Monitor/App/{GX85MonitorApp,CameraSession,CameraSettings,DiagnosticsLog}.swift`：会话和应用生命周期。
- `GX85Monitor/Camera/{LumixCommandClient,LiveViewReceiver,LatestFrameDecoder}.swift`：系统网络与图像解码。
- `GX85Monitor/Views/{CameraView,ShutterButton,ConnectionGuideView,SettingsView,DiagnosticsView,PreviewLayout}.swift`：中文 UI。
- `GX85Monitor/{Info.plist,Assets.xcassets}`：权限、方向和资源。
- `GX85MonitorTests/{CommandClientTests,CameraSessionTests,PreviewLayoutTests}.swift`：传输、恢复与几何布局测试。
- `GX85Monitor.xcodeproj/project.pbxproj` 和 `xcshareddata/xcschemes/GX85Monitor.xcscheme`：完整工程、共享测试/构建方案。
- `.github/workflows/ios-build.yml`、`scripts/build-ipa.sh`：测试与打包。
- `README.md`、`docs/{WINDOWS_INSTALL,DEVICE_TEST,PROTOCOL,VALIDATION}.md`：交付说明及实际验证状态。

## 验证执行约定

先写各任务列出的失败测试，再实现。若当前环境没有 Swift/Xcode，保留测试并明确标记“未执行”，不得以文本扫描代替测试通过。首次获得 macOS 环境时，在实现提交之前的测试版本运行红灯验证，再运行最终版本确认绿灯。不能为了符合流程而伪造失败输出。

核心测试命令在 macOS：`swift test --package-path GX85Core`。iOS 测试：`xcodebuild test -project GX85Monitor.xcodeproj -scheme GX85Monitor -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" CODE_SIGNING_ALLOWED=NO`。工作流从当前安装的模拟器中选取可用 iPhone，设置 `SIMULATOR_UDID`，不硬编码某个未必存在的型号。

当前目录没有 Git 仓库。实现阶段如初始化本地仓库，应先检查作者身份，不设置臆造的用户信息；身份缺失时保留文件，记录未提交，不因此阻塞工程交付。没有仓库授权时不创建远程仓库、不推送或触发云端任务。

### Task 1: 相机地址、命令与回应

**Files:** 核心 package、`CameraEndpoint.swift`、`LumixCommand.swift`、`LumixResponse.swift`、`ProtocolTests.swift`。

**Interfaces:** `CameraEndpoint.init(host: String, port: UInt16 = 49152) throws`；`LumixCommand.makeURL(endpoint: CameraEndpoint) throws -> URL`；`LumixResponse.parse(data: Data) throws -> LumixResponse`；回应包含成功/待确认/拒绝结果和原始安全长度摘要。命令提供 `requestAccess(clientID:name:)`、`state`、`recordMode`、`startStream(port:)`、`stopStream`、`capture`。

- [ ] 写失败测试：`testRejectsInvalidIPv4AndZeroPort`（空串、主机名、256 段、缺段、端口 0 均拒绝）；`testEncodesAccessNameAndStableID`（中文、空格、`&` 不改变参数结构）；`testParsesTextAndXMLSuccess`；`testRejectsUnknownMalformedAndCameraError`；`testPendingApprovalIsNotSuccess`。
- [ ] 在可用 Swift 环境运行核心测试，确认缺失实现使测试失败；无环境时记录未执行。
- [ ] 实现上述接口。XML 使用系统解析器和结构化结果字段；不使用正文包含 `ok` 的模糊判断。HTTP 状态错误与相机正文错误分开处理。
- [ ] 运行核心测试；整理第三方协议出处和 GX85 待验证差异到 `docs/PROTOCOL.md`。
- [ ] 有可用 Git 身份时提交本任务，否则保留变更。

### Task 2: 有界取景帧处理

**Files:** `JPEGFrameAssembler.swift`、`LatestFrameMailbox.swift` 及对应核心测试。

**Interfaces:** `JPEGFrameAssembler.init(maxBytes: Int = 2 * 1024 * 1024, timeout: TimeInterval = 0.5)`；`append(_ datagram: Data, now: TimeInterval) -> [Data]`；`reset()`；`LatestFrameMailbox.offer(_ frame: Data)`、`take() -> Data?`、`reset()`。时间由调用者传入以便确定性测试，mailbox 外部由专用串行队列保护。

- [ ] 写失败测试：`testExtractsJPEGWithPrefixAndSuffix`、`testHandlesSOISplitAcrossPackets`、`testIncompleteFrameExpires`、`testOversizedFrameResynchronizes`、`testDamagedFrameDoesNotPoisonNextFrame`、`testMailboxKeepsOnlyNewestFrame`，明确验证超过 2 MiB 和 0.5 秒后的丢弃行为。
- [ ] 运行核心测试确认失败，或记录环境限制。
- [ ] 实现扫描 JPEG 起止边界、有界缓存、超时清理和完整帧输出。遇到新起始边界可丢弃旧截断帧，不假定每个 UDP 包就是一张完整图。
- [ ] 运行核心测试确认恢复后的下一帧可取出，统计与缓冲上限一致。
- [ ] 有可用 Git 身份时提交本任务。

### Task 3: iOS 传输、解码与可测试工程

**Files:** Xcode 工程、共享 scheme、Info.plist、`LumixCommandClient.swift`、`LiveViewReceiver.swift`、`LatestFrameDecoder.swift`、`CommandClientTests.swift`。

**Interfaces:** `CommandSending.send(_ command: LumixCommand) async throws -> LumixResponse`；`LiveViewReceiving.start(endpoint:onDatagram:) async throws` 与 `stop()`；`LatestFrameDecoder.submit(_ jpeg: Data, generation: UUID)` 与 `reset(generation:)`，回调提供有效图像与同一代次。对象自身管理关闭，不把绑定等待交给 UI。

- [ ] 写失败测试：`testHTTP200WithCameraRejectionThrows`、`testTimeoutDoesNotRetryCapture`、`testCancellationReleasesQueuedCommands`；使用 URLProtocol stub，不访问真实相机。
- [ ] 在可用 Xcode 环境运行指定测试确认失败，或记录未执行。
- [ ] 创建完整 iPhone 工程，引用本地 GX85Core package。HTTP 使用 ephemeral URLSession、禁用缓存与蜂窝、有限超时；命令用真正串行执行门控制，不能仅依靠可重入 actor。客户端 `send` 不自动重试。
- [ ] 使用 Network 框架 UDP listener；仅绑定成功后返回 start，校验远端地址，限制/关闭额外连接，递归接收消息。停止时取消 listener、connections、回调和组帧缓存。
- [ ] 使用 ImageIO 在专用队列解码；一个进行中的解码和一个待处理帧，主线程仅接收结果。reset 后旧图像回调按 generation 丢弃；有界日志记录解码错误。
- [ ] 配置本地网络文案、数字 IP HTTP 所需 ATS 许可、竖屏及左右横屏。通过后续真机检查确认实际 ATS 行为；不引入照片库或多播 entitlement。
- [ ] 运行 iOS 测试和 simulator build，记录输出；有身份时提交本任务。

### Task 4: 会话、快门及恢复

**Files:** `SessionPolicy.swift`、`SessionPolicyTests.swift`、`CameraSession.swift`、`CameraSettings.swift`、`DiagnosticsLog.swift`、`CameraSessionTests.swift`。

**Interfaces:** 核心 `SessionPolicy` 接收健康、帧和快门时间事件，输出 none/restartStream/reconnect/giveUp；`@MainActor CameraSession` 提供 `connect()`、`disconnect()`、`capture()`、`setForeground(_:)` 和只读发布状态/图像/指标；注入 `CommandSending`、`LiveViewReceiving`、可控 clock/sleep 与持久化设置。`DiagnosticsLog` 最多 200 条，导出纯文本。

- [ ] 写失败测试：`testReconnectAfterThreeFailures`（2 秒间隔）；`testHealthyControlRestartsOnlyStalledStream`（3 秒阈值）；`testRetriesStopAfter1248Seconds`；`testDisconnectIgnoresLateHandshake`；`testBackgroundStopsReceiverAndForegroundResumesOnlyWhenWanted`。
- [ ] 写快门测试：`testCaptureTimeoutSentOnceAndReportsUnknown`、`testConcurrentCaptureIsDisabled`、`testCapturePauseDoesNotTriggerImmediateReconnect`。设置相机响应延迟与恢复时间由假 clock 推进，不靠真实等待。
- [ ] 在相应环境运行核心/iOS 测试确认失败，或记录未执行。
- [ ] 实现持久 clientID 和名称；握手待确认状态有限等待且可取消。依序完成访问许可、读状态、设置录制模式、UDP 就绪、启流。仅有效 JPEG 解码成功可发布监看中。
- [ ] 实现会话 UUID 隔离、任务取消、两秒健康检查、停帧标记及有限退避。快门操作及结束后两秒内不触发取景恢复；失败后重新评估健康。停流/退出尽力发送，不能无限等待。
- [ ] 实现后台关闭与前台恢复、活动监看保持屏幕点亮、用户主动断开清除连接意愿。设置只在未连接时允许修改，或者明确要求断开后应用。
- [ ] 运行核心和 iOS 测试，检查关闭路径；有身份时提交本任务。

### Task 5: 大取景画面与横竖屏 UI

**Files:** `GX85MonitorApp.swift`、所有 Views、资源目录、`PreviewLayoutTests.swift`。

**Interfaces:** `PreviewLayout.fit(imageSize: CGSize, in available: CGSize) -> CGRect`；`CameraView` 通过同一个 `CameraSession` 展示状态并发送用户操作。会话由 App 级 StateObject 持有，布局分支不得创建会话。

- [ ] 写布局失败测试：`testPortraitFits43WithoutCropping`、`testLandscapeFits169Beside96PointControls`、`testFullscreenUsesAvailableArea`、`testZeroImageDimensionsDoNotDivideByZero`。检查矩形留在可用边界内且比例正确。
- [ ] 运行布局测试确认失败，或记录环境限制。
- [ ] 实现黑色背景、白色环形大快门、连接状态与少量黄色强调。竖版控制区 128 pt，横版 96 pt；主界面不常驻帧率。对安全区适配，所有图标命中区至少 44 pt。
- [ ] 实现连接三步引导、待相机确认提示、画面暂停标记、快门处理中/结果未知提示、设置和诊断面板。全屏隐藏快门并保留退出入口；恢复后显示当前实际状态。
- [ ] 实现设置持久化与日志主动导出；没有相机时保持黑色占位和连接引导，预览专用样图不得进入真实取景。
- [ ] 在模拟器检查竖屏、两个横屏、全屏及字体放大；旋转测试记录 transport start/handshake 调用次数不增加。没有模拟器时提供待执行清单，不能宣称已视觉验证。
- [ ] 运行 iOS 测试；有身份时提交本任务。

### Task 6: 云端构建、安装说明与交付

**Files:** `.github/workflows/ios-build.yml`、`scripts/build-ipa.sh`、README 和安装/真机/验证文档。

**Interfaces:** 手动触发工作流 `workflow_dispatch`，在 `macos-15` runner 上检出代码、运行核心测试、选取可用 iPhone simulator、运行 iOS 测试、构建 `generic/platform=iOS`，以 `CODE_SIGNING_ALLOWED=NO` 输出 `Payload/GX85Monitor.app` 打包为 `GX85Monitor-unsigned.ipa`。产物通过 artifact 下载，不自动发布。

- [ ] 创建打包脚本；输出目录仅在工作区内，缺失 .app 或可执行文件时立即失败。不得把 simulator .app 打包成真机 IPA。
- [ ] 创建工作流，记录 Xcode 版本，失败时保留测试结果和构建日志，成功时上传 IPA。安装账号信息不得出现在 workflow secrets 或代码中。
- [ ] 写中文说明：GitHub 上传文件/运行 workflow/下载产物、Windows 安装 AltServer 与 Apple 驱动、手机开发者模式及信任、用户自行登录签名、免费账号定期刷新、相机连接和允许本地网络。
- [ ] 写真机验收表：连续监看 15 分钟、20 次快门与照片数量核对、后台恢复、Wi-Fi 切换、相机模式变化及横竖屏布局。明确第三方协议和 ATS/侧载未验证事项。
- [ ] 检查工程源文件引用、共享 scheme、plist 和 workflow，执行当前环境能完成的检查，并在 `docs/VALIDATION.md` 中分别记录本地静态检查、macOS 测试、真机测试的实际状态。
- [ ] 具备用户选定的远程仓库与授权后才能上传和运行云端构建；缺少这些条件仍交付完整本地工程和操作说明，不将“工作流已写好”称为“已生成 IPA”。
- [ ] 云端实际跑通后检查 IPA 内的真机架构及包结构；用户签名安装后依据诊断修复真实兼容问题。不得仅凭构建成功声称连接稳定或优于原厂。
- [ ] 有身份时提交，展示工程入口与安装说明；准确报告已完成内容和剩余环境验证。

## 计划自审与交接

范围覆盖：协议和端口绑定（1、3），内存/帧延迟控制（2、3），保活/拍照/生命周期（4），原生相机风格和横竖屏（5），Windows 安装和验证限制（6）。Review Focus 的五类失败均分配了具体测试或人工验收。对照规格未发现额外产品功能。

推荐由当前助手在本聊天中直接执行。各任务接口紧密相连，单人按顺序实现便于保持取消和会话行为一致；需要独立审查时再按执行技能安排。

用户已于 2026-10-13 确认计划并选择当前聊天直接实现。工程、测试源码与交付文档已制作；执行环境缺少 Swift/Xcode，运行验证步骤保持未完成，详情见 ../../IMPLEMENTATION_LOG.md 和 ../../VALIDATION.md。
