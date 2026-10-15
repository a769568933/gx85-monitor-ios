# GX85 Camera Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复快门无实际动作的控制与确认流程、稳定居中的监看布局，并交付录像、曝光参数、点按对焦、相机相册及 iPhone 媒体导出功能。

**Architecture:** 保留现有 Wi-Fi UDP 监看和串行 HTTP 控制，新增有类型的状态、能力及媒体解析。CameraSession 负责协调互斥操作和生命周期，拍摄、相册、下载和照片库写入分别由独立组件处理；SwiftUI 使用固定取景底层加覆盖控件。

**Tech Stack:** Swift 5.9-compatible GX85Core、SwiftUI/UIKit、Network、URLSession、Foundation XMLParser、Photos、UniformTypeIdentifiers；iOS 16+；GitHub Actions macos-15/Xcode。

**Spec:** `docs/superpowers/specs/2026-10-15-gx85-camera-controls-design.md`，用户于 2026-10-15 确认。

**Execution:** 用户已于 2026-10-15 确认计划，并选择在当前聊天直接实现；沿用该方法，不另建聊天、不改变执行方式。

## Global Constraints

- 保持 iOS 16 最低版本。
- 快门命令不自动重发。
- 按源画面比例完整显示，不拉伸、不裁切。
- 以整个屏幕的中心作为画面的水平、垂直中心。
- 任何提示、导出进度、参数选择或对焦框均不得推动或缩放实时画面。
- 不能因为 HTTP 200 或 `ok` 就报告“照片已保存”。
- 不能保证所有格式都能无线导出。
- 视频不会在本版本中转码。
- 下载不修改、不删除相机原文件。
- 新增仅添加照片库的权限说明，不申请不必要的照片库读取权限。
- 测试截图不能冒充真机连接、录像或媒体导出成功。
- 控制请求继续串行发送；外部实体解析关闭；HTTP 重定向及媒体资源必须来自同一相机。
- Windows 上没有 Swift/Xcode。静态检查不能替代编译、测试或真机验证；红/绿测试在 GitHub 的 macOS runner 上执行并保存证据。

## Review Focus

1. 相机回 `ok` 但没有拍成、请求超时或断连：不显示已拍成，不重复快门，不自动开始/停止录像。归属任务 2。
2. 横屏两方向、安全区、4:3/16:9、提示与参数浮层：画面中心和大小不变，黑边和控件点按不对焦。归属任务 3、5、9。
3. 机身切视频、未知字段、不同镜头/固件：模式未知不能当照片模式，菜单原值不被重新编码，参数失败不能断开正常监看。归属任务 1、4。
4. 浏览相册或下载时回后台/断线/返回监看：旧请求不能更新新会话，不能触发错误的监看重连，视频不整段载入内存。归属任务 6、7。
5. 不支持的格式、只有缩略图、外部 URL、照片库拒绝或磁盘不足：不能假报导出成功，不能下载相机之外的资源。归属任务 6—8。

## 文件和职责

新增 GX85Core：`CameraControlState.swift`（状态/模式）、`CameraCapabilities.swift`（菜单选项）、`LiveViewMetadata.swift`（有界元数据）、`CameraMedia.swift`（资源选择与 URL 校验）、`ContentDirectoryReply.swift`（SOAP/DIDL）。每个文件有同名测试文件，放在 `GX85Core/Tests/GX85CoreTests/`。

新增 App 组件：`Camera/CameraControlService.swift`、`Camera/CameraMediaClient.swift`、`App/CameraAlbumModel.swift`、`Media/MediaDownloadService.swift`、`Media/PhotoLibraryWriter.swift`。新增视图：`Views/CameraParameterBar.swift`、`Views/CameraAlbumView.swift`、`Views/CameraMediaPreview.swift`、`Views/MediaExportView.swift`、`Views/NoticeOverlay.swift`。对应行为测试位于 `GX85MonitorTests/`。

