// 橙子：桌面上的 agent 对话窗口，后端可在 Claude 和 Codex 之间切换。界面在 ui.html，这里负责窗口、快捷键和调用 claude / codex
import AppKit
import Carbon
import WebKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
// 右上角 🐞 反馈 bug 发到这个邮箱；fork 之后改成你自己的
let bugEmail = "lxu0101@gmail.com"
// 橙子的目录 = 橙子.app 所在的文件夹（ui.html、config.json 都在这里），所以仓库放在哪都能用
let appDir: String = {
    let dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    return FileManager.default.fileExists(atPath: dir + "/ui.html") ? dir : home + "/orange-desk"
}()
let stateFile = appDir + "/.state.json"

struct Config {
    var workdir = home + "/Orange"
    var permissionMode = "acceptEdits"
    var allowedTools: [String] = []
    var model = ""
    var claudePath = ""
    // 后端：claude 或 codex。Codex 用只能写工作区的沙箱，后台自动运行不弹确认
    var backend = "claude"
    var codexPath = ""
    var codexModel = ""
    var codexSandbox = "workspace-write"
    var codexNetwork = true
    // 知识库：flomo 自动同步默认关（没连 flomo 的人跑了也是白跑）；kbTopics 是 flomo 导入时保留哪些主题
    var flomoSync = false
    var kbTopics = "工作、学习、产品、行业观察"
    var theme: [String: String] = [:]   // 名字 / 图标 / 主色，比如 {"name": "柠檬", "icon": "🍋", "accent": "#e0b400"}
    var obsidianVault = ""   // Obsidian vault 的路径；填了，知识库里就多一个「同步 Obsidian」（本地文件夹，不用 AI）

