# 验证状态

日期：2026-10-13。本地环境：Windows，无 Swift/Xcode；苹果验证已通过 GitHub macOS runner 执行，未连接 GX85 或 iPhone。

## 已执行

- Swift tree-sitter 语法解析：33 个 Swift 文件，无语法诊断（仅语法层面，不验证 Apple API、类型或链接）。
- Xcode 工程 OpenStep 解析、源文件路径及成员核对。
- 共享 scheme 的目标引用、Info.plist、资源 JSON 解析。
- iPhone 图标生成。
- 云端工作流 YAML、Windows 诊断和图标脚本、Mac 打包脚本的语法检查。
- 模拟器选择脚本使用受控运行时列表执行，确认选取最新可用 iPhone 并输出正确的构建环境变量。
- 源码 ZIP 完整性和必要文件（包括隐藏的 .github 工作流）核对。

## 独立审查

已执行一次独立只读审查，随后进行一轮源码修正，处理快门与恢复交错、旧画面标记延迟、启流观察窗口、横屏结果提示、异步队列缓存上限及诊断回应摘要。详情见 [审查记录](CODE_REVIEW.md)。相关逻辑测试随后在云端实际通过；相机通信和视觉效果仍待设备验证。

## 云端已执行

首次运行：[38387882048](https://github.com/a769568933/gx85-monitor-ios/actions/runs/38387882048)，代码提交 `5630e112b0148b4c293afecc8a850d2790477f1a`。

- Xcode 16.4，macOS runner。
- 核心测试：24 项，0 失败。
- iPhone 模拟器测试：15 项，0 失败。
- iPhone 真机 Release 编译：BUILD SUCCEEDED。
- 首次打包校验失败；lipo 将放在 verify_arch 参数后面的文件路径当成架构名。已把输入文件移到校验选项前面，并在下一轮成功验证。

成功复测：[38388698038](https://github.com/a769568933/gx85-monitor-ios/actions/runs/38388698038)，提交 `e82a31037ec233761990ffaf081bdb705161f0b1`。

- 核心测试：24 项，0 失败；iPhone 模拟器测试：15 项，0 失败。
- iPhone 真机 Release 编译和整个 workflow 成功。
- IPA 已生成，ZIP 完整性校验通过；ARM64 架构通过 lipo 校验。
- 下载至 Windows 后再次检查：构建产物 SHA256 与 GitHub 一致，IPA 解压完整，Info.plist 声明 iphoneos / 最低 iOS 16.0，主程序为 ARM64 Mach-O，资源文件存在，未签名。
- IPA 大小：288288 字节；SHA256：`1e5b70823b320eb6d64483fdd15c2d1d64160757f02bcb05df45e57a93427bc1`。
- [下载构建产物](https://github.com/a769568933/gx85-monitor-ios/actions/runs/38388698038/artifacts/11808055340)。

## 未执行

- 用户 Apple 账号签名及手机安装。
- iPhone UI 的实际渲染与 GX85 连接、监看、拍照验证。

本地的 Swift 命令仍不可用，不影响上述云端结果。工作流只有测试、真机编译和打包校验实际成功后才输出未签名 IPA。真机验证表见 DEVICE_TEST.md。