修改 `LumixCommand.swift`、`LumixResponse.swift`、`LumixCommandClient.swift`、`CameraSession.swift`、`CameraView.swift`、`ShutterButton.swift`、`PreviewLayout.swift`、`LatestFrameDecoder.swift`、`CameraIdentityResolver.swift`、`Info.plist` 及工程生成/构建脚本。新增模拟器专用测试夹具和 UI 测试目标，见任务 9。

## 开始执行前的基线

- [ ] 读取本计划和已确认设计，检查根目录及上级 `AGENTS.md`、当前工作区、GitHub 最新分支和未提交文件。当前本地 Git 无初始提交、源码未追踪；不得用 reset/clean/强推解决。
- [ ] 按 `using-git-worktrees` 建立隔离工作区。保存不含 `.tools`、附件、凭据或产物的可恢复基线，校对本地源文件与 GitHub 当前源码；尊重远端新增修改。
- [ ] 运行现有核心、iPhone 测试及静态检查作为基线。通过 GitHub connector 建工作分支和可触发的验证流程；保持主分支旧安装包可用。
- [ ] 每个行为任务先提交失败测试并观察预期失败，再实现并运行到通过。Windows 的语法检查只做快速反馈。提交仅包含本任务文件，禁止暂存用户附件和安装/账号数据。

## Task 1: 状态、能力和协议命令

**Files:** GX85Core 上述五个新文件中，先实现 `CameraControlState.swift`、`CameraCapabilities.swift`；修改 `LumixCommand.swift`、`LumixResponse.swift`。

**Interfaces:**
- `CameraShootingMode: Equatable, Sendable`：`photo`、`video`、`unknown`。
- `CameraRecordingState: Equatable, Sendable`：`stopped`、`recording`、`unknown`。
- `CameraControlState.init(response: LumixResponse)`：保留模式、录制、机身占用、卡状态、剩余张数及原始字段；缺失信息为未知，禁止推断为空闲。
- `ExposureParameter: String, CaseIterable, Sendable`：`shutter`、`aperture`、`iso`。
- `CameraParameterOption: Equatable, Identifiable, Sendable`：`id`、`label`、`rawValue`、`enabled`。
- `CameraCapabilities.parse(data: Data) throws -> CameraCapabilities`；`options(for:) -> [CameraParameterOption]`。
- LumixCommand 新增 `.getSetting(String)`、`.getInfo(String)`、`.setSetting(type:value:)`、`.autoFocus`、`.releaseCapture`、`.videoStart`、`.videoStop`、`.playbackMode`、`.touchFocus(x:y:)`；精确生成相机协议 URL。

- [ ] 写失败测试：`testMissingRecRemainsUnknown` 断言空字段录制状态为 `.unknown`；`testRecordingOnOff` 断言 `rec=on/off` 分别对应录制/停止；`testMenuPreservesRawApertureValue` 断言 `392/256` 原样保留，不变成 `1.53125`；`testUnknownModeDoesNotSelectPhoto` 断言未知模式为 `.unknown`。
- [ ] 测试命令 URL：录像使用 `video_recstart/video_recstop`，释放使用 `capture_cancel`，设置快门用 `shtrspeed`、光圈用 `focal`、ISO 用 `iso`；点按坐标超界被拒绝，不拼接用户提供的任意参数或 URL。
- [ ] 云端运行 `swift test --package-path GX85Core`，确认新接口不存在时测试失败。
- [ ] 实现状态解析和菜单树解析；保留同一菜单项的 enabled 和值，未知 XML 结构记录兼容性诊断，不伪造选项。扩大通用响应上限前，单独为菜单设置有界大小（最大 2 MiB），普通回复仍为 256 KiB。
- [ ] 云端运行核心测试到通过；提交 `feat: add typed camera controls and capabilities`。

## Task 2: 真实拍摄结果与录像协调

**Files:** 新增 `GX85Monitor/Camera/CameraControlService.swift` 和 `GX85MonitorTests/CameraControlServiceTests.swift`；修改 `CameraSession.swift`、`CameraSessionTests.swift`、`LumixCommandClient.swift`。