    static func load() -> Config {
        var c = Config()
        defer { try? FileManager.default.createDirectory(atPath: c.workdir, withIntermediateDirectories: true) }
        guard let data = FileManager.default.contents(atPath: appDir + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = obj["workdir"] as? String, !v.isEmpty { c.workdir = v }
        if let v = obj["permissionMode"] as? String, !v.isEmpty { c.permissionMode = v }
        if let v = obj["allowedTools"] as? [String] { c.allowedTools = v }
        if let v = obj["model"] as? String { c.model = v }
        if let v = obj["claudePath"] as? String { c.claudePath = v }
        if let v = obj["backend"] as? String, v == "claude" || v == "codex" { c.backend = v }
        if let v = obj["codexPath"] as? String { c.codexPath = v }
        if let v = obj["codexModel"] as? String { c.codexModel = v }
        if let v = obj["codexSandbox"] as? String, ["read-only", "workspace-write", "danger-full-access"].contains(v) { c.codexSandbox = v }
        if let v = obj["codexNetwork"] as? Bool { c.codexNetwork = v }
        if let v = obj["flomoSync"] as? Bool { c.flomoSync = v }
        if let v = obj["kbTopics"] as? String, !v.isEmpty { c.kbTopics = v }
        if let v = obj["theme"] as? [String: String] { c.theme = v }
        if let v = obj["obsidianVault"] as? String { c.obsidianVault = (v as NSString).expandingTildeInPath }
        return c
    }
}

// 版本目录会随 Claude 桌面版更新变化，每次取最新的那个
func findClaude(_ config: Config) -> String? {
    let fm = FileManager.default
    if !config.claudePath.isEmpty, fm.isExecutableFile(atPath: config.claudePath) { return config.claudePath }
    let root = home + "/Library/Application Support/Claude/claude-code"
    let versions = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
        .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
        .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for v in versions {
        for h in (try? fm.contentsOfDirectory(atPath: root + "/" + v)) ?? [] {
            let bin = "\(root)/\(v)/\(h)/claude.app/Contents/MacOS/claude"
            if fm.isExecutableFile(atPath: bin) { return bin }
        }
    }
    return nil
}

// Codex 命令行藏在 ChatGPT 桌面版里
func findCodex(_ config: Config) -> String? {
    let fm = FileManager.default
    let candidates = [config.codexPath,
                      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                      home + "/.codex/plugins/.plugin-appserver/codex-cli/bin/codex",
                      "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    return candidates.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
}

// 橙子的界面会把 Markdown 任务列表渲染成可勾选的待办卡片，所以要告诉模型用这个格式。
// Codex 没有追加系统提示词的开关，只能放在新对话第一条消息前面；还原历史时按 orangeMarker 把它去掉
let orangeMarker = "（你运行在「橙子」桌面窗口里"
let orangeHint = "（你运行在「橙子」桌面窗口里：待办、行动项、今日清单、下一步要做的事，请用 Markdown 任务列表输出（每行 `- [ ] 事项`，已完成写 `- [x] 事项`），界面会渲染成可勾选的待办卡片；普通说明性列表不要用这个格式。只要内容是待办，每次都必须单独用 `- [ ] 事项` 一行一条输出，一条一行，不要把它们挤在一行里写成 ①②③，不要放进表格或别的列表项里。）\n\n"

// 读「系统设置 → 网络 → 代理」里的 HTTPS 代理，config.json 的 proxy 优先
func systemProxy() -> String? {
    if let data = FileManager.default.contents(atPath: appDir + "/config.json"),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let p = obj["proxy"] as? String, !p.isEmpty { return p }
    guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
          s["HTTPSEnable"] as? Int == 1,
          let host = s["HTTPSProxy"] as? String, let port = s["HTTPSPort"] as? Int else { return nil }
    return "http://\(host):\(port)"
}

func loadState() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: stateFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

func saveState(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        FileManager.default.createFile(atPath: stateFile, contents: data)
    }
}

// ---------- 模型选择 ----------
// Claude：留空 = 命令行默认。部分模型（比如 Fable 5.1）需要账号有额外额度，没有的话选了会直接报错
let claudeModels: [(id: String, name: String)] = [
    ("", "默认"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
    ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1（需额外额度）")]

func claudeShortName(_ id: String) -> String {
    for m in claudeModels where m.id == id { return m.name.components(separatedBy: "（").first ?? m.name }
    return id
}

struct CodexModel { let id: String; let name: String; let efforts: [String]; let defaultEffort: String }

// Codex 自己缓存了可选模型和各模型支持的推理档位
func codexModelList() -> [CodexModel] {
    guard let data = FileManager.default.contents(atPath: home + "/.codex/models_cache.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = obj["models"] as? [[String: Any]] else { return [] }
    return arr.filter { ($0["visibility"] as? String) == "list" }
        .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
        .compactMap { m in
            guard let slug = m["slug"] as? String else { return nil }
            let levels = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
            return CodexModel(id: slug, name: m["display_name"] as? String ?? slug, efforts: levels, defaultEffort: m["default_reasoning_level"] as? String ?? "")
        }
}

// ~/.codex/config.toml 顶层的 model 和 model_reasoning_effort
func codexConfigDefaults() -> (model: String, effort: String) {
    let raw = (try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)) ?? ""
    func val(_ key: String) -> String {
        for line in raw.split(separator: "\n") {
            if line.hasPrefix("[") { break }
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return ""
    }
    return (val("model"), val("model_reasoning_effort"))
}

// 模型名会拼进命令行参数，只放行安全字符
func safeToken(_ s: String) -> String { s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } ? s : "" }

// 一条正在跑的任务：每个对话各跑各的子进程，切到别的对话也不会被打断。
// events 记着它到现在发过的所有事件，切回来时连同 baseline（开跑前的历史）一起重放
// 子进程的标准输出：边读边攒（管道不及时读走会写满卡住），结束时一次取出
final class OutBuf {
    private var data = Data()
    private let lock = NSLock()
    func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

class Job {
    var process: Process?
    var buffer = Data()
    let backend: String
    var sessionId: String?
    var title: String?
    var baseline: [[String: Any]] = []
    var events: [[String: Any]] = []
    init(backend: String, sessionId: String?, title: String?) {
        self.backend = backend; self.sessionId = sessionId; self.title = title
    }
}

class Controller: NSObject, WKScriptMessageHandler, WKUIDelegate, NSWindowDelegate {
    let window: NSWindow
    let web: WKWebView
    var jobs: [Job] = []        // 正在跑的任务，可以同时有好几个
    var viewed: Job?            // 界面当前正在看的那个任务；没在看正在跑的任务就是 nil
    var unread = Set<String>()  // 在后台跑完、还没点开看过的对话
    var kbJob: Process?         // 知识库的整理任务（读网页/PDF、识别截图、同步 flomo），同一时间一个
    var kbRerun = false
    var kbUndo: [String: Any]?
    var state = loadState()
    let config = Config.load()
    var lastClaudeModel = ""    // claude 上一轮 init 事件里报的实际模型，用来显示「默认」到底是谁
    // 选中的模型：空 = 跟随各家自己的默认。按后端分别记，config.json 里的 model / codexModel 是初始值
    var claudeModel: String { safeToken(state["model_claude"] as? String ?? config.model) }
    var codexModel: String { safeToken(state["model_codex"] as? String ?? config.codexModel) }
    var codexEffort: String { safeToken(state["effort_codex"] as? String ?? "") }
    // 界面语言：用户选过就用选的，没选过看系统语言列表里有没有中文（有就显示中文，否则英文）
    var lang: String { (state["lang"] as? String) ?? (Locale.preferredLanguages.contains { $0.hasPrefix("zh") } ? "zh" : "en") }
    // 界面上选的后端；每个对话各属一家，换后端就是开新对话
    var backend: String { (state["backend"] as? String ?? config.backend) == "codex" ? "codex" : "claude" }

    override init() {
        let wc = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: wc)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        wc.userContentController.add(self, name: "agent")
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window.title = "橙子"
        window.minSize = NSSize(width: 420, height: 480)
        window.contentView = web
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("OrangeMain")
        if !window.setFrameUsingName("OrangeMain") { window.center() }
        if state["pinned"] as? Bool == true { window.level = .floating }

        let ui = URL(fileURLWithPath: appDir + "/ui.html")
        web.loadFileURL(ui, allowingReadAccessTo: URL(fileURLWithPath: appDir))
        window.makeKeyAndOrderFront(nil)
    }

    // 关窗只是隐藏，⌥ 空格 或点 Dock 图标再叫出来；⌘Q 才是真退出
    // 网页里的「选择文件…」要有系统文件对话框，WKWebView 默认什么都不弹，得自己接
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { window.orderOut(nil); return false }

    func toggle() {
        if window.isVisible && NSApp.isActive && window.isKeyWindow {
            window.orderOut(nil)
            NSApp.hide(nil)
        } else {
            show()
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        emit(["type": "focus"])
    }

    func emit(_ ev: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ev),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.onAgent && window.onAgent(\(json))")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msg = message.body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "send":
            let t = msg["text"] as? String ?? ""
            let imgs = msg["images"] as? [[String: String]] ?? []
            if !t.isEmpty || !imgs.isEmpty { run(t, images: imgs) }
        case "backend":
            if let b = msg["value"] as? String, b == "claude" || b == "codex", b != backend {
                if b == "codex", findCodex(config) == nil {
                    emit(["type": "error", "text": "找不到 Codex 程序。它在 ChatGPT 桌面版里，请确认已安装，或在 config.json 里填 codexPath。"])
                    emit(["type": "backend", "value": backend]); return
                }
                state["backend"] = b
                state["sessionId"] = nil
                viewed = nil
                saveState(state)
                emit(["type": "cleared"])
                emit(["type": "backend", "value": b])
                emitModels()
                emitHistory()
            }
        case "model":
            let v = safeToken(msg["value"] as? String ?? "")
            state[backend == "codex" ? "model_codex" : "model_claude"] = v
            if backend == "codex" { state["effort_codex"] = nil }   // 换了模型，之前选的推理档位可能不支持
            saveState(state)
            emitModels()
        case "effort":
            state["effort_codex"] = safeToken(msg["value"] as? String ?? "")
            saveState(state)
            emitModels()
        case "stop": viewed?.process?.interrupt()
        case "new":
            viewed = nil   // 正在跑的任务留在后台继续，只是不再看它
            state["sessionId"] = nil
            saveState(state)
            emit(["type": "cleared"])
            emitHistory()
        case "load":
            if let id = msg["id"] as? String { openConvo(id) }
        case "delete":
            if let id = msg["id"] as? String {
                state["convos"] = convos().filter { $0["id"] as? String != id }
                jobs.filter { $0.sessionId == id }.forEach { $0.process?.terminate() }
                unread.remove(id)
                if state["sessionId"] as? String == id { state["sessionId"] = nil; viewed = nil; emit(["type": "cleared"]) }
                saveState(state)
                emitHistory()
            }
        case "pin":
            let pinned = !(state["pinned"] as? Bool ?? false)
            state["pinned"] = pinned
            saveState(state)
            window.level = pinned ? .floating : .normal
            emit(["type": "pinned", "value": pinned])
        case "bug":
            // 打开一封写好标题和模板的邮件，系统版本、当前后端自动填上
            let body = "（最好附上截图；截图前看一下有没有私人资料）\n\n- 遇到了什么问题：\n- 出问题前你做了哪几步（按顺序写）：\n- 你本来希望它怎样：\n\n系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n后端：\(backend == "codex" ? "Codex" : "Claude")\n"
            var c = URLComponents()
            c.scheme = "mailto"; c.path = bugEmail
            c.queryItems = [URLQueryItem(name: "subject", value: "【橙子 Bug】"), URLQueryItem(name: "body", value: body)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        case "open":
            if let u = msg["url"] as? String, let url = URL(string: u) {
                // 链接里的 file:// 只放行知识库目录里的文件，别的本地路径不打开
                if url.isFileURL { if url.standardizedFileURL.path.hasPrefix(kbDir + "/") { NSWorkspace.shared.open(url) } }
                else if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
            }
        case "todo":
            if let k = msg["key"] as? String, let d = msg["done"] as? Bool {
                var todos = state["todos"] as? [String: Bool] ?? [:]
                todos[k] = d
                state["todos"] = todos
                saveState(state)
            }
        case "lang":
            if let v = msg["value"] as? String, v == "zh" || v == "en" { state["lang"] = v; saveState(state) }
        case "ready":
            emit(["type": "lang", "value": lang])
            if !config.theme.isEmpty { var t: [String: Any] = config.theme; t["type"] = "theme"; emit(t) }
            emit(["type": "backend", "value": backend])
            if let d = FileManager.default.contents(atPath: appDir + "/chips.json"), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { emit(["type": "chips", "items": arr]) }
            emitModels()
            emit(["type": "pinned", "value": state["pinned"] as? Bool ?? false])
            emit(["type": "todos", "value": state["todos"] as? [String: Bool] ?? [:]])
            emitHistory()
            if let id = state["sessionId"] as? String { openConvo(id) }
            if backend == "codex" {
                if findCodex(config) == nil { emit(["type": "error", "text": "没找到 Codex 程序，请确认已安装 ChatGPT 桌面版，或在 config.json 里填 codexPath。"]) }
            } else if findClaude(config) == nil {
                emit(["type": "error", "text": "没找到 Claude 桌面版自带的 claude 程序，请在 config.json 里填 claudePath。"])
            }
        default: if type.hasPrefix("kb_") { kbHandle(type, msg) }
        }
    }

    // 每条消息起一个子进程（claude -p 或 codex exec），用各自的 resume 接上同一会话；
    // 两家用同一个工作目录，所以 AGENTS.md / CLAUDE.md、共用记忆、skill、lark-cli 两边都能用。
    // 提示词走 stdin：claude 用 stream-json（文字和图片同一条消息），codex 用 `-`（图片落临时文件，用 -i 传）
    func run(_ text: String, images: [[String: String]] = []) {
        // 快捷按钮里可以写 {{APP_DIR}}，指向橙子所在的文件夹（比如 {{APP_DIR}}/prompts/study.md）
        let titleText = text.replacingOccurrences(of: "{{APP_DIR}}/", with: "")
        let text = text.replacingOccurrences(of: "{{APP_DIR}}", with: appDir)
        guard viewed == nil else { emit(["type": "error", "text": "这个对话上一条还在处理，等它完成或按 Esc 停止。"]); return }
        let sessionId = state["sessionId"] as? String
        let useCodex = backend == "codex"
        var bin = ""
        var args: [String] = []
        var stdinData = Data()
        var tmp: [String] = []

        if useCodex {
            guard let b = findCodex(config) else {
                emit(["type": "error", "text": "找不到 Codex 程序。它在 ChatGPT 桌面版里，请确认已安装，或在 config.json 里填 codexPath。"]); return
            }
            bin = b
            args = ["exec"]
            if sessionId != nil { args.append("resume") }
            // -i 在 exec 里能接多个值，所以图片放最前，后面紧跟别的开关把它截断
            for (i, img) in images.enumerated() {
                guard let type = img["media_type"], let b64 = img["data"], let d = Data(base64Encoded: b64) else { continue }
                let ext = type.contains("jpeg") ? "jpg" : (type.contains("png") ? "png" : "img")
                let path = NSTemporaryDirectory() + "orange-\(UUID().uuidString)-\(i).\(ext)"
                if FileManager.default.createFile(atPath: path, contents: d) { tmp.append(path); args += ["-i", path] }
            }
            args += ["--json", "--skip-git-repo-check",
                     "-c", "approval_policy=\"never\"",
                     "-c", "sandbox_mode=\"\(config.codexSandbox)\""]
            if config.codexSandbox == "workspace-write" && config.codexNetwork { args += ["-c", "sandbox_workspace_write.network_access=true"] }
            // 用 -c 覆盖：新会话和续聊都认，续聊时也能中途换模型
            if !codexModel.isEmpty { args += ["-c", "model=\"\(codexModel)\""] }
            let eff = codexEffective().effort
            if !eff.isEmpty { args += ["-c", "model_reasoning_effort=\"\(eff)\""] }
            if let s = sessionId { args.append(s) }
            args.append("-")
            let body = text.isEmpty ? "请看图片。" : text
            stdinData = Data(((sessionId == nil ? orangeHint : "") + body).utf8)
        } else {
            guard let b = findClaude(config) else { emit(["type": "error", "text": "找不到 claude 程序。"]); return }
            bin = b
            args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-mode", config.permissionMode]
            if !config.allowedTools.isEmpty { args += ["--allowedTools"] + config.allowedTools }
            if !claudeModel.isEmpty { args += ["--model", claudeModel] }
            if let s = sessionId { args += ["--resume", s] }
            var content: [[String: Any]] = images.compactMap { img in
                guard let type = img["media_type"], let data = img["data"] else { return nil }
                return ["type": "image", "source": ["type": "base64", "media_type": type, "data": data]]
            }
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            let userMsg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            guard var line = try? JSONSerialization.data(withJSONObject: userMsg) else { return }
            line.append(0x0A)
            stdinData = line
            // 橙子的界面会把 Markdown 任务列表渲染成可勾选的待办卡片
            args += ["--append-system-prompt", orangeHint.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let job = Job(backend: useCodex ? "codex" : "claude", sessionId: sessionId,
                      title: sessionId == nil ? (titleText.isEmpty ? "[图片]" : titleText) : nil)
        if let s = sessionId { job.baseline = useCodex ? codexTranscript(s) : transcript(s) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // 从 Finder 启动时拿不到终端里的代理变量，直连会 403，这里改用系统代理
        if env["HTTPS_PROXY"] == nil, let proxy = systemProxy() {
            env["HTTPS_PROXY"] = proxy
            env["HTTP_PROXY"] = proxy
            env["NO_PROXY"] = env["NO_PROXY"] ?? "localhost,127.0.0.1,::1,.local"
        }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(job, d) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for f in tmp { try? FileManager.default.removeItem(atPath: f) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.consume(job, rest)
                if proc.terminationStatus != 0 && proc.terminationReason == .exit && !errText.isEmpty {
                    self.jemit(job, ["type": "error", "text": String(errText.suffix(500))])
                }
                job.process = nil
                self.jobs.removeAll { $0 === job }
                self.jemit(job, ["type": "end"])
                if self.viewed === job { self.viewed = nil }
                else if let s = job.sessionId, self.convos().contains(where: { $0["id"] as? String == s }) { self.unread.insert(s) }
                self.emitHistory()
            }
        }
        do {
            try p.run()
            job.process = p
            jobs.append(job)
            viewed = job
            let shown: [String] = images.compactMap { img in
                guard let t = img["media_type"], let d = img["data"] else { return nil }
                return "data:\(t);base64,\(d)"
            }
            job.events.append(["type": "me", "text": text, "images": shown])
            jemit(job, ["type": "start"])
            emitHistory()
            // 图片可能有几 MB，放后台写，别卡住界面；写完关掉 stdin，对方才知道消息结束了
            DispatchQueue.global().async {
                inp.fileHandleForWriting.write(stdinData)
                try? inp.fileHandleForWriting.close()
            }
        } catch {
            for f in tmp { try? FileManager.default.removeItem(atPath: f) }
            emit(["type": "error", "text": "启动失败：\(error.localizedDescription)"])
        }
    }

    // ---------- 历史对话：列表存在 .state.json（每条记着是哪个后端），内容从各家自己的会话记录还原 ----------
    func convos() -> [[String: Any]] { state["convos"] as? [[String: Any]] ?? [] }

    func upsertConvo(newId: String, oldId: String?, title: String?, backend: String) {
        var list = convos()
        let now = Date().timeIntervalSince1970
        if let i = list.firstIndex(where: { $0["id"] as? String == newId || ($0["id"] as? String) == oldId }) {
            list[i]["id"] = newId
            list[i]["updated"] = now
        } else {
            let title = String((title ?? "新对话").prefix(40))
            list.append(["id": newId, "title": title, "updated": now, "backend": backend])
        }
        state["convos"] = list
    }

    // 当前真正会用的 Codex 模型和推理档位：没选就用 ~/.codex/config.toml 的，选了模型没选档位就用该模型的默认档
    func codexEffective() -> (list: [CodexModel], id: String, model: CodexModel?, effort: String) {
        let list = codexModelList()
        let def = codexConfigDefaults()
        let id = codexModel.isEmpty ? def.model : codexModel
        let cur = list.first { $0.id == id }
        let efforts = cur?.efforts ?? []
        var eff = codexEffort
        if !efforts.contains(eff) {
            eff = (codexModel.isEmpty && efforts.contains(def.effort)) ? def.effort : (cur?.defaultEffort ?? "")
        }
        return (list, id, cur, eff)
    }

    func emitModels() {
        if backend == "codex" {
            let e = codexEffective()
            emit(["type": "models", "backend": "codex",
                  "items": e.list.map { ["id": $0.id, "name": $0.name] },
                  "current": e.id, "label": e.model?.name ?? e.id, "efforts": e.model?.efforts ?? [String](), "effort": e.effort])
        } else {
            let cur = claudeModel
            let label = cur.isEmpty ? (lastClaudeModel.isEmpty ? "默认" : "默认 · " + claudeShortName(lastClaudeModel)) : claudeShortName(cur)
            emit(["type": "models", "backend": "claude",
                  "items": claudeModels.map { ["id": $0.id, "name": $0.name] },
                  "current": cur, "label": label, "efforts": [String](), "effort": ""])
        }
    }

    func emitHistory() {
        let list = convos().sorted { ($0["updated"] as? Double ?? 0) > ($1["updated"] as? Double ?? 0) }
        emit(["type": "history", "items": list, "current": state["sessionId"] as? String ?? "",
              "running": jobs.compactMap { $0.sessionId }, "unread": Array(unread)])
    }

    func openConvo(_ id: String) {
        // 旧记录没有 backend 字段，都是 Claude 的
        let b = convos().first { $0["id"] as? String == id }?["backend"] as? String ?? "claude"
        state["backend"] = b == "codex" ? "codex" : "claude"
        state["sessionId"] = id
        unread.remove(id)
        saveState(state)
        emit(["type": "backend", "value": backend])
        emitModels()
        // 正在后台跑的对话：重放「开跑前的历史 + 它到现在发过的事件」，再把界面切回处理中
        let running = jobs.first { $0.sessionId == id }
        viewed = running
        let events = running.map { $0.baseline + $0.events } ?? (backend == "codex" ? codexTranscript(id) : transcript(id))
        emit(["type": "transcript", "events": events])
        emit(["type": "busy", "value": running != nil])
        emitHistory()
    }

    func sessionFile(_ id: String) -> String? {
        let root = home + "/.claude/projects"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let f = "\(root)/\(d)/\(id).jsonl"
            if FileManager.default.fileExists(atPath: f) { return f }
        }
        return nil
    }

    func transcript(_ id: String) -> [[String: Any]] {
        guard let f = sessionFile(id), let raw = try? String(contentsOfFile: f, encoding: .utf8) else {
            return [["type": "error", "text": "这段对话的记录找不到了。"]]
        }
        var events: [[String: Any]] = []
        var open = false
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = o["message"] as? [String: Any] else { continue }
            let type = o["type"] as? String ?? ""
            if o["isMeta"] as? Bool == true || o["isSidechain"] as? Bool == true { continue }
            if type == "user" {
                var text = ""
                var images: [String] = []
                if let c = msg["content"] as? String { text = c }
                else if let blocks = msg["content"] as? [[String: Any]] {
                    text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    images = blocks.filter { $0["type"] as? String == "image" }.compactMap { b in
                        guard let src = b["source"] as? [String: Any], let t = src["media_type"] as? String, let d = src["data"] as? String else { return nil }
                        return "data:\(t);base64,\(d)"
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (text.isEmpty && images.isEmpty) || text.hasPrefix("<") { continue }
                if open { events.append(["type": "end"]) }
                events.append(["type": "me", "text": text, "images": images])
                events.append(["type": "start"])
                open = true
            } else if type == "assistant", let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty { events.append(["type": "text", "text": t]) }
                    if b["type"] as? String == "tool_use", let n = b["name"] as? String { events.append(["type": "tool", "name": n, "input": b["input"] ?? [:]]) }
                }
            }
        }
        if open { events.append(["type": "end"]) }
        return events
    }

    // Codex 的会话记录在 ~/.codex/sessions/年/月/日/rollout-时间-<id>.jsonl
    func codexSessionFile(_ id: String) -> String? {
        let root = home + "/.codex/sessions"
        guard let en = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let rel as String in en where rel.hasSuffix("-\(id).jsonl") { return root + "/" + rel }
        return nil
    }

    // 工具调用里能看的一句话：custom_tool_call 的 input 是一段 JS，里面有 cmd:"..."；function_call 的 arguments 是 JSON
    func codexToolSummary(_ p: [String: Any]) -> String {
        let raw = (p["input"] as? String) ?? (p["arguments"] as? String) ?? ""
        if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let c = o["cmd"] ?? o["command"] {
            if let arr = c as? [Any] { return arr.map { "\($0)" }.joined(separator: " ") }
            return "\(c)"
        }
        if let re = try? NSRegularExpression(pattern: #"cmd:\s*"((?:[^"\\]|\\.)*)""#) {
            let ns = raw as NSString
            let found = re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            if !found.isEmpty { return found.joined(separator: " ; ") }
        }
        return String(raw.prefix(120))
    }

    func codexTranscript(_ id: String) -> [[String: Any]] {
        guard let f = codexSessionFile(id), let raw = try? String(contentsOfFile: f, encoding: .utf8) else {
            return [["type": "error", "text": "这段 Codex 对话的记录找不到了。"]]
        }
        var events: [[String: Any]] = []
        var open = false
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any] else { continue }
            let t = p["type"] as? String ?? ""
            if t == "message" {
                let role = p["role"] as? String ?? ""
                let blocks = p["content"] as? [[String: Any]] ?? []
                // Codex 会把 AGENTS.md、环境信息等当成"用户消息"塞进会话，这些块都以 < 或 # AGENTS.md 开头，跳过
                let parts = blocks.compactMap { $0["text"] as? String }
                    .filter { !$0.hasPrefix("<") && !$0.hasPrefix("# AGENTS.md instructions") }
                var text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if role == "user" {
                    if text.hasPrefix(orangeMarker), let r = text.range(of: "\n\n") { text = String(text[r.upperBound...]) }
                    let images = blocks.filter { $0["type"] as? String == "input_image" }.compactMap { $0["image_url"] as? String }.filter { $0.hasPrefix("data:") }
                    if text.isEmpty && images.isEmpty { continue }
                    if open { events.append(["type": "end"]) }
                    events.append(["type": "me", "text": text, "images": images])
                    events.append(["type": "start"])
                    open = true
                } else if role == "assistant", !text.isEmpty {
                    events.append(["type": "text", "text": text])
                }
            } else if t == "custom_tool_call" || t == "function_call" {
                let name = p["name"] as? String ?? "tool"
                let isShell = ["exec", "exec_command", "shell", "local_shell"].contains(name)
                events.append(["type": "tool", "name": isShell ? "Bash" : name, "input": ["command": codexToolSummary(p)]])
            }
        }
        if open { events.append(["type": "end"]) }
        return events
    }

    // 任务发的事件：记进任务自己的 events，只有界面正在看它时才推给界面
    func jemit(_ job: Job, _ ev: [String: Any]) {
        job.events.append(ev)
        if viewed === job { emit(ev) }
    }

    func consume(_ job: Job, _ data: Data) {
        job.buffer.append(data)
        while let nl = job.buffer.firstIndex(of: 0x0A) {
            let line = job.buffer.subdata(in: job.buffer.startIndex..<nl)
            job.buffer.removeSubrange(job.buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if job.backend == "codex" { handleCodex(job, obj) } else { handle(job, obj) }
            }
        }
    }

    // codex exec --json 的事件：thread.started / turn.started / item.started|completed / turn.completed|failed
    func handleCodex(_ job: Job, _ ev: [String: Any]) {
        let type = ev["type"] as? String ?? ""
        switch type {
        case "thread.started":
            if let id = ev["thread_id"] as? String {
                upsertConvo(newId: id, oldId: job.sessionId, title: job.title, backend: job.backend)
                job.sessionId = id; job.title = nil
                if viewed === job { state["sessionId"] = id }
                saveState(state)
                emitHistory()
            }
        case "item.started", "item.completed":
            let item = ev["item"] as? [String: Any] ?? [:]
            let it = item["type"] as? String ?? ""
            let done = type == "item.completed"
            switch it {
            case "agent_message":
                if done, let t = item["text"] as? String, !t.isEmpty { jemit(job, ["type": "text", "text": t]) }
            case "command_execution":
                if !done {
                    var c = item["command"] as? String ?? ""
                    // 去掉外面包的 /bin/bash -lc '...'
                    if let r = c.range(of: "-lc ") { c = String(c[r.upperBound...]) }
                    if c.count >= 2, let f = c.first, (f == "'" || f == "\""), c.last == f { c = String(c.dropFirst().dropLast()) }
                    jemit(job, ["type": "tool", "name": "Bash", "input": ["command": c]])
                }
            case "file_change":
                if done {
                    let path = (item["changes"] as? [[String: Any]])?.first?["path"] as? String ?? ""
                    jemit(job, ["type": "tool", "name": "Edit", "input": ["file_path": path]])
                }
            case "mcp_tool_call":
                if !done {
                    let s = item["server"] as? String ?? "mcp", t = item["tool"] as? String ?? ""
                    jemit(job, ["type": "tool", "name": "mcp__\(s)__\(t)", "input": item["arguments"] ?? [:]])
                }
            case "web_search":
                if !done { jemit(job, ["type": "tool", "name": "WebSearch", "input": ["query": item["query"] as? String ?? ""]]) }
            case "error":
                if done { jemit(job, ["type": "error", "text": item["message"] as? String ?? "Codex 出错了"]) }
            case "reasoning", "todo_list", "": break
            default:
                if done { jemit(job, ["type": "tool", "name": it, "input": [:]]) }
            }
        case "turn.failed":
            let m = (ev["error"] as? [String: Any])?["message"] as? String
            jemit(job, ["type": "error", "text": m ?? "Codex 这一轮没完成。"])
        case "turn.completed":
            emitHistory()
        default: break
        }
    }

    func handle(_ job: Job, _ ev: [String: Any]) {
        let type = ev["type"] as? String ?? ""
        if type == "system", ev["subtype"] as? String == "init", let m = ev["model"] as? String, !m.isEmpty, m != lastClaudeModel {
            lastClaudeModel = m
            emitModels()
        }
        if let s = ev["session_id"] as? String, type == "system" || type == "result" {
            upsertConvo(newId: s, oldId: job.sessionId, title: job.title, backend: job.backend)
            job.sessionId = s; job.title = nil
            if viewed === job { state["sessionId"] = s }
            saveState(state)
            emitHistory()
        }
        if type == "assistant", let msg = ev["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks {
                if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty {
                    jemit(job, ["type": "text", "text": t])
                }
                if b["type"] as? String == "tool_use", let name = b["name"] as? String {
                    jemit(job, ["type": "tool", "name": name, "input": b["input"] ?? [:]])
                }
            }
        }
        if type == "result" {
            if ev["is_error"] as? Bool == true {
                jemit(job, ["type": "error", "text": ev["result"] as? String ?? "出错了"])
            }
            if let denials = ev["permission_denials"] as? [[String: Any]], !denials.isEmpty {
                let names = Set(denials.compactMap { $0["tool_name"] as? String }).sorted().joined(separator: "、")
                jemit(job, ["type": "error", "text": "这些工具没被允许用：\(names)。要放开就加进 config.json 的 allowedTools，然后重开橙子。"])
            }
        }
    }
}

