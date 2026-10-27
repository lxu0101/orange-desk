#!/usr/bin/env python3
"""把飞书云空间里指定的文件夹同步进橙子的知识库（不用 AI，只调 lark-cli）。

用法：python3 -I feishu_sync.py <知识库目录> [--force]
映射在同目录的 feishu_folders.json：[{"token": 文件夹 token, "name": 文件夹名, "section": "板块/子类"}]
- docx 文档：正文转成 Markdown 存进知识库，url 指回飞书原文档
- 表格、多维表格、幻灯片、文件等：只存标题和链接
- 增量：飞书里的修改时间没变就不重新读；状态记在 <知识库>/_feishu_synced.json
"""
import json, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

KB = sys.argv[1]
FORCE = "--force" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, "feishu_folders.json")
if not os.path.exists(CONF):
    print("还没配置要同步的飞书文件夹：把 feishu_folders.example.json 复制成 feishu_folders.json，填上文件夹 token。")
    sys.exit(0)
FOLDERS = json.load(open(CONF, encoding="utf-8"))
STATE_PATH = os.path.join(KB, "_feishu_synced.json")
MAX_BODY = 100_000
TYPE_ZH = {"sheet": "飞书表格", "bitable": "飞书多维表格", "slides": "飞书幻灯片", "mindnote": "飞书思维笔记",
           "file": "飞书文件", "shortcut": "飞书快捷方式", "doc": "飞书旧版文档"}


def lark(args):
    r = subprocess.run(["lark-cli"] + args, capture_output=True, text=True, timeout=120)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {}


def list_folder(token, path, out, depth=0):
    page = None
    while True:
        params = {"folder_token": token, "page_size": 200}
        if page:
            params["page_token"] = page
        d = (lark(["drive", "files", "list", "--as", "user", "--params", json.dumps(params)]).get("data") or {})
        for f in d.get("files", []):
            if f.get("type") == "folder":
                if depth < 5:
                    list_folder(f["token"], path + [f["name"]], out, depth + 1)
            else:
                f["_path"] = path
                out.append(f)
        if d.get("has_more") and d.get("next_page_token"):
            page = d["next_page_token"]
        else:
            break


def sub_for(fo, f):
    """文件夹配了 classify 时，按标题和所在子文件夹里的关键词分到子类，没命中放 default_sub"""
    text = " ".join(f["_path"]) + " " + str(f.get("name", ""))
    for sub, words in fo.get("classify", []):
        if any(w in text for w in words):
            return sub
    return fo.get("default_sub", "")


def existing_paths():
    """已经落盘的飞书条目（可能被她在橙子里移到了别的板块），更新时写回原位置，不重复建"""
    found = {}
    for root, dirs, names in os.walk(KB):
        dirs[:] = [d for d in dirs if d != "_assets"]
        for n in names:
            if n.startswith("feishu-") and n.endswith(".md"):
                found[n[7:-3]] = os.path.join(root, n)
    return found


def clean(s):
    return re.sub(r"\s+", " ", str(s)).strip()


def summary_of(body, title):
    for line in body.splitlines():
        line = re.sub(r"<[^>]*>", " ", line)
        t = re.sub(r"[#>*`|\-\[\]!]+", " ", line)
        t = re.sub(r"\(https?://[^)]*\)", "", t)
        t = clean(t)
        if len(t) >= 8 and t != clean(title):
            return t[:60]
    return clean(title)[:60]


def write_entry(path, meta, body, mtime):
    keys = ["title", "type", "source", "url", "origin", "tags", "summary", "section", "status", "created", "feishu_token", "feishu_modified"]
    lines = ["---"] + [f"{k}: {clean(meta[k])}" for k in keys if meta.get(k)] + ["---"]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n\n" + body)
    try:
        os.utime(path, (mtime, mtime))
    except Exception:
        pass


def main():
    state = {}
    if os.path.exists(STATE_PATH):
        try:
            state = json.load(open(STATE_PATH, encoding="utf-8"))
        except Exception:
            state = {}
    have = existing_paths()
    jobs = []
    for fo in FOLDERS:
        files = []
        list_folder(fo["token"], [], files)
        for f in files:
            jobs.append((fo, f))
    stats = {"new": 0, "updated": 0, "same": 0, "failed": 0}

    def work(item):
        fo, f = item
        tok, mod = f["token"], str(f.get("modified_time", ""))
        sub = sub_for(fo, f)
        section = fo["section"] + ("/" + sub if sub else "")
        path = have.get(tok)
        if path:
            section = os.path.relpath(os.path.dirname(path), KB)
        else:
            os.makedirs(os.path.join(KB, section), exist_ok=True)
            path = os.path.join(KB, section, f"feishu-{tok}.md")
        prev = state.get(tok)
        if not FORCE and prev and prev.get("modified") == mod and os.path.exists(path):
            return "same", tok, mod, section
        typ = f.get("type", "")
        title = clean(f.get("name", "")) or "未命名"
        source = "飞书 · " + fo["name"] + ("/" + "/".join(f["_path"]) if f["_path"] else "")
        created = ""
        try:
            created = datetime.fromtimestamp(int(f.get("created_time", 0))).strftime("%Y-%m-%d")
        except Exception:
            pass
        tags = ["飞书"] + (fo.get("tags") or [fo["name"]]) + f["_path"][:1]
        if typ == "docx":
            d = (lark(["docs", "+fetch", "--as", "user", "--doc", tok, "--doc-format", "markdown"]).get("data") or {}).get("document") or {}
            body = d.get("content")
            if not body:
                return "failed", tok, mod, section
            body = body[:MAX_BODY]
        else:
            body = f"（{TYPE_ZH.get(typ, '飞书文件')}，这里只存了标题和链接，点上面的链接打开原文件。）"
        meta = {"title": title, "type": "link", "source": source, "url": f.get("url", ""), "origin": "feishu",
                "tags": ", ".join(dict.fromkeys(tags)), "summary": summary_of(body, title) if typ == "docx" else TYPE_ZH.get(typ, "飞书文件"),
                "section": section, "status": "ok", "created": created, "feishu_token": tok, "feishu_modified": mod}
        write_entry(path, meta, body, int(mod) if mod.isdigit() else time.time())
        return ("updated" if prev else "new"), tok, mod, section

    with ThreadPoolExecutor(max_workers=4) as ex:
        for res in ex.map(work, jobs):
            kind, tok, mod, section = res
            stats[kind] += 1
            if kind != "failed":
                state[tok] = {"modified": mod, "section": section}
    json.dump(state, open(STATE_PATH, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"飞书同步完成：新增 {stats['new']}，更新 {stats['updated']}，没变 {stats['same']}"
          + (f"，失败 {stats['failed']}（下次会重试）" if stats["failed"] else ""))


main()