**Interfaces:**
- `CameraCaptureOutcome: Equatable, Sendable`：`confirmed`、`acceptedUnconfirmed`、`rejected(String)`、`unknown`。
- `CameraControlService` actor，通过 `init(client: any CommandSending, sleep: @escaping @Sendable (TimeInterval) async throws -> Void)` 注入依赖。
- `readState() async throws -> CameraControlState`；`capturePhoto() async -> CameraCaptureOutcome`；`setRecording(_ active: Bool) async throws -> CameraRecordingState`；`setParameter(_ parameter: ExposureParameter, rawValue: String) async throws`；`focus(at point: CGPoint) async throws`。
- CameraSession 发布 `controlState`、`selectedShootingMode`、`actionInProgress`；对外提供 `performPrimaryAction()` 和 `selectShootingMode(_:)`。接收相机确认的 mode 后更新选择，未知状态保留用户显式选择。

- [ ] 先写脚本化假相机测试：capture 返回 ok 而拍后状态未变，结果必须为 `.acceptedUnconfirmed`；超时结果 `.unknown`，统计 capture 命令只能有一次；卡异常或机身占用时不发 capture。
- [ ] 测试 AF/MF 分支、对焦明确失败、快门释放失败，以及录制 ack 后 `rec` 未切换时不得发布录制成功。原有并发、断连、后台测试继续保留。
- [ ] 在云端运行 `xcodebuild test`，确认失败来自尚未实现的新行为。
- [ ] 实现单次拍照事务：读状态、按能力检查 AF、必要时单次 AF、单次 capture、按已验证的 GX85 快门流程释放、有限次数查询后状态。默认等待上限 4 秒；不把估算剩余容量变化单独当成照片已保存的证据。明确新文件标识/事件才能 `.confirmed`。
- [ ] 控制器统一互斥操作，使用可取消的事务 gate；不能仅依赖会在 await 时重入的 actor。健康检查与 stream restart 不能插入事务。录像状态由 `rec` 确认；未知时查询，不重发 start；后台/断线不自动 stop。日志添加拍前/拍后模式、AF、卡和操作状态，不只记录 ack。
- [ ] 核心和 iPhone 测试通过后提交 `fix: coordinate shutter and verify recording state`。

## Task 3: 居中取景、覆盖提示和双态主按钮

**Files:** 修改 `CameraView.swift`、`PreviewLayout.swift`、`ShutterButton.swift`；新增 `NoticeOverlay.swift`；扩展 `PreviewLayoutTests.swift`。

**Interfaces:**
- 保留 `PreviewLayout.fit(imageSize:in:) -> CGRect`，调用方传入完整屏幕尺寸；移除会改变其父容器大小的提示 inset 和横屏单侧挤占。
- `ShutterButton` 消费 `CameraShootingMode`、`CameraRecordingState`、enabled/busy 和 action；照片白圆、视频红圆、确认录制红方块。
- `NoticeOverlay(message:onDismiss:)` 是布局覆盖层，消息变更时最多显示 6 秒；重要错误保留可展开详情，关闭定时器必须与消息标识匹配。

- [ ] 新增失败测试：390×844 和 844×390，4:3/16:9 的 `rect.midX/midY` 均等于屏幕中点；同尺寸显示/隐藏提示前后 rect 完全相等；无效尺寸仍返回零矩形。
- [ ] 运行 iPhone 测试，记录旧父布局下的 UI 回归失败；纯 fit 函数已有居中测试不能单独作为本次缺陷的复现证据。
- [ ] CameraView 改为整屏取景底层加安全区内控制覆盖层；相册、参数和连接入口维持 44 点可点击区域。全屏隐藏控制；未知录制状态不显示虚假录制计时。
- [ ] 更新按钮及可访问性文案；提示叠加不截断长中文。自动消失任务随视图退出取消。
- [ ] iPhone 测试通过后提交 `fix: keep preview centered beneath controls and notices`；完整屏幕回归测试留待任务 9。