// ---------- 知识库 ----------
// 位置：<工作目录>/shared/knowledge/。每条资料是一个带 frontmatter 的 .md；新收的先进 _inbox（待归类），
// 用户确认后移到「板块/子类」文件夹。文件和截图放 _assets。整理（读网页、读 PDF、识别截图、摘要、打标签）交给一次性的 claude -p 任务
let kbDefaultDirsZh = ["工作/项目", "工作/调研", "学习/笔记", "学习/课程", "_inbox", "_assets"]
let kbDefaultDirsEn = ["Work/Projects", "Work/Research", "Learning/Notes", "Learning/Courses", "_inbox", "_assets"]
let kbSubOrder = ["项目", "调研", "笔记", "课程", "Projects", "Research", "Notes", "Courses"]
let kbFields = ["title", "type", "source", "url", "origin", "asset", "images", "tags", "summary", "section", "status", "created"]
let kbReadme = """
# 知识库

橙子的「知识库」tab 管理这个文件夹。Claude、Codex、橙子读的是同一份。

## 结构

- `工作/项目`、`工作/调研`：工作相关的资料
- `学习/笔记`、`学习/课程`：学习相关的资料
- `_inbox/`：刚收进来、还没归类的资料（status: raw 是还没整理，pending 是等用户确认）
- `_assets/`：原始 PDF、Word、截图
- 板块可以在橙子里新建，也就是在这里新建文件夹

## 每条资料

一个 `.md`，顶部是 frontmatter（title、type: file/link/note、source、url、tags、summary、section、status、created），下面是正文（网页全文、文件提取的文字、笔记原文、截图里的文字）。

`url` 是这条资料的源文件链接：网页是原网址，flomo 是笔记链接，PDF、Word、截图是 file:// 链接（点了用默认程序打开原文件），纯文字笔记是这个 .md 自己。

## 怎么用

回答用户的问题时，如果可能和这里存的资料有关，先在这个文件夹里搜相关资料（先看 summary 和 tags，再读正文），回答按「先给总结 → 再给支持性证据 → 最后列来源」的结构：先用 2 到 4 句话直接回答；再分点列出资料里的关键内容、数据或案例，每点标明来自哪条资料；最后单独一节列出用到的资料，每条写成 Markdown 超链接 `[标题](url)`，url 原样复制资料 frontmatter 里的 url 字段，不要改写，方便点进去看源文件。没找到就直说。
"""

