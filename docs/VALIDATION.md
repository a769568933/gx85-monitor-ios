# 验证状态

日期：2026-10-13。环境：Windows，当前未安装 Swift/Xcode，未连接 GX85 或 iPhone。

## 已执行

- Swift tree-sitter 语法解析：33 个 Swift 文件，无语法诊断（仅语法层面，不验证 Apple API、类型或链接）。
- Xcode 工程 OpenStep 解析、源文件路径及成员核对。
- 共享 scheme 的目标引用、Info.plist、资源 JSON 解析。
- iPhone 图标生成。
- 云端工作流 YAML、Windows 诊断和图标脚本、Mac 打包脚本的语法检查。
- 模拟器选择脚本使用受控运行时列表执行，确认选取最新可用 iPhone 并输出正确的构建环境变量。
- 源码 ZIP 完整性和必要文件（包括隐藏的 .github 工作流）核对。

## 独立审查

已执行一次独立只读审查，随后进行一轮源码修正，处理快门与恢复交错、旧画面标记延迟、启流观察窗口、横屏结果提示、异步队列缓存上限及诊断回应摘要。详情见 [审查记录](CODE_REVIEW.md)。新增与已有 XCTest 尚未执行，不能把这些源码调整称为已经在运行中验证的修复。

## 未执行

- `swift test --package-path GX85Core`：尝试启动，系统找不到 swift；不是测试失败，也不是测试通过。
- Xcode 的 iOS 类型检查、编译、链接及 XCTest。
- macOS 云端 workflow。
- 真机 IPA 生成、签名和安装。
- iPhone UI 的实际渲染与 GX85 连接、监看、拍照验证。

所以当前交付是待苹果环境验证的工程。工作流只有测试和真机编译实际成功后才输出未签名 IPA。真机验证表见 DEVICE_TEST.md。