## Task 4: 同步机身模式与曝光参数

**Files:** 新增 `GX85Core/Sources/GX85Core/LiveViewMetadata.swift`、对应测试、`Views/CameraParameterBar.swift`；修改 `LatestFrameDecoder.swift`、`CameraSession.swift`，新增 `CameraParameterTests.swift`。

**Interfaces:**
- `LiveViewMetadata: Equatable, Sendable`，可选模式、快门、光圈、ISO；`parse(datagram: Data) -> LiveViewMetadata?`。已识别包结构、长度、标签才允许读字段，未知/短包返回 nil。
- CameraSession `parameterOptions: [ExposureParameter: [CameraParameterOption]]`、`parameterValues: [ExposureParameter: String]`；`updateParameter(_:option:)`。
- `CameraParameterBar` 读取以上状态，点按打开选择层，通过 option.rawValue 发请求。

- [ ] 先写失败测试：已知相机元数据夹具解析照片和视频模式；短包、伪 JPEG、未知包格式不输出模式；相机模式变化更新按钮；未知值不把录像状态清零。
- [ ] 写参数测试：MF 不影响曝光；A 模式不可手动调快门，S 模式不可手动调光圈；相机拒绝值时界面保持旧值并给出原因；镜头最小光圈不同不共用错误缓存。
- [ ] 云端确认预期失败后实现。记录来自参考资料/真机的夹具来源与格式；若拿不到可验证的元数据结构，不实现无保护的偏移猜测，保留手动操作选择并报告自动同步待真机确认。
- [ ] 状态轮询沿用 2 秒节奏，菜单初连/镜头或模式变化时刷新；解析元数据使用有界最新值通道，不在主线程处理每个 UDP 包。
- [ ] 数值读回确认后更新 UI，使用相机允许值和当前模式禁用项；参数失败不能触发整个会话恢复。
- [ ] 测试通过后提交 `feat: sync shooting mode and exposure controls`。

## Task 5: 取景点按对焦

**Files:** 修改 `PreviewLayout.swift`、`CameraView.swift` 和 CameraControlService；新增 `GX85MonitorTests/FocusMappingTests.swift`。

**Interfaces:** `PreviewLayout.focusPoint(at:in:) -> CGPoint?`，输入屏幕点及实际图像 rect，输出归一化 0...1 坐标或 nil；CameraControlService 映射为 0...1000 整数并发送能力支持的触摸指令。

- [ ] 写失败测试：图像中点 -> (0.5,0.5)，四边界 -> 0/1，黑边 -> nil；横竖屏及改变源比例后取景同一相对点得到相同结果；控件区域不调用对焦处理器。
- [ ] 云端确认失败后实现坐标映射、非穿透控制层与位置框。AF 请求中的位置框为黄色，只有实际合焦反馈才能绿；超时/不支持显示提示，不触发照片。
- [ ] 验证 MF 和不支持位置调整的 AF 模式不会误发触摸快门；测试通过后提交 `feat: add image-coordinate tap focus`。

## Task 6: 相机相册与回放生命周期

**Files:** 新增 `CameraMedia.swift`、`ContentDirectoryReply.swift`、对应核心测试、`Camera/CameraMediaClient.swift`、`App/CameraAlbumModel.swift`、`Views/CameraAlbumView.swift`、`Views/CameraMediaPreview.swift`；扩展 CameraIdentityResolver 和 CameraSession。

