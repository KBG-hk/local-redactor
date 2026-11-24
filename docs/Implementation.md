# 实施与验收

依据 [主设计](Design.md) 和已确认的首版方案。实际交付为 Apple Silicon 的 macOS 本机试用包。

| 节点 | 入口 | 状态落点与界面 | 验证结果 | 状态 |
| --- | --- | --- | --- | --- |
| 1. 脱敏与还原 | RedactionCore | 纯输入输出，返回预览区间与内存映射 | packaging/test-core.sh 通过 14 项测试，含 13 个 SQL 拦截用例、10 个合成试用样本。覆盖 Unicode 选区、重叠密钥、还原及到期清理 | verified |
| 2. 菜单栏 | LocalRedactor | 内存会话、左右预览、菜单及热键。只保存热键 | 签名包 --self-test 通过。实际打开 AppKit 窗口，使用独立的系统剪贴板验证取消、确认复制、手动遮盖、撤销、剪贴板变化时重新载入、还原和清除。全局组合键注册通过 | verified |
| 3. 打包与试用 | packaging/build-app.sh | dist/LocalRedactor.app 和 ZIP | 验证签名、macOS 14.0 目标、Apple Silicon 和沙盒。应用成功启动，沙盒阻止出站 TCP。102,340 字节日志的剪贴板到窗口预览 P95 为 90.0 毫秒（20 次，预热窗口） | verified |

本机通过 SwiftPM 和 Command Line Tools 打包，免装完整 Xcode。当前系统实际运行版本为 macOS 27.2。包采用临时签名，本机试用为交付边界。macOS 14 与其他 macOS 版本实机、Intel 包、外部 AI 服务和真实 Oracle 数据库均未测试。

[代表性试用记录](Trial.md)

## 0.2 增强

| 节点 | 入口 | 状态落点与界面 | 验收及发布条件 | 状态 |
| --- | --- | --- | --- | --- |
| 可选识别和批量遮盖 | Redactor、SensitiveRules、OracleRedaction | 规则选项、源文选区、当前预览和内存映射 | 核心测试验证默认行为、URL 凭据、邮箱主机名还原、Oracle 引号、Unicode 匹配和密钥优先级。共 20 项测试通过 | verified |
| 可选模板和出包 | PreviewModel、PreviewView、ApplicationController、packaging | 只在当前预览保存选项，复制内容与预览一致 | 签名包烟测验证选项切换、批量撤销、模板复制、沙盒和性能。签名包烟测通过，102,375 字节日志开启邮箱和 URL 主机名时 P95 为 126.6 毫秒（20 次）。ZIP 解压后签名及版本通过 | verified |