extension Controller {
    var kbDir: String { config.workdir + "/shared/knowledge" }

    func kbEnsure() {
        let fm = FileManager.default
        // 只在知识库还是空的时建默认文件夹，免得用户删掉、改名、合并过的又被建回来
        let fresh = ((try? fm.contentsOfDirectory(atPath: kbDir)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && $0 != "README.md" }.isEmpty
        for d in (lang == "en" ? kbDefaultDirsEn : kbDefaultDirsZh) where (fresh || d.hasPrefix("_")) && !fm.fileExists(atPath: kbDir + "/" + d) {
            try? fm.createDirectory(atPath: kbDir + "/" + d, withIntermediateDirectories: true)
        }
        if (try? String(contentsOfFile: kbDir + "/README.md", encoding: .utf8))?.contains("先给总结") != true { try? kbReadme.write(toFile: kbDir + "/README.md", atomically: true, encoding: .utf8) }
        kbBackfillUrls()
        // 让 Claude / Codex 知道有这个知识库：在共用的指令文件里补一小段（只补一次）
        let agents = config.workdir + "/AGENTS.md"
        let oldA = "引用时说明出处，并把每条出处写成 Markdown 链接 `[标题](url)`（url 取资料 frontmatter 里的 url 字段，原样复制），方便用户点开看源文件。"
        let newA = "回答按「先给总结 → 再给支持性证据 → 最后列来源」的结构：先 2 到 4 句话直接回答；再分点列出资料里的关键内容、数据或案例，每点标明来自哪条资料；最后单独一节列出用到的资料，每条写成 Markdown 超链接 `[标题](url)`（url 取资料 frontmatter 里的 url 字段，原样复制），方便用户点开看源文件。没找到就直说。"
        if var t = try? String(contentsOfFile: agents, encoding: .utf8), t.contains(oldA) {
            t = t.replacingOccurrences(of: oldA, with: newA)
            try? t.write(toFile: agents, atomically: true, encoding: .utf8)
        }
        if let t = try? String(contentsOfFile: agents, encoding: .utf8), !t.contains("同步进知识库"), let h = FileHandle(forWritingAtPath: agents) {
            h.seekToEndOfFile()
            h.write(Data("""


            ## 把外部资料同步进知识库

            用户说「把 XX（flomo、Notion、Obsidian、飞书……）的内容同步进知识库」时：
            - 只用对应连接器里读取类的工具（搜索、读取、列表），绝不调用创建、修改、发送、删除类的工具。
            - 先读 `shared/knowledge/_sources/<来源>.json`（没有就当作 `{"ids":[]}`）里已处理的条目 id；按时间从新到旧取，首次最多 100 条，之后最多 50 条，跳过已处理的。只导入和这些主题有关的：\(config.kbTopics)；无关的日常记录不导入，但 id 也记为已处理。
            - 每条在 `shared/knowledge/_inbox/` 新建 `<来源>-<条目id>.md`，frontmatter：title（30 字以内）、type: note、source、url（原文链接，取不到留空）、origin、tags、summary（一句话）、section（从知识库现有板块里选，都不合适填「待定」）、status: pending、created（YYYY-MM-DD）；正文是原文。最后把处理过的 id 写回 `_sources/<来源>.json`，用一句话汇报导入了几条、跳过了几条。
            - Obsidian：运行 `python3 -I \(appDir)/obsidian_sync.py \(kbDir) <config.json 里的 obsidianVault>`。飞书文件夹：运行 `python3 -I \(appDir)/feishu_sync.py \(kbDir)`（需要先配好 feishu_folders.json）。这两个直接读文件或调命令行，不用逐条处理。

            """.utf8))
            h.closeFile()
        }
        if let t = try? String(contentsOfFile: agents, encoding: .utf8), !t.contains("shared/knowledge"),
           let h = FileHandle(forWritingAtPath: agents) {
            h.seekToEndOfFile()
            h.write(Data("\n\n## 知识库\n\n用户收集的资料都在 `shared/knowledge/`（结构和用法见里面的 README.md）。问题可能和这些资料有关时，先去那里搜，引用时说明出处。\n".utf8))
            h.closeFile()
        }
    }

    func kbParse(_ raw: String) -> (meta: [String: String], body: String) {
        var meta: [String: String] = [:]
        guard raw.hasPrefix("---\n") else { return (meta, raw) }
        let after = raw.dropFirst(4)
        guard let end = after.range(of: "\n---") else { return (meta, raw) }
        for line in after[..<end.lowerBound].split(separator: "\n") {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            meta[k] = v
        }
        var body = String(after[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (meta, body)
    }

    func kbWrite(_ path: String, _ meta: [String: String], _ body: String) {
        var lines = ["---"]
        let keys = kbFields + meta.keys.filter { !kbFields.contains($0) }.sorted()
        for k in keys { if let v = meta[k], !v.isEmpty { lines.append("\(k): \(v.replacingOccurrences(of: "\n", with: " "))") } }
        lines.append("---")
        try? (lines.joined(separator: "\n") + "\n\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
    }

    func kbFileURL(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }

    // 每条资料都要有 url（源文件链接）：flomo → 笔记页，网页 → 原网址，文件和截图 → file://，纯文字 → 这个 .md 自己
    func kbDefaultURL(_ meta: [String: String], path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if name.hasPrefix("flomo-") { return "https://v.flomoapp.com/mine/?memo_id=" + name.dropFirst(6) }
        if let s = meta["source"], s.hasPrefix("http") { return s }
        if let a = meta["asset"], a.hasPrefix("_assets/"), !a.contains("..") { return kbFileURL(kbDir + "/" + a) }
        if let i = (meta["images"] ?? "").components(separatedBy: ",").first, i.hasPrefix("_assets/"), !i.contains("..") { return kbFileURL(kbDir + "/" + i) }
        return kbFileURL(path)
    }

    func kbBackfillUrls() {
        guard let en = FileManager.default.enumerator(atPath: kbDir) else { return }
        for case let rel as String in en {
            if rel == "_assets" { en.skipDescendants(); continue }
            guard rel.hasSuffix(".md"), rel != "README.md", !rel.hasPrefix(".") else { continue }
            let full = kbDir + "/" + rel
            guard let raw = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            var (m, body) = kbParse(raw)
            guard !m.isEmpty, (m["url"] ?? "").isEmpty else { continue }
            let when = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate]
            m["url"] = kbDefaultURL(m, path: full)
            kbWrite(full, m, body); body = ""
            if let w = when { try? FileManager.default.setAttributes([.modificationDate: w], ofItemAtPath: full) }
        }
    }

    func kbScan() -> (sections: [[String: Any]], items: [[String: Any]]) {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
        let lay = kbLayout()
        let topOrder = lay["top"] as? [String] ?? []
        let subOrders = lay["subs"] as? [String: [String]] ?? [:]
        func rank(_ s: String, _ l: [String]) -> Int { l.firstIndex(of: s) ?? (1000 + (kbSubOrder.firstIndex(of: s) ?? 99)) }
        var sections: [[String: Any]] = []
        let tops = ((try? fm.contentsOfDirectory(atPath: kbDir)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isDir(kbDir + "/" + $0) }
            .sorted { (rank($0, topOrder), $0) < (rank($1, topOrder), $1) }
        for t in tops {
            let subs = ((try? fm.contentsOfDirectory(atPath: kbDir + "/" + t)) ?? []).filter { !$0.hasPrefix(".") && isDir(kbDir + "/" + t + "/" + $0) }
                .sorted { (rank($0, subOrders[t] ?? []), $0) < (rank($1, subOrders[t] ?? []), $1) }
            sections.append(["name": t, "subs": subs])
        }
        var items: [[String: Any]] = []
        if let en = fm.enumerator(atPath: kbDir) {
            for case let rel as String in en {
                if rel == "_assets" { en.skipDescendants(); continue }
                guard rel.hasSuffix(".md"), rel != "README.md", !rel.hasPrefix(".") else { continue }
                let full = kbDir + "/" + rel
                guard let raw = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                let m = kbParse(raw).meta
                let inbox = rel.hasPrefix("_inbox/")
                let ts = ((try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let tags = (m["tags"] ?? "").components(separatedBy: CharacterSet(charactersIn: ",，、")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                items.append(["id": rel,
                              "title": m["title"] ?? ((rel as NSString).lastPathComponent as NSString).deletingPathExtension,
                              "type": m["type"] ?? "note", "source": m["source"] ?? "", "tags": tags, "summary": m["summary"] ?? "",
                              "section": inbox ? (m["section"] ?? "待定") : (rel as NSString).deletingLastPathComponent,
                              "status": inbox ? (m["status"] ?? "raw") : "ok",
                              "created": m["created"] ?? "", "url": m["url"] ?? "", "ts": ts, "canOpen": m["asset"] != nil || (m["url"] ?? "").hasPrefix("http") || (m["source"] ?? "").hasPrefix("http")])
            }
        }
        items.sort { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
        return (sections, items)
    }

    func kbEmit() { let s = kbScan(); emit(["type": "kb", "sections": s.sections, "items": s.items]) }
    func kbMsg(_ t: String) { emit(["type": "kb_msg", "text": t]) }

    // 一次性的 claude -p 任务：同一时间只跑一个，跑完刷新列表
    // lean：整理资料用不上连接器、skill 和用户 hooks，不加载它们，每次启动能省好几秒
    func kbRun(label: String, prompt: String, model: String = "claude-sonnet-5-5", lean: Bool = false, extraTools: [String] = [], capture: ((String) -> Void)? = nil, done: @escaping () -> Void) {
        // 知识库的整理任务跟着当前选的后端走：Claude 用 claude -p，Codex 用 codex exec（最后一条回复写进临时文件）
        let useCodex = backend == "codex"
        guard let bin = useCodex ? findCodex(config) : findClaude(config) else { kbMsg(useCodex ? "找不到 Codex 程序，整理没法进行。" : "找不到 claude 程序，整理没法进行。"); return }
        var args: [String]
        let codexOut = NSTemporaryDirectory() + "orange-kb-\(UUID().uuidString).txt"
        if useCodex {
            args = ["exec", "--skip-git-repo-check", "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"\(config.codexSandbox)\""]
            if config.codexSandbox == "workspace-write" && config.codexNetwork { args += ["-c", "sandbox_workspace_write.network_access=true"] }
            args += ["-o", codexOut, "-"]
        } else {
            args = ["-p", "--output-format", "text", "--permission-mode", config.permissionMode, "--no-session-persistence", "--model", model]
            if lean { args += ["--strict-mcp-config", "--disable-slash-commands", "--setting-sources", ""] }
            let tools = config.allowedTools + extraTools
            if !tools.isEmpty { args += ["--allowedTools"] + tools }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if env["HTTPS_PROXY"] == nil, let proxy = systemProxy() {
            env["HTTPS_PROXY"] = proxy; env["HTTP_PROXY"] = proxy
            env["NO_PROXY"] = env["NO_PROXY"] ?? "localhost,127.0.0.1,::1,.local"
        }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = err
        let outBuf = OutBuf()
        out.fileHandleForReading.readabilityHandler = { outBuf.add($0.availableData) }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            outBuf.add(out.fileHandleForReading.readDataToEndOfFile())
            var text = outBuf.text
            if useCodex { text = (try? String(contentsOfFile: codexOut, encoding: .utf8)) ?? ""; try? FileManager.default.removeItem(atPath: codexOut) }
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.kbJob = nil
                self.emit(["type": "kb_busy", "value": false])
                if proc.terminationStatus != 0 && !errText.isEmpty && !(useCodex && !text.isEmpty) { self.kbMsg("整理出错：" + String(errText.suffix(200))) }
                else if let c = capture { c(text) }
                else { self.kbMsg(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120))) }
                self.kbEmit()
                done()
            }
        }
        do {
            try p.run()
            kbJob = p
            emit(["type": "kb_busy", "value": true, "label": label])
            DispatchQueue.global().async {
                inp.fileHandleForWriting.write(Data(prompt.utf8))
                try? inp.fileHandleForWriting.close()
            }
        } catch { kbMsg("启动整理失败：\(error.localizedDescription)") }
    }

    // 飞书同步：不用 AI，直接跑 feishu_sync.py（调 lark-cli），同一时间只跑一个任务
    func kbFeishu(auto: Bool) {
        guard FileManager.default.fileExists(atPath: kbFeishuPath) else { if !auto { kbMsg("还没配置要同步的飞书文件夹：把 feishu_folders.example.json 复制成 feishu_folders.json，填上文件夹 token。") }; return }
        state["kb_feishu_last"] = Date().timeIntervalSince1970
        saveState(state)
        kbScript("feishu_sync.py", args: [kbDir], label: "正在同步飞书文件夹", name: "飞书", auto: auto)
    }

    // 不用 AI 的同步：直接跑 appDir 里的 python 脚本，同一时间只跑一个任务
    func kbScript(_ file: String, args: [String], label: String, name: String, auto: Bool) {
        guard kbJob == nil else { if !auto { kbMsg("上一个任务还在跑，跑完再同步\(name)。") }; return }
        let script = appDir + "/" + file
        guard FileManager.default.fileExists(atPath: script) else { if !auto { kbMsg("找不到 \(file)。") }; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if env["HTTPS_PROXY"] == nil, let proxy = systemProxy() {
            env["HTTPS_PROXY"] = proxy; env["HTTP_PROXY"] = proxy
            env["NO_PROXY"] = env["NO_PROXY"] ?? "localhost,127.0.0.1,::1,.local"
        }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let outBuf = OutBuf()
        out.fileHandleForReading.readabilityHandler = { outBuf.add($0.availableData) }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            outBuf.add(out.fileHandleForReading.readDataToEndOfFile())
            let text = outBuf.text
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.kbJob = nil
                self.emit(["type": "kb_busy", "value": false])
                if proc.terminationStatus != 0 { self.kbMsg("\(name)同步出错：" + String(errText.suffix(200))) }
                else { self.kbMsg(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120))) }
                self.kbEmit()
                self.kbAutoSync()
            }
        }
        do {
            try p.run()
            kbJob = p
            emit(["type": "kb_busy", "value": true, "label": label])
        } catch { kbMsg("启动\(name)同步失败：\(error.localizedDescription)") }
    }

    // 打开知识库时：flomo 和飞书各自超过 6 小时没同步就自动同步一次，一个跑完接着下一个
    func kbAutoSync() {
        guard kbJob == nil else { return }
        let now = Date().timeIntervalSince1970
        if config.flomoSync, now - (state["kb_flomo_last"] as? Double ?? 0) > 6 * 3600 { kbFlomo(auto: true) }
        else if FileManager.default.fileExists(atPath: kbFeishuPath), now - (state["kb_feishu_last"] as? Double ?? 0) > 6 * 3600 { kbFeishu(auto: true) }
    }

    var kbSectionsText: String {
        kbScan().sections.flatMap { s in (s["subs"] as? [String] ?? []).map { "\(s["name"] as? String ?? "")/\($0)" } }.joined(separator: "、")
    }

    func kbOrganize() {
        guard kbJob == nil else { kbRerun = true; return }
        let n = kbScan().items.filter { $0["status"] as? String == "raw" }.count
        guard n > 0 else { return }
        let prompt = """
        你是橙子的知识库整理员。知识库在 \(kbDir)。读取 _inbox/ 里 frontmatter 中 status: raw 的每个 .md 条目，逐个处理：
        1. 补全正文。type: link：如果正文已经有内容（橙子已经读好了），不用再抓取；正文为空才用 WebFetch 抓取 source 网址，把正文要点（清理后，保留原文的结构和关键数据，最多约 6000 字）写进该文件正文，抓取失败就在正文写「抓取失败」并保留链接。type: file：用 Read 读 asset 字段指向的文件（路径相对于知识库目录；PDF 用 pages 参数分段读，最多前 20 页；Word 用 `textutil -convert txt -stdout <路径>` 提取），把提取的文字（最多约 6000 字）写进正文。type: note：正文已有文字；如果有 images 字段（逗号分隔的相对路径），用 Read 逐张读图，把图里的文字原样转写，追加到正文末尾的「## 图片文字」小节。
        2. 补全 frontmatter：title（如果现在的 title 不是网址，说明已经是文档或网页的真实标题，保持不变；只有 title 还是网址、或者是 note 时，才用 30 字以内概括内容）、summary（一句话，60 字以内）、tags（2 到 4 个短词，逗号分隔）、section（从现有板块里选最合适的，格式「板块/子类」，现有：\(kbSectionsText)；实在都不合适就填「待定」）。
        3. 把 status 改成 pending。
        只改这些条目的内容，不要移动或删除任何文件，不要碰 status 不是 raw 的条目，保留 frontmatter 里原有的 type、source、url、asset、images、created 等字段，尤其不要改 url。全部处理完后用一句话说处理了几条。
        """
        kbRun(label: "正在整理 \(n) 条新资料", prompt: prompt, model: "claude-haiku-5-5", lean: true) { [weak self] in
            if let s = self, s.kbRerun { s.kbRerun = false; s.kbOrganize() }
        }
    }

    func kbFlomo(auto: Bool) {
        guard kbJob == nil else { if !auto { kbMsg("上一个整理任务还在跑，跑完再同步 flomo。") }; return }
        state["kb_flomo_last"] = Date().timeIntervalSince1970
        saveState(state)
        let prompt = """
        把 flomo 笔记同步进知识库 \(kbDir)。先读 \(kbDir)/_flomo_synced.json（没有就当作 {"ids":[]}）里已同步的 memo id。用 flomo 的 memo_search 工具按时间从新到旧取笔记（首次最多取最近 100 条，之后每次最多 50 条），跳过已同步的 id。
        每条要导入的笔记，在 \(kbDir)/_inbox/ 新建 flomo-<memo id>.md，frontmatter 字段：title（30 字以内概括）、type: note、source: flomo、url: https://v.flomoapp.com/mine/?memo_id=<memo id>、origin: flomo、tags（flomo 里的标签去掉 #，再补 1 到 2 个）、summary（一句话）、section（从现有板块里选：\(kbSectionsText)；都不合适填「待定」）、status: pending、created（笔记创建日期 YYYY-MM-DD）；正文是笔记原文。
        只导入和这些主题有关的笔记：\(config.kbTopics)。无关的日常记录（待办、购物、心情流水等）不要导入，但它们的 id 也要记为已处理。最后把所有处理过的 id 写回 _flomo_synced.json（格式 {"ids":["…"]}）。用一句话汇报导入了几条、跳过了几条。
        """
        kbRun(label: "正在同步 flomo", prompt: prompt) { [weak self] in
            if let s = self, s.kbRerun { s.kbRerun = false; s.kbOrganize() }
            self?.kbAutoSync()
        }
    }

    func kbSafeName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "未命名" : String(t.prefix(80))
    }

    // 板块路径只允许「名字」或「名字/名字」，不能出现 ..、不能以 _ 或 . 开头
    func kbValidSection(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix("_") && !$0.hasPrefix(".") && $0 != ".." && !$0.contains(":") }
    }