**Interfaces:**
- `CameraMediaKind: Equatable, Sendable`：`photo`、`video`、`other`；`CameraMediaResource`：URL、MIME、原件/预览角色和可选大小；`CameraMediaItem: Identifiable, Sendable`：id、title、kind: CameraMediaKind、resources；`originalResource` 绝不退回缩略图。
- `CameraMediaPage`：items、numberReturned、totalMatches、nextStartingIndex。
- `ContentDirectoryReply.parse(data:cameraHost:) throws -> CameraMediaPage`，SOAP 与 DIDL 分层解析；`MediaURLPolicy.validate(_:cameraHost:) throws -> URL`。
- `CameraMediaClient(endpoint:descriptionURL:)`；`browse(start:count:) async throws -> CameraMediaPage`，每页 40 项，单次响应最大 4 MiB。
- CameraSession `beginPlayback() async throws -> CameraMediaClient`、`endPlayback() async`；CameraAlbumModel 发布 items/selection/loadState，提供 `loadNextPage()`、`close()`。

- [ ] 写失败测试：双层转义 XML、不同命名空间、多 res、MP4/RAW/JPEG 原件和缩略图区分、容器项、重复页、零返回和总数变化；外部 host、userinfo、https/其他协议及重定向被拒绝，数值 IP 只允许当前相机。
- [ ] 云端确认失败后实现描述服务解析、ContentDirectory Browse 及资源分类。优先描述服务 URL；发现失败时限定同一主机尝试 `/Server0/CDS_control` 的 60606 端口，失败明确报告，不扫描设备或 MAC 地址。
- [ ] iPhone 测试验证：录制中禁止回放；进入回放期间监看 watchdog 不重连；关闭相册恢复 recmode + stream；旧页任务在关闭/新连接后不能填回 UI。
- [ ] 实现分页网格、有限缩略图并发（最多 3）、32 MiB NSCache、单项预览；返回监看后保留本次失败原因，不能无限加载同一页。
- [ ] 核心和 iPhone 测试通过后提交 `feat: browse camera media with playback coordination`。

## Task 7: 有界下载与导出进度

**Files:** 新增 `Media/MediaDownloadService.swift`、`Media/MediaExportCoordinator.swift`、`Views/MediaExportView.swift` 及相应 iPhone 测试。

**Interfaces:**
- `MediaDownloading: Sendable` 提供 `download(_ resource: CameraMediaResource, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL`，返回本服务拥有的临时文件。
- `MediaDownloadService` 使用 URLSessionDownloadTask 的文件下载与 delegate 进度，连接到当前相机，串行下载一项；最大下载文件 8 GiB，预期/实际大小超限均失败。
- `MediaExportCoordinator` 为 MainActor，有选择项队列、当前项、进度、成功/失败项列表及 `cancel()`；临时文件成功交给保存组件前保持有效，消费后清理。

- [ ] 写失败测试：只有缩略图时不下载原片；Content-Length 未知仍可进度不确定；流式大文件不经 data(for:)；取消取消底层任务、后台中断、网络丢失、空间不足均返回失败并移除本次临时文件。
- [ ] 验证重定向仍仅限同相机，文件名只用于安全展示，临时路径由 UUID 生成；晚到 delegate 回调不能更新另一项任务。
- [ ] 云端确认失败后实现下载、逐项取消和进度。允许明确导出到文件的不兼容格式，原件不可用则显示限制原因，绝不改用预览图。
- [ ] 测试通过后提交 `feat: download original camera media with cancellation`。

## Task 8: 写入 iPhone 照片和文件

**Files:** 新增 `Media/PhotoLibraryWriter.swift`、`Views/FileExportSheet.swift`、`PhotoLibraryWriterTests.swift`；修改 MediaExportCoordinator、CameraAlbumView、Info.plist。

**Interfaces:** `PhotoLibraryWriting` 提供 `save(fileURL: URL, kind: CameraMediaKind) async throws`；`PhotoLibraryWriter` 使用 `PHPhotoLibrary.requestAuthorization(for: .addOnly)` 和 `performChanges`；可注入权限与保存回调以独立测试。`FileExportSheet` 是 UIDocumentPickerViewController 的 SwiftUI 包装，输入 `[URL]`，通过完成/取消回调报告结果。

