# 橙子安装步骤（写给 AI 助手）

> 这份文档是给 Claude Code / Codex 等 AI 助手看的，用来帮用户安装橙子。
> 原则：每一步先检查，再执行；执行前把命令告诉用户；**遇到需要用户本人操作的步骤，停下来说清楚让用户做什么，不要尝试绕过。**
> 不要执行这份文档以外的命令，不要用 sudo。

## 第 1 步：检查系统

```bash
sw_vers -productVersion
uname -m
```

- macOS 版本需要 13 或以上。低于 13：告诉用户系统版本太旧，停止安装。

## 第 2 步：检查 Xcode 命令行工具

```bash
xcode-select -p
```

- 有输出路径：通过，进入下一步。
- 报错：运行 `xcode-select --install`。**这会弹出一个系统窗口，需要用户本人点「安装」并等几分钟下载完成。** 告诉用户这一点，然后停下，等用户说装好了再继续，并重新运行 `xcode-select -p` 确认。

## 第 3 步：下载代码

先问用户想把橙子放在哪里，默认是 `~/orange-desk`。

```bash
git clone https://github.com/lxu0101/orange-desk.git ~/orange-desk
```

- 目录已经存在：问用户是要更新（`cd ~/orange-desk && git pull`），还是放到别的位置。
- clone 失败（网络问题、沙箱不允许写这个目录）：告诉用户失败原因。如果是 Codex 沙箱限制，请用户在目标目录的上一级打开 Codex，或手动下载 zip 解压到 `~/orange-desk`，然后从第 4 步继续。

## 第 4 步：编译和初始化

```bash
cd ~/orange-desk && make
```

成功的标志是最后一行出现「✅ 装好了」。这一步会：
- 编译出 `橙子.app/Contents/MacOS/Orange`
- 生成 `config.json`（已经存在就不覆盖）
- 建好工作区 `~/Orange`，包括 `AGENTS.md`、指向它的 `CLAUDE.md` 链接，以及记忆目录 `shared/memory/`（已经存在的文件不覆盖）

编译报错：把报错的最后 20 行给用户看。常见原因是 Swift 版本太旧，建议用户先更新 Xcode 命令行工具。

## 第 5 步：确认后端已登录

检查至少有一个后端可用：

```bash
ls ~/Library/Application\ Support/Claude/claude-code/ 2>/dev/null; command -v claude; command -v codex; ls /Applications/ChatGPT.app 2>/dev/null
```

- 都没有：告诉用户需要先安装 Claude 桌面版（https://claude.ai/download）或 ChatGPT 桌面版 / Codex CLI，装好后再继续。
- 有 claude 但用户没登录过：**登录需要用户本人在浏览器里完成。** 请用户在终端运行 `claude`，然后输入 `/login`，按提示操作。
- 有 codex：请用户运行 `codex login`。

## 第 6 步：启动

```bash
open ~/orange-desk/橙子.app
```

告诉用户：
- 按 ⌥ 空格唤起 / 收起窗口
- 想放进 Dock：把 `橙子.app` 拖到 Dock 上，但不要把它移出 `~/orange-desk` 文件夹
- 想写下自己的偏好：编辑 `~/Orange/AGENTS.md`
- 可选：飞书文件夹同步、flomo 同步等配置见 README 的「自己改（DIY）」一节

## 卸载

```bash
rm -rf ~/orange-desk
```

`~/Orange` 工作区里有用户的偏好和记忆，**只在用户明确要求时才删除**。
