#if os(macOS)
import SwiftUI
import AppKit

/// Readlet → Settings… (⌘,): General · Voice & Narration · Storage & Usage
struct SettingsView: View {
    // gateway + models
    @State var key = Settings.apiKey
    @State var base = Settings.baseURL
    @State var lang = Settings.targetLang
    @State var models: [String] = []
    @State var loading = false
    @State var status = ""
    @State var tModel = ModelConfig.translateModel
    @State var tStyle = ModelConfig.style("translate")
    @State var cModel = ModelConfig.chatModel
    @State var cStyle = ModelConfig.style("chat")
    @State var lookahead = Settings.lookahead
    @State var configExists = ConfigFile.exists
    @State var keyManaged = Settings.apiKeyManagedByFile
    @State var theme = AppTheme.current
    @ObservedObject var lc = LangCenter.shared
    @ObservedObject var gpt = ChatGPTAuth.shared
    @ObservedObject var updater = UpdateChecker.shared
    @ObservedObject var cloud = CloudSync.shared
    // narration + speech
    @State var narrStyle = Settings.narrationStyle
    @State var narrExtra = Settings.narrationExtraPrompt
    @State var ttsProvider = Narrator.shared.provider
    @State var sysVoice = Narrator.shared.systemVoice
    @State var tts = TTSFields.load(Narrator.shared.provider)
    @State var ttsModels: [String] = []
    // storage
    @State var usage: StorageManager.Usage?
    @State var cacheLimit = Settings.ttsCacheLimitGB
    @State var busy = ""
    @State var usageDays = 7
    @State var usageTick = 0
    @State var priceIn = Pricing.inputPerMTok
    @State var priceOut = Pricing.outputPerMTok
    @State var priceTTS = Pricing.ttsPerMChars
    @State var currency = Pricing.currency