    func kbAdd(_ msg: [String: Any]) {
        kbEnsure()
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        let today = d.string(from: Date())
        func entry(_ meta: [String: String], _ body: String) {
            var m = meta; m["status"] = "raw"; m["created"] = today
            kbWrite("\(kbDir)/_inbox/\(stamp)-\(UUID().uuidString.prefix(4)).md", m, body)
        }
        var linkJobs: [(String, String)] = []
        var imageRels: [String] = []
        for (i, url) in (msg["images"] as? [String] ?? []).enumerated() {
            guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { continue }
            let ext = url.hasPrefix("data:image/jpeg") ? "jpg" : "png"
            let rel = "_assets/\(stamp)-\(i).\(ext)"
            try? data.write(to: URL(fileURLWithPath: kbDir + "/" + rel))
            imageRels.append(rel)
        }
        let text = (msg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if msg["kind"] as? String == "file" {
            guard let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64) else { kbMsg("这个文件没读进来。"); return }
            let name = kbSafeName(msg["name"] as? String ?? "文件")
            let rel = "_assets/\(stamp)-\(name)"
            do { try data.write(to: URL(fileURLWithPath: kbDir + "/" + rel)) } catch { kbMsg("存文件失败：\(error.localizedDescription)"); return }
            entry(["title": (name as NSString).deletingPathExtension, "type": "file", "source": name, "asset": rel, "url": kbFileURL(kbDir + "/" + rel)], "")
        } else {
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty && lines.allSatisfy({ $0.hasPrefix("http://") || $0.hasPrefix("https://") }) && imageRels.isEmpty {
                for u in lines {
                    let path = "\(kbDir)/_inbox/\(stamp)-\(UUID().uuidString.prefix(4)).md"
                    kbWrite(path, ["title": u, "type": "link", "source": u, "url": u, "status": "raw", "created": today], "")
                    linkJobs.append((path, u))
                }
            } else {
                entry(["title": String(text.prefix(30)).isEmpty ? "截图笔记" : String(text.prefix(30)), "type": "note",
                       "source": msg["from"] as? String ?? "手动", "images": imageRels.joined(separator: ",")], text)
            }
        }
        kbEmit()
        if linkJobs.isEmpty { kbOrganize(); return }
        // 链接先花几秒读出真实标题（飞书文档用 lark-cli 读标题和正文），列表里立刻就是文件名，再交给整理
        DispatchQueue.global().async { [weak self] in
            let res = linkJobs.map { ($0.0, self?.kbLinkInfo($0.1) ?? (nil, nil)) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (path, info) in res {
                    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    var (m, body) = self.kbParse(raw)
                    if let t = info.0, !t.isEmpty { m["title"] = t }
                    if let b = info.1, !b.isEmpty { body = b }
                    self.kbWrite(path, m, body)
                }
                self.kbEmit()
                self.kbOrganize()
            }
        }
    }

