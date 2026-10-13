# SDD ledger — plan: docs/superpowers/plans/2026-10-13-gx85-iphone-implementation.md

2026-10-13：用户确认规格与计划，选择在当前聊天直接执行。

Pre-flight 1→3：CameraEndpoint / LumixCommand / LumixResponse 供 HTTP 客户端使用，签名一致。
Pre-flight 2→3：JPEGFrameAssembler 和 LatestFrameMailbox 由接收/解码串行队列使用，无共享未保护状态。
Pre-flight 3→4：CommandSending / LiveViewReceiving 是会话注入边界，接收 start 仅在绑定成功后返回。
Pre-flight 4→5：App 层持有单一 CameraSession，布局变更不创建会话。
Pre-flight 1–5→6：核心测试与 iOS 测试分别执行，真机打包与 simulator 测试分开。

Ruling: 当前目录是新建专用项目，没有已有分支需要隔离；在此初始化 feature/gx85-monitor 分支，不额外创建 worktree — 避免把交付工程藏进嵌套目录 — 风险：今后其他人同时修改时需另行隔离。
Ruling: Windows 当前没有 Swift/Xcode，按已批准计划的“验证执行约定”先写测试再实现，苹果运行结果标记未执行 — 不用静态检查冒充通过 — 风险：需要云端运行后修复可能的类型/平台问题。
Ruling: 当前 Git 没有配置作者身份，保留本地变更，不伪造姓名/邮箱或执行提交 — 工程文件照常交付 — 风险：暂没有提交历史用于回退。

Task 1: in progress，先写协议测试。

Task 1: source and tests written; swift test could not start (swift unavailable), not a test failure or pass.
Task 2: source and tests written; XCTest execution pending macOS.
Task 3: HTTP/UDP/decoder source and HTTP boundary tests written; Apple platform verification pending.
Task 4: core policy tests and implementation written; session integration follows.

Ruling: GMaster 的握手值引用相机 UPnP UDN，原计划只用客户端 UUID 不能覆盖这种协议行为；增加针对已输入 IP 的单播标识读取、缓存和高级手动标识入口 — 不使用 iOS 多播，保留无回应时的兼容尝试 — 风险：部分 GX85 固件不回应单播时需要 Windows 诊断工具读取 UDN 后填入。

Task 3: engineering source and project created; static grammar/configuration checks pass; Xcode tests pending.
Task 4: session, cancellation and shutter implemented; integration tests pending Xcode.
Task 5: native-camera layout, portrait/landscape/fullscreen and layout tests implemented; simulator visual QA pending.
Task 6: workflow, device packaging, Windows installation guide and validation checklist written; cloud build not run.
Final review: fresh reviewer requested after local static integrity checks.

Final review returned: five Important findings and one Minor, no confirmed Critical. One source fix pass performed; runtime results remain unavailable.
Final: source correction — health/capture interleaving deferred until capture settles; recovery advances epoch. Regression test written before correction, XCTest pending.
Final: source correction — display-age ticker independent of HTTP; pending-health stale detection test written, XCTest pending.
Final: source correction — restart grace begins after successful response; core policy regression test written, XCTest pending.
Final: source correction — readable persistent shutter outcome in all orientations; visual QA pending.
Final: source correction — bounded ingress inbox and latest-image delivery slot; boundary tests written, XCTest pending.
Final: source correction — raw HTTP summaries connected to diagnostics; reviewed as Important because first-device compatibility needs evidence. Runtime pending.
Final: minor (deferred): none; original logging item regraded and source correction included.

Final: Ruling: Apple 编译/链接/XCTest 留待云端 — 当前无 Swift/Xcode，不以静态检查替代 — 风险：首轮云端仍可能暴露编译或测试问题。
Final: Ruling: GX85 的身份握手/单播/UDP 兼容留待真实相机 — 无相机回应或抓包 — 风险：可能需要按固件调整协议。
Final: Ruling: 横屏、安全区和字体的最终效果留待模拟器/手机 — 只有几何测试源码，无运行渲染 — 风险：可能需调整局部布局。
Final: Ruling: 签名安装、连续监看和拍照数量留待设备验收 — 没有已编译产物或设备 — 风险：不能提前承诺稳定性改善。

Workspace notes: no ignored SDD workspace was created because there are no commits or author identity; durable progress kept here. Do not remove this ledger while Apple/device verification is pending.

GitHub setup 2026-10-13: authenticated connector confirmed account a769568933. Connector exposes repository content APIs but not repository creation or workflow dispatch. Browser and Node UI runtime both fail to initialize (failed to write kernel assets: os error 3), and no local GitHub CLI credentials are available. No remote repository was created. Added main/master push workflow trigger so the initial upload can start CI without a separate dispatch tool once a repository exists.

GitHub upload attempt: user supplied a769568933/gx85-monitor-ios. Repository metadata API returned 404; authenticated login is a769568933, installed account list is empty, accessible repository list and targeted repository search are empty. No upload or remote mutation performed. Local origin configured to the supplied repository. Provider repository installation/access must be enabled before uploading.

GitHub upload succeeded: 67 files committed on main at 5630e112b0148b4c293afecc8a850d2790477f1a. Private repository and workflow file verified. Cloud run 38387882048 started on push; watching validation.

Cloud run 38387882048: 24 core + 15 iOS tests passed, iOS device Release BUILD SUCCEEDED. Packaging failed in lipo because -verify_arch consumes following architecture arguments, including the mistakenly trailing binary path. Moved input binary before -verify_arch arm64; next cloud run is acceptance verification. Added workflow path filters so documentation-only status updates do not repeat a validated build.

Cloud run 38388698038: SUCCESS. Exact corrected revision e82a31037ec233761990ffaf081bdb705161f0b1 passed 24 core tests + 15 iOS tests, device Release build, ARM64 validation, IPA packaging and upload. The packaging failure was observed in run 1 and no longer occurs in run 2.
Downloaded IPA artifact 11808055340. Artifact ZIP digest matched GitHub; local ZIP/plist/Mach-O verification passed. IPA is unsigned, arm64, minimum iOS 16.0, 288288 bytes, SHA256 1e5b70823b320eb6d64483fdd15c2d1d64160757f02bcb05df45e57a93427bc1.
Task 1–5: software implementations and 39 automated tests verified in cloud; camera and visual device acceptance remains open.
Task 6: cloud build and actual unsigned IPA delivery verified; user signing and installation remains open.
Prior Apple compile/test limitation has been resolved by cloud execution. Source and published repository preserved; no PR or branch cleanup needed for the explicitly authorized initial repository upload.
