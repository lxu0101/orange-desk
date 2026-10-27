#!/usr/bin/env python3
"""把 Obsidian 仓库（本地文件夹）里的笔记同步进橙子的知识库（不用 AI，只读 .md 文件）。

用法：python3 -I obsidian_sync.py <知识库目录> <Obsidian 仓库路径> [--force]
- 每篇笔记对应知识库里一个 obsidian-<编号>.md，url 是 obsidian:// 链接，点了直接在 Obsidian 里打开原笔记
- 增量：笔记修改时间没变就不重写；状态记在 <知识库>/_obsidian_synced.json
- 只读仓库，不会修改 Obsidian 里的任何文件
"""
import hashlib, json, os, re, sys, time
from datetime import datetime
from urllib.parse import quote

KB, VAULT = sys.argv[1], os.path.expanduser(sys.argv[2])
FORCE = "--force" in sys.argv
STATE_PATH = os.path.join(KB, "_obsidian_synced.json")
MAX_BODY, MAX_FILES = 100_000, 3000
NAME = os.path.basename(VAULT.rstrip("/"))

if not os.path.isdir(VAULT):
    print(f"找不到 Obsidian 仓库：{VAULT}")
    sys.exit(0)


def clean(s):
    return re.sub(r"\s+", " ", str(s)).strip()


def existing_paths():
    found = {}
    for root, dirs, names in os.walk(KB):
        dirs[:] = [d for d in dirs if d != "_assets"]
        for n in names:
            if n.startswith("obsidian-") and n.endswith(".md"):
                found[n[9:-3]] = os.path.join(root, n)
    return found


def split_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            return text[4:end], text[end + 4:].lstrip("\n")
    return "", text


def main():
    try:
        state = json.load(open(STATE_PATH, encoding="utf-8"))
    except Exception:
        state = {}
    have = existing_paths()
    files = []
    for root, dirs, names in os.walk(VAULT):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
        files += [os.path.join(root, n) for n in names if n.endswith(".md") and not n.startswith(".")]
    skipped = max(0, len(files) - MAX_FILES)
    files.sort(key=os.path.getmtime, reverse=True)
    stats = {"new": 0, "updated": 0, "same": 0}
    for f in files[:MAX_FILES]:
        rel = os.path.relpath(f, VAULT)
        key = hashlib.md5(rel.encode("utf-8")).hexdigest()[:12]
        mtime = int(os.path.getmtime(f))
        path = have.get(key)
        if not FORCE and state.get(key) == mtime and path and os.path.exists(path):
            stats["same"] += 1
            continue
        try:
            raw = open(f, encoding="utf-8").read()
        except Exception:
            continue
        fm, body = split_frontmatter(raw)
        body = body[:MAX_BODY]
        top = rel.split(os.sep)[0] if os.sep in rel else ""
        section = "Obsidian" + ("/" + top if top else "")
        if path:
            section = os.path.relpath(os.path.dirname(path), KB)
        else:
            os.makedirs(os.path.join(KB, section), exist_ok=True)
            path = os.path.join(KB, section, f"obsidian-{key}.md")
        title = os.path.splitext(os.path.basename(f))[0]
        m = re.search(r"^#\s+(.+)$", body, re.M)
        if m:
            title = clean(m.group(1))
        tags = ["Obsidian"] + ([top] if top else [])
        tm = re.search(r"^tags:\s*\[?([^\n\]]*)", fm, re.M)
        if tm:
            tags += [t.strip().strip("#'\"") for t in tm.group(1).split(",") if t.strip()][:3]
        summary = ""
        for line in body.splitlines():
            t = clean(re.sub(r"[#>*`|\-\[\]!]+", " ", line))
            if len(t) >= 8 and t != title:
                summary = t[:60]
                break
        meta = {"title": title, "type": "note", "source": "Obsidian · " + NAME,
                "url": f"obsidian://open?vault={quote(NAME)}&file={quote(rel[:-3])}", "origin": "obsidian",
                "tags": ", ".join(dict.fromkeys(tags)), "summary": summary or title[:60], "section": section,
                "status": "ok", "created": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")}
        lines = ["---"] + [f"{k}: {clean(v)}" for k, v in meta.items() if v] + ["---"]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n\n" + body)
        try:
            os.utime(path, (mtime, mtime))
        except Exception:
            pass
        stats["updated" if key in state else "new"] += 1
        state[key] = mtime
    json.dump(state, open(STATE_PATH, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"Obsidian 同步完成：新增 {stats['new']}，更新 {stats['updated']}，没变 {stats['same']}"
          + (f"，超过 {MAX_FILES} 篇的部分（{skipped} 篇）没同步" if skipped else ""))


main()