    // 读链接的真实标题：飞书文档用 lark-cli（网页要登录，直接抓只会拿到登录页），其他网页读 <title>
    func kbLinkInfo(_ urlStr: String) -> (String?, String?) {
        guard let url = URL(string: urlStr), let host = url.host else { return (nil, nil) }
        if ["feishu.cn", "larksuite.com", "larkoffice.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            guard url.pathComponents.contains(where: { ["docx", "wiki"].contains($0) }), let tok = url.pathComponents.last, safeToken(tok) == tok else { return (nil, nil) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["lark-cli", "docs", "+fetch", "--as", "user", "--doc", tok, "--doc-format", "markdown"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            let buf = OutBuf()
            out.fileHandleForReading.readabilityHandler = { buf.add($0.availableData) }
            do { try p.run() } catch { return (nil, nil) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            p.waitUntilExit(); killer.cancel()
            out.fileHandleForReading.readabilityHandler = nil
            buf.add(out.fileHandleForReading.readDataToEndOfFile())
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(buf.text.utf8))) as? [String: Any],
                  let content = ((obj["data"] as? [String: Any])?["document"] as? [String: Any])?["content"] as? String else { return (nil, nil) }
            var title: String?
            var body = content
            if let a = content.range(of: "<title>"), let b = content.range(of: "</title>"), a.upperBound <= b.lowerBound {
                title = String(content[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                body = String(content[b.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (title, String(body.prefix(20000)))
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        var html = ""
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d = d { html = String(data: d.prefix(200_000), encoding: .utf8) ?? String(data: d.prefix(200_000), encoding: .isoLatin1) ?? "" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) else { return (nil, nil) }
        var t = String(html[r])
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (t.isEmpty ? nil : String(t.prefix(100)), nil)
    }

    func kbMove(_ id: String, _ section: String) {
        guard kbValidSection(section) else { kbMsg("先选一个板块。"); return }
        let src = kbDir + "/" + id
        guard id.hasSuffix(".md"), !id.contains(".."), let raw = try? String(contentsOfFile: src, encoding: .utf8) else { return }
        var (meta, body) = kbParse(raw)
        let dir = kbDir + "/" + section
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var dest = dir + "/" + (id as NSString).lastPathComponent
        var n = 1
        while FileManager.default.fileExists(atPath: dest) && dest != src {
            dest = dir + "/" + ((id as NSString).lastPathComponent as NSString).deletingPathExtension + "-\(n).md"; n += 1
        }
        meta["section"] = section; meta["status"] = "ok"
        if (meta["url"] ?? "").isEmpty || (meta["url"] ?? "").hasSuffix(".md") { meta["url"] = kbDefaultURL(meta, path: dest) }
        kbWrite(dest, meta, body)
        if dest != src { try? FileManager.default.removeItem(atPath: src) }
        body = ""
        kbEmit()
    }

    // ---------- 侧边栏：文件夹整理（拖拽、改名、合并、删除、撤销） ----------
    var kbLayoutPath: String { kbDir + "/_layout.json" }
    func kbLayout() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: kbLayoutPath) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    func kbSaveLayout(top: [String], subs: [String: [String]]) {
        if let d = try? JSONSerialization.data(withJSONObject: ["top": top, "subs": subs], options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: kbLayoutPath)) }
    }
    func kbOrderNow() -> (top: [String], subs: [String: [String]]) {
        let s = kbScan().sections
        var subs: [String: [String]] = [:]
        for x in s { subs[x["name"] as? String ?? ""] = x["subs"] as? [String] ?? [] }
        return (s.compactMap { $0["name"] as? String }, subs)
    }
    var kbFeishuPath: String { appDir + "/feishu_folders.json" }
    // 飞书同步按「板块/子类」路径落盘；文件夹挪了或改名了，映射跟着改，下次同步才不会建回旧的
    func kbRemapFeishu(_ old: String, _ new: String) {
        guard let d = FileManager.default.contents(atPath: kbFeishuPath), var arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        var changed = false
        for i in arr.indices {
            guard let sec = arr[i]["section"] as? String else { continue }
            if sec == old { arr[i]["section"] = new; changed = true }
            else if sec.hasPrefix(old + "/") { arr[i]["section"] = new + String(sec.dropFirst(old.count)); changed = true }
        }
        if changed, let out = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) { try? out.write(to: URL(fileURLWithPath: kbFeishuPath)) }
    }
    func kbIsDir(_ rel: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: kbDir + "/" + rel, isDirectory: &d) && d.boolValue }
    func kbUniqueName(_ dirRel: String, _ name: String) -> String {
        var dest = name, n = 1
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: kbDir + "/" + dirRel + "/" + dest) { dest = base + "-\(n)" + (ext.isEmpty ? "" : "." + ext); n += 1 }
        return dest
    }
    // 把一个文件夹里的内容挪到另一个文件夹（重名自动加后缀），返回挪动记录，供撤销
    func kbMoveContents(_ from: String, _ to: String, into moves: inout [[String]]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: kbDir + "/" + to, withIntermediateDirectories: true)
        for n in ((try? fm.contentsOfDirectory(atPath: kbDir + "/" + from)) ?? []) where !n.hasPrefix(".") {
            let dn = kbUniqueName(to, n)
            if (try? fm.moveItem(atPath: kbDir + "/" + from + "/" + n, toPath: kbDir + "/" + to + "/" + dn)) != nil { moves.append([from + "/" + n, to + "/" + dn]) }
        }
    }
    func kbRemoveEmptyDir(_ rel: String) {
        let p = kbDir + "/" + rel
        for h in ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []) where h.hasPrefix(".") { try? FileManager.default.removeItem(atPath: p + "/" + h) }
        try? FileManager.default.removeItem(atPath: p)   // 非空会失败，不会误删
    }
    func kbDone(_ text: String, moves: [[String]], made: [String], removed: [String], layout: [String: Any], feishu: Data?) {
        kbUndo = ["moves": moves, "made": made, "removed": removed, "layout": layout, "feishu": feishu as Any]
        kbEmit()
        emit(["type": "kb_toast", "text": text, "undo": true])
    }
    func kbFolderOp(_ type: String, _ msg: [String: Any]) {
        let fm = FileManager.default
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let a = clean(msg["path"] as? String ?? ""), layoutBefore = kbLayout(), feishuBefore = fm.contents(atPath: kbFeishuPath)
        var moves: [[String]] = [], made: [String] = [], removed: [String] = []
        guard kbValidSection(a), kbIsDir(a) else { kbMsg("找不到这个文件夹。"); return }
        let aParts = a.split(separator: "/").map(String.init)
        let aName = aParts.last!, aParent = aParts.count == 2 ? aParts[0] : ""
        var order = kbOrderNow()
        func place(_ name: String, parent: String, before: String?) {
            var list = parent.isEmpty ? order.top : (order.subs[parent] ?? [])
            list.removeAll { $0 == name }
            if let b = before, let i = list.firstIndex(of: b) { list.insert(name, at: i) } else { list.append(name) }
            if parent.isEmpty { order.top = list } else { order.subs[parent] = list }
        }
        switch type {
        case "kb_fmove":
            let parent = clean(msg["parent"] as? String ?? ""), before = msg["before"] as? String
            if !parent.isEmpty && (!kbValidSection(parent) || parent.contains("/") || !kbIsDir(parent)) { kbMsg("目标文件夹不对。"); return }
            if parent == a { return }
            let dest = parent.isEmpty ? aName : parent + "/" + aName
            if dest != a {
                if aParent.isEmpty, !((order.subs[aName] ?? []).isEmpty) { kbMsg("带子类的大标题不能放进别的文件夹，先把子类拖出来。"); return }
                if kbIsDir(dest) { kbMsg("「\(parent.isEmpty ? "最外层" : parent)」里已经有叫「\(aName)」的文件夹了，要合并请拖到它上面。"); return }
                if !parent.isEmpty { try? fm.createDirectory(atPath: kbDir + "/" + parent, withIntermediateDirectories: true) }
                guard (try? fm.moveItem(atPath: kbDir + "/" + a, toPath: kbDir + "/" + dest)) != nil else { kbMsg("没挪成功。"); return }
                moves.append([a, dest])
                if !aParent.isEmpty {
                    // 原大标题空了就收掉
                    let left = ((try? fm.contentsOfDirectory(atPath: kbDir + "/" + aParent)) ?? []).filter { !$0.hasPrefix(".") }
                    if left.isEmpty { kbRemoveEmptyDir(aParent); removed.append(aParent) }
                }
                kbRemapFeishu(a, dest)
            }
            order = kbOrderNow()
            place(aName, parent: parent, before: before)
            kbSaveLayout(top: order.top, subs: order.subs)
            kbDone(dest == a ? "顺序已调整" : "已把「\(aName)」" + (parent.isEmpty ? "移到最外层" : "放进「\(parent)」"), moves: moves, made: made, removed: removed, layout: layoutBefore, feishu: feishuBefore)
        case "kb_fmerge":
            let into = clean(msg["into"] as? String ?? "")
            guard kbValidSection(into), kbIsDir(into), into != a else { kbMsg("合并目标不对。"); return }
            if !((order.subs[a] ?? []).isEmpty) { kbMsg("带子类的大标题不能直接合并。"); return }
            kbMoveContents(a, into, into: &moves)
            kbRemoveEmptyDir(a); removed.append(a)
            if !aParent.isEmpty, ((try? fm.contentsOfDirectory(atPath: kbDir + "/" + aParent)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty { kbRemoveEmptyDir(aParent); removed.append(aParent) }
            kbRemapFeishu(a, into)
            order = kbOrderNow(); kbSaveLayout(top: order.top, subs: order.subs)
            kbDone("已把「\(aName)」合并到「\(into)」，\(moves.count) 项", moves: moves, made: made, removed: removed, layout: layoutBefore, feishu: feishuBefore)
        case "kb_frename":
            let name = kbSafeName(msg["name"] as? String ?? "")
            guard !name.isEmpty, kbValidSection(name), !name.contains("/") else { kbMsg("名字不能为空，也不能用 _ 或 . 开头。"); return }
            if name == aName { return }
            let dest = aParent.isEmpty ? name : aParent + "/" + name
            if kbIsDir(dest) { kbMsg("已经有叫「\(name)」的了。"); return }
            guard (try? fm.moveItem(atPath: kbDir + "/" + a, toPath: kbDir + "/" + dest)) != nil else { kbMsg("没改成功。"); return }
            moves.append([a, dest])
            var o = order
            if aParent.isEmpty {
                o.top = o.top.map { $0 == aName ? name : $0 }; if let v = o.subs.removeValue(forKey: aName) { o.subs[name] = v }
            } else { o.subs[aParent] = (o.subs[aParent] ?? []).map { $0 == aName ? name : $0 } }
            kbRemapFeishu(a, dest)
            kbSaveLayout(top: o.top, subs: o.subs)
            kbDone("已改名为「\(name)」", moves: moves, made: made, removed: removed, layout: layoutBefore, feishu: feishuBefore)
        case "kb_fdelete":
            // 不删文件：全部挪到「未分类」，文件夹本身移除
            let spare = "未分类"
            if a == spare { kbMsg("「未分类」留着装没处放的文件。"); return }
            if !kbIsDir(spare) { made.append(spare) }
            for sub in (order.subs[a] ?? []) { kbMoveContents(a + "/" + sub, spare, into: &moves); kbRemoveEmptyDir(a + "/" + sub); removed.append(a + "/" + sub) }
            kbMoveContents(a, spare, into: &moves)
            kbRemoveEmptyDir(a); removed.append(a)
            if !aParent.isEmpty, ((try? fm.contentsOfDirectory(atPath: kbDir + "/" + aParent)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty { kbRemoveEmptyDir(aParent); removed.append(aParent) }
            order = kbOrderNow(); kbSaveLayout(top: order.top, subs: order.subs)
            kbDone("已删除「\(aName)」，里面的 \(moves.count) 项挪到了「未分类」", moves: moves, made: made, removed: removed, layout: layoutBefore, feishu: feishuBefore)
        default: break
        }
    }
    func kbUndoLast() {
        guard let u = kbUndo else { return }
        kbUndo = nil
        let fm = FileManager.default
        for r in (u["removed"] as? [String] ?? []) { try? fm.createDirectory(atPath: kbDir + "/" + r, withIntermediateDirectories: true) }
        for m in (u["moves"] as? [[String]] ?? []).reversed() where m.count == 2 {
            try? fm.createDirectory(atPath: ((kbDir + "/" + m[0]) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.moveItem(atPath: kbDir + "/" + m[1], toPath: kbDir + "/" + m[0])
        }
        for r in (u["made"] as? [String] ?? []) { kbRemoveEmptyDir(r) }
        let lay = u["layout"] as? [String: Any] ?? [:]
        if lay.isEmpty { try? fm.removeItem(atPath: kbLayoutPath) }
        else { kbSaveLayout(top: lay["top"] as? [String] ?? [], subs: lay["subs"] as? [String: [String]] ?? [:]) }
        if let f = u["feishu"] as? Data { try? f.write(to: URL(fileURLWithPath: kbFeishuPath)) }
        kbEmit()
        emit(["type": "kb_toast", "text": "已撤销", "undo": false])
    }

    func kbHandle(_ type: String, _ msg: [String: Any]) {
        let id = msg["id"] as? String ?? ""
        switch type {
        case "kb_load":
            kbEnsure(); kbEmit(); kbOrganize()
            kbAutoSync()
        case "kb_fmove", "kb_fmerge", "kb_frename", "kb_fdelete": kbFolderOp(type, msg)
        case "kb_undo": kbUndoLast()
        case "kb_add": kbAdd(msg)
        case "kb_flomo": kbFlomo(auto: false)
        case "kb_move": kbMove(id, msg["section"] as? String ?? "")
        case "kb_delete":
            guard id.hasSuffix(".md"), !id.contains("..") else { return }
            let path = kbDir + "/" + id
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let m = kbParse(raw).meta
                for rel in ([m["asset"] ?? ""] + (m["images"] ?? "").components(separatedBy: ",")) where rel.hasPrefix("_assets/") && !rel.contains("..") {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: kbDir + "/" + rel), resultingItemURL: nil)
                }
            }
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            kbEmit()
        case "kb_open":
            guard id.hasSuffix(".md"), !id.contains(".."), let raw = try? String(contentsOfFile: kbDir + "/" + id, encoding: .utf8) else { return }
            let m = kbParse(raw).meta
            // 优先打开源文件：飞书文档、flomo 笔记、网页都有 http 的 url；PDF、Word 打开存下来的原文件；都没有才打开这条 .md
            if let u = m["url"], u.hasPrefix("http"), let url = URL(string: u) { NSWorkspace.shared.open(url) }
            else if let a = m["asset"], a.hasPrefix("_assets/"), !a.contains("..") { NSWorkspace.shared.open(URL(fileURLWithPath: kbDir + "/" + a)) }
            else if let s = m["source"], s.hasPrefix("http"), let u = URL(string: s) { NSWorkspace.shared.open(u) }
            else { NSWorkspace.shared.open(URL(fileURLWithPath: kbDir + "/" + id)) }
        case "kb_detail":
            guard id.hasSuffix(".md"), !id.contains(".."), let raw = try? String(contentsOfFile: kbDir + "/" + id, encoding: .utf8) else { return }
            let (m, body) = kbParse(raw)
            var imgs: [String] = []
            for rel in (m["images"] ?? "").components(separatedBy: ",") where rel.hasPrefix("_assets/") && !rel.contains("..") {
                if let data = FileManager.default.contents(atPath: kbDir + "/" + rel), data.count < 3_000_000 {
                    imgs.append("data:image/\(rel.hasSuffix("jpg") ? "jpeg" : "png");base64," + data.base64EncodedString())
                }
            }
            // 飞书导出的正文开头带一行 <title>…</title>，预览里不显示
            let shown = body.replacingOccurrences(of: #"^\s*<title>.*?</title>\s*"#, with: "", options: .regularExpression)
            emit(["type": "kb_detail", "id": id, "body": String(shown.prefix(4000)), "images": imgs])
        case "kb_section":
            let name = kbSafeName(msg["name"] as? String ?? "")
            let sub = (msg["sub"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let path = sub.isEmpty ? name : name + "/" + kbSafeName(sub)
            guard kbValidSection(path) else { kbMsg("名字不能用 _ 或 . 开头。"); return }
            try? FileManager.default.createDirectory(atPath: kbDir + "/" + path, withIntermediateDirectories: true)
            kbEmit()
        default: break
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return true
    }
}

// ⌥ 空格 全局唤起（Carbon 热键，不需要辅助功能权限）
func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { controller.toggle() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x4F524E47), id: 1),
                        GetApplicationEventTarget(), 0, &ref)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 最小菜单：没有它就没法 ⌘C / ⌘V / ⌘Q
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu(); appItem.submenu = appMenu
appMenu.addItem(withTitle: "隐藏橙子", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(withTitle: "退出橙子", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let winItem = NSMenuItem(); mainMenu.addItem(winItem)
let winMenu = NSMenu(title: "窗口"); winItem.submenu = winMenu
winMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
let controller = Controller()
registerHotKey()
app.activate(ignoringOtherApps: true)
app.run()