- [ ] 先写失败测试：拒绝/受限权限不调用保存；照片/视频类型分别提交正确资源；系统保存失败不记为成功；多项导出部分失败不覆盖已成功项。
- [ ] 在 `Info.plist` 添加 `NSPhotoLibraryAddUsageDescription`：`将你选择的 GX85 照片和视频保存到 iPhone。` 不申请读取整库。
- [ ] 云端确认失败后实现 JPEG/MP4 保存，使用 PHAssetCreationRequest 的文件 URL 资源，结果取自系统完成回调；不能根据启动 performChanges 就标记成功。不被照片库接受的格式保留“保存到文件”选择，通过 `UIDocumentPickerViewController(forExporting:asCopy:)` 交给系统，不把视频装进 Data 或 FileDocument 的内存包装。
- [ ] 测试保存到文件取消不报成功；临时文件在导出器关闭前不能删除；后台/页面关闭取消未完成工作。
- [ ] 测试通过后提交 `feat: export selected media to Photos and Files`。

## Task 9: 整合、截图和交付

**Files:** 新增 `GX85Monitor/Debug/DebugCameraFixture.swift`、`GX85MonitorUITests/CameraLayoutUITests.swift`；修改 `GX85MonitorApp.swift`、`scripts/generate-project.py`、`scripts/check-project.py`、`.github/workflows/ios-build.yml`、README、协议/安装/真机验证文档。

- [ ] 调整工程生成器，把新增 App/单元测试文件及 UI 测试目标纳入共享 scheme；将版本号统一为 0.2.0、build 2，避免脚本覆盖新版本。
- [ ] 测试夹具限定 `#if DEBUG && targetEnvironment(simulator)`，仅显式启动参数启用。图案、模式、状态均标记“模拟画面 · 非相机连接”；Release 真机包不含夹具入口。
- [ ] UI 测试先在旧布局复现：`testNoticeDoesNotChangePreviewFrame` 记录取景 frame，再显示长提示，assert frame 完全相同；`testPortraitAndBothLandscapesStayCentered` 验证实际视图中心；`testControlTapDoesNotFocus` 验证覆盖控件不穿透。照片和视频主按钮分别测试可访问性状态。
- [ ] 云端验证 red/green 后保存竖屏、横屏两方向及长提示截图，分别显示照片/录像/参数/相册测试状态。通过 xcresult 附件导出实际模拟器截图，标签必须出现在截图中。
- [ ] 运行 `python scripts/generate-project.py`、`python scripts/check-project.py`；云端运行全量 `swift test --package-path GX85Core`、`xcodebuild test -project GX85Monitor.xcodeproj -scheme GX85Monitor -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath build/Simulator -resultBundlePath dist/iPhoneTests.xcresult CODE_SIGNING_ALLOWED=NO`。
- [ ] 用执行技能要求的独立最终审查，检查本计划的五类 Review Focus、并发/资源释放和真实设备限制；修复有效发现并对涉及部分重测，不因时间耗尽假报完成。
- [ ] 运行 `bash scripts/build-ipa.sh`，确认 ARM64 真机 Release 构建、IPA 完整性及包内版本 0.2.0；生成源码包、日志和带校验值的安装包。
- [ ] 发布前比较 GitHub 最新 head，使用非强制更新保留他人修改。向当前聊天交付可下载新包、真实模拟器截图、测试结果和逐项 GX85 待验清单。
- [ ] 真机清单必须包括：实体快门动作和新照片、机身视频模式同步、开始/停止录像、参数读回、横竖屏对焦位置、相册回放恢复、JPEG/MP4 导出到照片/文件、未支持格式的准确提示。没有硬件结果的项目保持“待真机验证”。

## 自检与交付边界

本计划覆盖已确认设计的全部五组交互、协议/安全边界及六项验收。控制状态/能力由任务 1 统一提供；任务 2 对外协调接口供布局和控制使用；任务 6 的媒体资源供任务 7 下载；任务 7 的文件供任务 8 保存。不得把“已实现 UI”“编译通过”“模拟器通过”写成“GX85 真机已修复”。
