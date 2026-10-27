# 参与贡献

谢谢你愿意一起改橙子！先看看你想改的东西在哪一层，大部分改动都不用碰 Swift。

## 橙子的三层结构

| 层 | 文件 | 谁来改 | 要重新编译吗 |
|---|---|---|---|
| 配置 | `config.json`、`chips.json` | 每个用户自己改，不进仓库 | 不用 |
| 扩展 | `prompts/*.md`、`ui.html`、`*_sync.py` | 欢迎 PR | 不用 |
| 核心 | `Orange.swift` | 欢迎 PR，改动请尽量小 | 要，`make build` |

## 最容易上手的贡献

1. **一个新的「模式」**：在 `prompts/` 里写一个 md，说清楚让 AI 读什么、输出什么（参考 `prompts/study.md`），再在 `chips.example.json` 里加一个按钮指向它（路径写 `{{APP_DIR}}/prompts/你的文件.md`）。
2. **一个新的本地数据源**：照着 `obsidian_sync.py` 写一个脚本，把某个本地来源转成知识库格式（每条一个 `.md`，frontmatter 至少有 `title / type / source / url / tags / summary / section / status / created`）。连接器类的来源（Notion、flomo……）不需要写代码，用户在对话里说一句就行。
3. **界面改进**：`ui.html` 直接用浏览器打开会进入演示模式，可以不启动 App 调样式。

## 提 PR 之前

- `make build` 能编译通过
- 不要提交 `config.json`、`chips.json`、`feishu_folders.json`、`.state.json`（已经在 `.gitignore` 里）
- 改了界面的话，可以用 `bash docs/screenshot/shoot.sh` 重新截 README 的图（中英文各一套，只用演示数据）
- 新增界面文案时，在 `ui.html` 底部的 `EN` 字典里补一条英文翻译（整句对应），没补的话英文界面里会显示中文原文
- 中文文案尽量直白，少用术语

## 提 Issue / 反馈 Bug

可以在 GitHub 提 Issue，也可以点橙子右上角的 🐞 反馈，或发邮件到 lxu0101@gmail.com。请附上：macOS 版本、用的后端（Claude / Codex）、橙子提示的原话或截图。截图前请检查有没有你的私人资料。
