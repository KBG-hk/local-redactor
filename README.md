# 本地脱敏中转站

macOS 14+ 菜单栏应用。把 Oracle SQL 和日志从剪贴板脱敏，再交给 AI。收到回复后，可把本次占位符换回原值。

## 使用

1. 双击 LocalRedactor.app。点击菜单栏的盾牌图标打开菜单。
2. 从编辑器复制文本，再按默认快捷键 **⌃⌥⌘S**。也可以从菜单选择「脱敏剪贴板」。
3. 选择「Oracle SQL」或「日志」，检查左右预览。在「隐私选项」中按需开启邮箱、URL 主机名或 SQL 字符串遮盖。选中原文可点击「遮盖此处」或「遮盖所有同文」，再用「撤销遮盖」撤销整次操作。
4. 按回车复制脱敏结果，再粘贴到 AI。勾选「附带 AI 提问」可同时复制模式对应的提问模板，预览会显示完整内容。复制 AI 回复后，点菜单的「还原 AI 回复」，确认后复制到原工作流。

对象名、表别名、CTE、IP、邮箱和 URL 主机名的映射有效期为 30 分钟。新脱敏结果、菜单「清除还原映射」或退出应用会清除旧映射。密钥、手动遮盖内容及由隐私选项遮盖的 SQL 字符串不可还原。复制只在当前设备可用。请检查列名、普通字面量和其他未高亮内容。Oracle 模式仅覆盖常见单条 SELECT，遇到超范围的内容会停在预览。系统提示剪贴板读取权限时，选择允许以载入文本。

## 本机编译和验证

~~~sh
./packaging/test-core.sh
./packaging/build-app.sh
./dist/LocalRedactor.app/Contents/MacOS/LocalRedactor --self-test
open ./dist/LocalRedactor.app
~~~

构建使用 Xcode 或 macOS Command Line Tools。输出是为当前机器架构编译并临时签名的本机试用包。烟测启动应用窗口，并使用独立的测试剪贴板。

详细开发边界与验收记录见 [主设计](docs/Design.md) 与 [实施与验收](docs/Implementation.md)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。
