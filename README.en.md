# Orange 🍊

**A hotkey desktop shell for Claude Code & Codex — one window, shared memory, your own knowledge base.**

English · [中文](README.md)

![Orange home](docs/images/home.png)

Orange is a small macOS window that drives the `claude` (Claude Code) or `codex` CLI behind the scenes. Press ⌥ Space anywhere, say what you need, and it gets done with whatever skills and connectors you already have.

## Why Orange

- **Two backends, one memory** — switch between Claude and Codex in one click. Both read the same `AGENTS.md` and memory folder, so nothing is lost when you switch.
- **Always one hotkey away** — ⌥ Space to summon; to-do lists render as checkable cards.
- **A knowledge base that follows your connectors** — whatever you've connected in Claude or Codex (flomo, Notion, Google Drive…), just say "sync it into my knowledge base". Obsidian works with a folder path. Paste links, PDFs, screenshots. Answers cite your own notes with links back to the source.
- **Built for Chinese workplace tools** — Feishu/Lark (via lark-cli), flomo and Notion work out of the box. The UI is in Chinese.
- **Hackable** — config is JSON, home-screen shortcuts are `chips.json`, the UI is a single HTML file. No rebuild needed.

| Chat with to-do cards | Knowledge base |
|---|---|
| ![chat](docs/images/chat.png) | ![kb](docs/images/kb.png) |

*Screenshots use demo data.*

## Install

**Let your AI do it:** send this to Claude Code or Codex:

> Please read https://github.com/lxu0101/orange-desk/blob/main/INSTALL.md and install Orange for me step by step.

**Or by hand** (macOS 13+, Xcode Command Line Tools):

```bash
git clone https://github.com/lxu0101/orange-desk.git ~/orange-desk
cd ~/orange-desk && make
```

Then double-click `橙子.app`. Log in to at least one backend first (`claude` → `/login`, or `codex login`).

Building from source means macOS won't block the app as "unidentified developer".

## Customize

| What | Where |
|---|---|
| Backend, model, permissions, workspace | `config.json` |
| Your preferences and memory | `~/Orange/AGENTS.md`, `~/Orange/shared/memory/` |
| Home-screen shortcuts and their prompts | copy `chips.example.json` → `chips.json` |
| UI | `ui.html` (reopen to apply) |
| Window / hotkey logic | `Orange.swift`, then `make build` |

## Bugs & contact

Click **🐞 反馈** (Feedback) in the top-right corner of Orange to open a pre-filled email, or write to **lxu0101@gmail.com**. GitHub [Issues](https://github.com/lxu0101/orange-desk/issues) are welcome too.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details. If Orange is useful to you, a ⭐ helps a lot.

## License

MIT