    @State private var settingsWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab.tabItem { Label(L("通用"), systemImage: "gearshape") }
                voiceTab.tabItem { Label(L("语音与讲解"), systemImage: "waveform") }
                storageTab.tabItem { Label(L("存储与用量"), systemImage: "internaldrive") }
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 640, height: 680)
        .task { if models.isEmpty { await reload() } }
        .background(WindowFinder { settingsWindow = $0 })
        .onChange(of: ttsProvider) { old, new in
            tts.save(old)                         // keep what was typed for the previous provider
            tts = TTSFields.load(new)
            ttsModels = []
        }
    }

    // MARK: tabs

    var generalTab: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text(L("不确定怎么配？用向导一步步选好 AI 和语音。")).font(.callout)
                    Spacer()
                    Button(L("打开设置向导")) { OnboardingPanel.show() }
                    Link(L("配置说明"), destination: AppInfo.supportURL).font(.callout)
                }
            }
            Section(L("界面语言") + " / Interface Language") {
                Picker(L("界面语言"), selection: Binding(get: { lc.lang }, set: { lc.set($0) })) { ForEach(UILang.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
            }
            Section(L("配置文件")) {
                HStack {
                    Text(ConfigFile.displayPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    if configExists {
                        Button(L("打开")) { NSWorkspace.shared.open(ConfigFile.url) }
                        Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url]) }
                    } else {
                        Button(L("创建配置文件")) {
                            save()
                            do { try ConfigFile.create(from: Settings.snapshot); configExists = true; status = L("✅ 已创建配置文件") }
                            catch { status = "❌ " + error.localizedDescription }
                        }
                    }
                }
                Text(configExists ? L("配置文件中的值优先于这里的设置；在这里保存会同步写回配置文件。API Key 不会写入文件。")
                                  : L("可选：用一个文本文件管理网关、模型和语音配置。未创建时使用这里的设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("网关")) {
                if keyManaged {
                    LabeledContent("API Key", value: L("由配置文件提供"))
                } else {
                    SecureField("API Key", text: $key)
                }
                TextField("Base URL", text: $base, prompt: Text("https://api.anthropic.com"))
                HStack {
                    Button(loading ? L("加载中…") : L("刷新可用模型")) { Task { await reload() } }.disabled(loading)
                    Text(models.isEmpty ? "" : LF("共 %d 个模型", models.count)).foregroundStyle(.secondary)
                    Spacer()
                    Menu(L("本地模型")) {
                        Button("Ollama · http://localhost:11434") { base = "http://localhost:11434"; tStyle = .chat; cStyle = .chat; if key.isEmpty { key = "ollama" } }
                        Button("LM Studio · http://localhost:1234") { base = "http://localhost:1234"; tStyle = .chat; cStyle = .chat; if key.isEmpty { key = "lm-studio" } }
                    }.fixedSize()
                }
                Text(L("API Key 保存在系统钥匙串中。也支持本机或局域网的 http:// 地址（如 Ollama、LM Studio），协议选 OpenAI Chat Completions。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if AppInfo.chatGPTAvailable { chatGPTSection }
            Section(L("翻译")) {
                modelRow(L("模型"), $tModel, from: tStyle == .chatgpt ? gpt.models.map(\.slug) : models, filter: { !$0.contains("tts") && !$0.contains("image") && !$0.contains("embedding") })
                Picker(L("接口协议"), selection: $tStyle) { ForEach(APIStyle.available) { Text($0.name).tag($0) } }
                Picker(L("翻译目标语言"), selection: $lang) { ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어"], id: \.self) { Text($0) } }
                Stepper(LF("提前翻译 %d 页", lookahead), value: $lookahead, in: 0...10)
            }
            Section(L("AI 助手 / 解读 / 闪卡")) {
                modelRow(L("模型"), $cModel, from: cStyle == .chatgpt ? gpt.models.map(\.slug) : models, filter: { !$0.contains("tts") && !$0.contains("image") && !$0.contains("embedding") })
                Picker(L("接口协议"), selection: $cStyle) { ForEach(APIStyle.available) { Text($0.name).tag($0) } }
                Text(L("AI 解读会把页面截图发给模型，请选择支持图片输入的模型。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("PDF 打开方式")) {
                HStack {
                    Text(isDefaultPDF ? L("Readlet 已是默认 PDF 阅读器") : L("当前默认：") + defaultPDFAppName)
                    Spacer()
                    Button(isDefaultPDF ? L("已设为默认") : L("设为默认 PDF 工具")) { setDefaultPDF() }.disabled(isDefaultPDF)
                }
                Text(L("也可以在访达中右键任意 PDF →「打开方式」选择 Readlet。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("外观")) {
                Picker(L("主题"), selection: $theme) { ForEach(AppTheme.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
            }
            Section(L("更新")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LF("当前版本 %@", "\(UpdateChecker.currentVersion) (\(AppInfo.build))"))
                        if !updater.statusText.isEmpty {
                            Text(updater.statusText).font(.caption).foregroundStyle(updater.availableRelease != nil ? Color.accentColor : .secondary)
                        }
                    }
                    Spacer()
                    if let rel = updater.availableRelease {
                        Button(LF("下载 %@", rel.version)) { updater.openDownload(for: rel) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(updater.checking ? L("正在检查更新…") : L("检查更新…")) {
                        Task { await updater.check(manual: true) }
                    }.disabled(updater.checking)
                }
                Toggle(L("启动时与后台自动检查新版本"), isOn: Binding(get: { updater.autoCheckEnabled }, set: { updater.autoCheckEnabled = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    /// Sign in with ChatGPT: use the ChatGPT Plus / Pro plan instead of an API key
    var chatGPTSection: some View {
        Section(L("ChatGPT 账号")) {
            if gpt.phase == .connected, gpt.profile != nil {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gpt.accountLabel).font(.callout.weight(.semibold))
                        Text(gpt.connected ? L("已连接 · 可使用 ChatGPT 套餐额度") : L("已登录，但没有授权使用套餐额度")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("管理用量")) { NSWorkspace.shared.open(ChatGPTAuth.usageURL) }
                    Menu(L("账号")) {
                        if !gpt.connected { Button(L("重新授权")) { gpt.signIn() } }
                        ForEach(gpt.savedProfiles.filter { $0.client_id != gpt.profile?.client_id && $0.refresh_token != nil }, id: \.client_id) { p in
                            Button(L("切换到 ") + (p.email ?? p.subject)) { gpt.select(clientId: p.client_id) }
                        }
                        Button(L("添加其他账号…")) { gpt.signIn(newAccount: true) }
                        Divider()
                        Button(L("退出登录"), role: .destructive) { gpt.signOut() }
                    }.fixedSize()
                }
                if gpt.connected {
                    HStack {
                        Text(gpt.models.isEmpty ? L("正在获取可用模型…") : LF("可用模型 %d 个", gpt.models.count)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("用 ChatGPT 运行翻译和 AI 助手")) {
                            tStyle = .chatgpt; cStyle = .chatgpt
                            let first = gpt.models.first?.slug ?? ""
                            if !first.isEmpty { tModel = first; cModel = first }
                            status = L("已切换到 ChatGPT 账号，点「保存」生效")
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button { gpt.signIn() } label: {
                        Label(gpt.phase == .signingIn ? L("等待浏览器授权…") : (gpt.phase == .needsReconnect ? L("重新连接 ChatGPT") : "Continue with ChatGPT"), systemImage: "person.crop.circle.badge.checkmark")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.black)
                    .disabled(gpt.phase == .signingIn)
                    Text(L("ChatGPT Plus / Pro 用户可直接用自己的套餐额度运行 Readlet 的 AI 功能，不需要 API Key。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !gpt.message.isEmpty { Text(gpt.message).font(.caption).foregroundStyle(.secondary) }
        }
        .task { if gpt.connected && gpt.models.isEmpty { await gpt.refreshModels() } }
    }

    var voiceTab: some View {
        Form {
            Section(L("AI 解读风格")) {
                Picker(L("讲解风格"), selection: $narrStyle) {
                    ForEach(NarrationStyle.allCases) { st in Text(L(st.title) + " — " + L(st.subtitle)).tag(st) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("补充提示词（可选）")).font(.callout)
                    TextEditor(text: $narrExtra)
                        .font(.system(size: 12.5))
                        .frame(minHeight: 60, maxHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Text(L("例如：多结合代码讲解；每页结尾用一句话总结；讲给高中生听。修改后新生成的讲解会采用新风格，已生成的旧风格内容会保留，切回去可直接复用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("语音（TTS）")) {
                Picker(L("语音引擎"), selection: $ttsProvider) {
                    ForEach(TTSProvider.allCases) { Text(L($0.title)).tag($0) }
                }
                if ttsProvider == .system {
                    Picker(L("音色"), selection: $sysVoice) {
                        Text(L("自动（按目标语言）")).tag("")
                        ForEach(SystemTTS.options(for: lang)) { Text($0.label).tag($0.id) }
                    }
                    if SystemTTS.hasOnlyCompactVoices {
                        HStack(alignment: .top) {
                            Label(L("现在只有「紧凑版」系统声音，听起来比较机械。下载一个「高级」版会自然很多（免费）。"), systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(L("去下载…")) { NSWorkspace.shared.open(SystemTTS.spokenContentSettingsURL) }
                        }
                    }
                    Text(L("更自然的声音可在「系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音」中下载，推荐「高级」或「增强」版本。")).font(.caption).foregroundStyle(.secondary)
                } else {
                    remoteTTSFields
                }
                HStack {
                    Button(L("试听")) {
                        save(); status = L("合成中…")
                        Task {
                            do { try await Narrator.shared.previewVoice(); status = "✅ " + L("试听") }
                            catch { status = "❌ TTS: " + error.localizedDescription }
                        }
                    }
                    if ttsProvider.isRemote {
                        Text(L("请求失败（如没有模型、Key 无效）时，讲解会自动改用系统语音。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var remoteTTSFields: some View {
        let p = ttsProvider
        if p == .gateway {
            LabeledContent(L("地址与 Key"), value: L("使用「通用」中的网关"))
        } else {
            TextField(L("Base URL"), text: $tts.baseURL, prompt: Text(p.defaultBaseURL.isEmpty ? p.baseURLHint : p.defaultBaseURL))
            if !p.baseURLHint.isEmpty, p.baseURLHint != p.defaultBaseURL {
                Text(L("留空使用默认：") + p.baseURLHint).font(.caption).foregroundStyle(.secondary)
            }
            if tts.keyManaged {
                LabeledContent("API Key", value: L("由配置文件提供"))
            } else {
                HStack {
                    SecureField(p == .volcengine ? "Access Token" : "API Key", text: $tts.key)
                    if let h = p.keyHelpURL, let u = URL(string: h) { Link(L("获取"), destination: u).font(.caption) }
                }
            }
        }
        if p.needsRegion { TextField(L("区域（Region）"), text: $tts.region, prompt: Text("eastasia / eastus / westeurope…")) }
        if p.needsAppId { TextField("App ID", text: $tts.appId) }
        if p != .azure {
            HStack {
                modelRow(p == .volcengine ? L("集群（Cluster）") : L("TTS 模型"), $tts.model, from: p == .gateway ? models : ttsModels, filter: { $0.contains("tts") || p != .gateway })
            }
        }
        HStack {
            TextField(L("音色"), text: $tts.voice, prompt: Text(p.defaultVoice))
            if !p.voiceSuggestions.isEmpty {
                Menu(L("常用音色")) {
                    ForEach(p.voiceSuggestions) { v in Button(v.label) { tts.voice = v.id } }
                }.fixedSize()
            }
        }
        HStack(alignment: .top) {
            Text(providerNote(p)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let u = URL(string: AppInfo.supportURL.absoluteString + "#tts-" + p.rawValue) { Link(L("详细步骤"), destination: u).font(.caption) }
        }
    }

    func providerNote(_ p: TTSProvider) -> String {
        switch p {
        case .gateway: return L("网关需提供 OpenAI 兼容的 POST /v1/audio/speech。")
        case .openai: return L("OpenAI 官方，或任何兼容 POST /v1/audio/speech 的服务（如 SiliconFlow、本地 Kokoro）。")
        case .gemini: return L("使用 Gemini API 的 Interactions 接口，Key 来自 Google AI Studio。")
        case .qwen: return L("阿里云百炼 DashScope：北京地域用默认地址，新加坡地域改用 dashscope-intl。模型如 qwen3-tts-flash。")
        case .azure: return L("填写语音资源的 Key 和区域；音色用完整名称，如 zh-CN-XiaoxiaoNeural。")
        case .elevenlabs: return L("音色填 Voice ID，可在 ElevenLabs 的 Voice Library 中复制。")
        case .minimax: return L("国内用默认地址，海外账号改用 https://api.minimax.io。")
        case .volcengine: return L("在火山引擎控制台创建语音合成应用，填写 App ID 和 Access Token。")
        case .system: return ""
        }
    }

    static let featureNames: [String: String] = ["translate": "翻译", "narration": "AI 解读", "assistant": "AI 助手", "flashcards": "闪卡", "mindmap": "AI 脑图", "tts": "语音合成"]

    var usageSection: some View {
        let _ = usageTick
        let sum = UsageStore.shared.summary(days: usageDays)
        return Section(L("模型用量")) {
            Picker(L("时间范围"), selection: $usageDays) {
                Text(L("今天")).tag(1); Text(L("最近 7 天")).tag(7); Text(L("最近 30 天")).tag(30)
            }.pickerStyle(.segmented)
            LabeledContent(L("模型调用"), value: LF("%d 次", sum.calls))
            LabeledContent(L("输入 / 输出 token"), value: sum.input.compact + " / " + sum.output.compact)
            if sum.ttsChars > 0 { LabeledContent(L("在线语音合成"), value: LF("%@ 字", sum.ttsChars.compact)) }
            if Pricing.enabled { LabeledContent(L("估算费用"), value: Pricing.format(sum.cost)) }
            ForEach(UsageStore.shared.byFeature(days: usageDays), id: \.feature) { f in
                LabeledContent(L(SettingsView.featureNames[f.feature] ?? f.feature),
                               value: f.feature == "tts" ? LF("%@ 字", f.input.compact) : LF("%d 次 · %@ token", f.calls, (f.input + f.output).compact))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if sum.estimated > 0 { Text(LF("其中 %d 次调用的网关没有返回用量，按字数估算。", sum.estimated)).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(L("单价（每百万）")).font(.callout)
                TextField(L("输入"), value: $priceIn, format: .number).frame(width: 64)
                TextField(L("输出"), value: $priceOut, format: .number).frame(width: 64)
                TextField(L("语音字"), value: $priceTTS, format: .number).frame(width: 64)
                TextField(L("货币"), text: $currency).frame(width: 36)
            }
            Text(L("填写你的网关价格（每百万 token、每百万字），用于估算费用；留 0 不显示金额。ChatGPT 账号使用套餐额度，不计费。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("清空统计")) { UsageStore.shared.reset(); usageTick += 1 }
            }
        }
    }

    var storageTab: some View {
        Form {
            usageSection
            Section(L("存储")) {
                if let u = usage {
                    LabeledContent(L("讲解语音缓存"), value: StorageManager.format(u.audio))
                    LabeledContent(L("导出讲解视频"), value: StorageManager.format(u.video))
                    LabeledContent(L("双语页面缓存"), value: StorageManager.format(u.bilingual))
                    LabeledContent(L("PDF 原文件"), value: StorageManager.format(u.pdfs))
                    LabeledContent(L("笔记、讲稿与翻译"), value: StorageManager.format(u.other))
                    LabeledContent(L("合计"), value: StorageManager.format(u.total)).fontWeight(.semibold)
                } else {
                    HStack { ProgressView().controlSize(.small); Text(L("正在统计…")).foregroundStyle(.secondary) }
                }
                Stepper(value: $cacheLimit, in: 0.5...50, step: 0.5) {
                    Text(LF("语音缓存上限 %@", String(format: "%.1f GB", cacheLimit)))
                }
                Text(L("超过上限时，自动删除最久没听的文档的语音；需要时会重新合成。语音以 AAC 压缩保存，约为 WAV 的 1/8。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("清理语音缓存")) { run(L("正在清理…")) { StorageManager.clearAudio() } }
                    Button(L("清理双语缓存")) {
                        let open = Set(DocWindows.shared.entries.keys)
                        run(L("正在清理…")) { StorageManager.clearBilingual(open: open) }
                    }
                    Button(L("压缩旧的 WAV 语音")) { run(L("正在压缩…")) { _ = StorageManager.compressLegacyClips() } }
                }
                .disabled(!busy.isEmpty)
                HStack {
                    if !busy.isEmpty { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L("在访达中显示数据目录")) { NSWorkspace.shared.activateFileViewerSelecting([Paths.base]) }
                }
            }
            Section(L("单篇文档音视频空间")) {
                let docs = Store.shared.lib.docs
                if docs.isEmpty {
                    Text(L("当前没有占用的语音或视频缓存")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(docs) { d in
                        let du = StorageManager.docMediaUsage(d.id, title: d.title)
                        if du.totalResettableBytes > 0 || du.bilingualBytes > 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).font(.callout).lineLimit(1)
                                    Text(LF("语音 %@ (%d 段) · 视频 %@ (%d 个) · 讲稿 %@", StorageManager.format(du.audioBytes), du.audioCount, StorageManager.format(du.videoBytes), du.videoCount, StorageManager.format(du.scriptBytes)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu(L("重置")) {
                                    Button(L("清理语音与视频缓存")) {
                                        run(L("正在清理…")) { _ = StorageManager.resetDocMedia(d.id, title: d.title, includeScripts: false, includeBilingual: false) }
                                    }
                                    Button(L("清理语音、视频与双语缓存")) {
                                        run(L("正在清理…")) { _ = StorageManager.resetDocMedia(d.id, title: d.title, includeScripts: false, includeBilingual: true) }
                                    }
                                    Divider()
                                    Button(L("完全重置（含 AI 讲解稿）"), role: .destructive) {
                                        run(L("正在清理…")) { _ = StorageManager.resetDocMedia(d.id, title: d.title, includeScripts: true, includeBilingual: false) }
                                    }
                                }.fixedSize()
                            }
                        }
                    }
                }
            }
            Section(L("iCloud 多端同步（Mac · iPhone · iPad）")) {
                Toggle(L("自动通过 iCloud 同步文档、标签、阅读进度、卡片与配置"), isOn: $cloud.isEnabled)
                Text(L("仅同步 PDF、讲解稿、摘录批注、笔记本与阅读进度；语音与视频文件仅保留在本地，不占用 iCloud 流量与空间。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: cloud.state.isSyncing ? "arrow.triangle.2.circlepath.icloud.fill" : "checkmark.icloud.fill")
                        .foregroundStyle(cloud.isEnabled ? .blue : .secondary)
                    if cloud.state.isSyncing {
                        Text(L("正在与 iCloud 同步…")).font(.callout).foregroundStyle(.secondary)
                    } else if let dt = cloud.lastSyncedAt {
                        Text(LF("上次同步：%@", dt.formatted(date: .abbreviated, time: .standard))).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(L("就绪")).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("立即同步")) { cloud.syncNow() }
                        .disabled(!cloud.isEnabled || cloud.state.isSyncing)
                }
                if !cloud.cloudLocationDescription.isEmpty {
                    Text(cloud.cloudLocationDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshUsage() }
    }

    var footer: some View {
        HStack {
            Text(status).foregroundStyle(.secondary).lineLimit(2).font(.callout)
            Spacer()
            Button(L("测试连接")) {
                save(); status = L("测试中…")
                Task {
                    do {
                        let t = try await Translator.translateOne("Attention is all you need. (test \(Int.random(in: 0...9999)))")
                        let c = try await LLMClient.complete(role: "chat", system: "Reply in one short sentence.", input: LLMInput(text: "Say hello in Chinese."), maxTokens: 60)
                        status = "✅ " + L("翻译：") + "\(t)  ✅ " + L("助手：") + "\(c.prefix(40))"
                    } catch { status = "❌ " + error.localizedDescription }
                }
            }
            Button(L("保存")) {
                save(); status = L("✅ 已保存")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settingsWindow?.close() }
            }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: helpers

    @ViewBuilder func modelRow(_ label: String, _ v: Binding<String>, from all: [String], filter: @escaping (String) -> Bool) -> some View {
        let list = all.filter(filter)
        if list.isEmpty {
            TextField(label, text: v)
        } else {
            Picker(label, selection: v) {
                if !list.contains(v.wrappedValue) { Text(v.wrappedValue).tag(v.wrappedValue) }
                ForEach(list, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    func run(_ label: String, _ work: @escaping @Sendable () -> Void) {
        busy = label
        Task {
            await Task.detached(priority: .userInitiated) { work() }.value
            busy = ""
            await refreshUsage()
        }
    }

    func refreshUsage() async {
        usage = await Task.detached(priority: .utility) { StorageManager.usage() }.value
    }

    @State var pdfStateTick = 0
    var defaultPDFURL: URL? { _ = pdfStateTick; return NSWorkspace.shared.urlForApplication(toOpen: .pdf) }
    var isDefaultPDF: Bool { defaultPDFURL?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path }
    var defaultPDFAppName: String { defaultPDFURL.map { FileManager.default.displayName(atPath: $0.path) } ?? L("无") }
    func setDefaultPDF() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { err in
            DispatchQueue.main.async { pdfStateTick += 1; status = err == nil ? L("✅ 已将 Readlet 设为默认 PDF 工具") : "❌ " + (err?.localizedDescription ?? "") }
        }
    }

    func reload() async {
        if !keyManaged { Settings.apiKey = key }
        Settings.baseURL = base
        loading = true
        models = await LLMClient.listModels()
        loading = false
    }

    func save() {
        if !keyManaged { Settings.apiKey = key }
        Settings.baseURL = base; Settings.targetLang = lang
        ModelConfig.setModel("translate", tModel); ModelConfig.setStyle("translate", tStyle)
        ModelConfig.setModel("chat", cModel); ModelConfig.setStyle("chat", cStyle)
        tts.save(ttsProvider)
        Narrator.shared.provider = ttsProvider
        Narrator.shared.voice = Settings.ttsVoice(ttsProvider)
        if Settings.narrationStyle != narrStyle { Settings.narrationStyle = narrStyle }
        if Settings.narrationExtraPrompt != narrExtra { Settings.narrationExtraPrompt = narrExtra }
        Narrator.shared.systemVoice = sysVoice
        Settings.lookahead = lookahead
        if cacheLimit != Settings.ttsCacheLimitGB { Settings.ttsCacheLimitGB = cacheLimit }
        if priceIn != Pricing.inputPerMTok { Pricing.inputPerMTok = priceIn }
        if priceOut != Pricing.outputPerMTok { Pricing.outputPerMTok = priceOut }
        if priceTTS != Pricing.ttsPerMChars { Pricing.ttsPerMChars = priceTTS }
        if currency != Pricing.currency { Pricing.currency = currency }
        ThemeCenter.shared.set(theme)
        CloudSync.shared.recordSettingsChange()
    }
}
#endif
