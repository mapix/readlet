# Readlet Agent Guidelines (`AGENTS.md`)

本文档整理了 Readlet（macOS 14+ & iOS/iPadOS 17+ 双端 AI 双语阅读器）的核心架构、构建签名、公证发布、跨端同步与 AI 语音解读开发规范。所有协作 Agent 在修改代码或发布安装包时必须严格遵守。

---

## 1. 官网 macOS 安装包发布规范（最高优先级 · 强制）

**任何上传至官网（`https://readlet.novarock.io/download/`）的 macOS 安装包（`Readlet-<VERSION>.zip`），始终必须先完成 Apple Developer ID 签名、公证（Notarize）与票据订合（Staple），严禁上传未公证的安装包。**

### 1.1 标准构建与公证流程
运行 [`./build_app.sh`](file:///Users/mac/workspaces/readlet/build_app.sh)，确保完整走通以下四步：
1. **签名（Hardened Runtime）**：使用 `Developer ID Application` 证书（本地钥匙串或 Xcode Cloud-Managed Developer ID）对 `build/Readlet.app` 签名并附带安全时间戳（`Timestamp`）。
2. **提交公证（Notarize）**：使用 `xcrun notarytool submit dist/Readlet-<VERSION>.zip ... --wait` 提交 Apple Notary 服务，必须等待返回 `status: Accepted`（私钥默认从 `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` 或 `~/.asc/keys/` 读取，切勿将 `.p8` 或 `.env.local` 提交进 Git）。
3. **订合票据（Staple）**：执行 `xcrun stapler staple build/Readlet.app`。
4. **重新打包**：订合完成后必须重新生成 `dist/Readlet-<VERSION>.zip` 并同步更新本机 `/Applications/Readlet.app`。

### 1.2 上传官网前的强制校验（缺一不可）
在将 `dist/Readlet-<VERSION>.zip` 同步到官网前，**必须**执行以下两条命令并确认通过：
```bash
xcrun stapler validate build/Readlet.app
spctl -a -vvv -t exec build/Readlet.app
```
必须确认输出包含：
- `The validate action worked!`
- `build/Readlet.app: accepted`
- `source=Notarized Developer ID`

校验通过后，再计算最新包的 `sha256` 与 `size`，更新 `landing/download/latest.json` 并部署至官网集群（注意：`landing/download/` 下的二进制包不入 Git 仓库）。

---

## 2. 项目架构与核心模块速查

项目基于单一 Swift Package（[`Package.swift`](file:///Users/mac/workspaces/readlet/Package.swift)），同一套源码通过条件编译（`#if os(macOS)` / `#if os(iOS)`）同时构建 macOS 与 iOS/iPadOS 应用：

| 模块 | 文件路径 | 核心职责 |
|---|---|---|
| 应用入口 | [`App.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/App.swift), [`iOSApp.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/iOSApp.swift) | macOS 多窗口/菜单栏入口与 iOS 四栏（书库、闪卡、AI 助手、设置）+ 播客迷你播放器入口 |
| 阅读与双语合成 | [`Reader.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Reader.swift), [`Bilingual.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Bilingual.swift), [`PDFEditor.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/PDFEditor.swift) | PDF 渲染、保留原排版的逐页双语对照生成（`bi2-*`）、PDF 截断/擦除/删除页编辑 |
| AI 与配置 | [`LLMClient.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/LLMClient.swift), [`Translator.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Translator.swift), [`Config.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Config.swift) | 统一封装 Anthropic Messages、OpenAI Chat Completions、OpenAI Responses 及 ChatGPT OAuth；管理 `Settings` 与 `config.toml` |
| AI 语音解读 | [`Narrator.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Narrator.swift), [`NarratorUI.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/NarratorUI.swift), [`NarrationStyle.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/NarrationStyle.swift), [`ScriptParser.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/ScriptParser.swift) | 逐页多模态讲稿生成（`p<N>.json`）、分句高亮跟随、倍速播放、锁屏控制（`MPNowPlayingInfoCenter`）与语音打断问答 |
| 语音合成引擎 | [`RemoteTTS.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/RemoteTTS.swift), [`RemoteTTS+Synth.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/RemoteTTS+Synth.swift), [`SystemTTS.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/SystemTTS.swift), [`AudioCodec.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/AudioCodec.swift) | 支持系统离线语音、主网关、OpenAI、Gemini、通义千问 Qwen-TTS、Azure、ElevenLabs、MiniMax、火山引擎豆包；音频统一转为干净 16-bit PCM WAV 播放并以 AAC `.m4a` 落盘缓存 |
| 预渲染与视频导出 | [`NarrationExport.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/NarrationExport.swift) | 「准备全部讲解」（全量预生成讲稿+语音，macOS/iOS 均支持）及竖屏字幕讲解视频导出（macOS） |
| 跨端同步与存储 | [`CloudSync.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/CloudSync.swift), [`LanSync.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/LanSync.swift), [`StorageManager.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/StorageManager.swift) | iCloud ubiquity 容器同步 + 局域网 Bonjour (`_readlet-sync._tcp`) 点对点直连同步 + 音视频缓存配额与按文档清理 |
| 笔记、脑图与闪卡 | [`Models.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Models.swift), [`MindMap.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/MindMap.swift), [`Flashcards.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Flashcards.swift), [`Copilot.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Copilot.swift) | 摘录批注、思维导图、SM-2 间隔重复闪卡与文档 AI 助手对话 |

---

## 3. 构建、测试与App Store / 真机发布流程

### 3.1 单元测试
每次修改核心逻辑后必须运行并通过全部测试：
```bash
swift test
```

### 3.2 macOS 构建
- **官网直装版（含自动签名、公证、订合、安装至 `/Applications/Readlet.app`）**：
  ```bash
  ./build_app.sh
  ```
- **Mac App Store 版（沙盒 `-DMAS`，生成 `dist/Readlet-<VERSION>-AppStore.pkg`）**：
  ```bash
  ./build_mas.sh
  ./upload_mas.sh dist/Readlet-<VERSION>-AppStore.pkg
  ```

### 3.3 iOS / iPadOS 构建与真机调试
- **同时构建模拟器版与真机版（`build/Readlet-iOS.app` + `dist/Readlet-<VERSION>-iOS.ipa`）**：
  ```bash
  ./build_ios.sh
  ```
- **导出 iOS App Store 提审包（`dist/Readlet-<VERSION>-iOS-AppStore.ipa`）**：
  ```bash
  ./build_ios.sh appstore
  ```
- **安装到已连接的 iPhone 并重启进程（确保新二进制立即生效）**：
  安装真机包后，务必携带 `--terminate-existing` 启动，避免手机上仍驻留旧进程：
  ```bash
  xcrun devicectl device install app --device <DEVICE_UUID> build/Readlet-iOS.app
  xcrun devicectl device process launch --terminate-existing --device <DEVICE_UUID> io.novarock.readlet
  ```
- **注意事項（Build 号递增）**：
  每次向 App Store Connect 上传新构建（macOS `.pkg` 或 iOS `.ipa`）时，`CFBundleVersion`（`BUILD`）必须严格大于已上传构建号。

---

## 4. 跨端同步、数据迁移与存储规范

1. **云端同步范围（轻量化原则）**：
   - **同步项**：PDF 原文（`original.pdf`）、封面缩略图（`thumb.png`）、书库元数据与阅读/讲解进度（`library.json`）、闪卡（`cards.json`）、AI 对话记录（`copilot.json`）、翻译缓存（`translations.json`）、讲解文稿（`narration/p*.json`、`progress.json`）以及网关/TTS 配置与各服务商 Key（`cloud-settings.json`，含 `apiKey` 与 `providerKeys`）。
   - **仅存本地项（不同步至 iCloud）**：合成后的音频切片（`.m4a` / `.wav`）、导出的视频（`.mp4` / `.mov`）以及体积较大的双语页面缓存（`bi2-*`）。
2. **版本升级数据迁移**：
   - 旧版本曾将 `.m4a` / `.wav` 放入 iCloud 容器的，新版本启动时由 [`CloudSync.migrateCloudAudioToLocalIfNeeded`](file:///Users/mac/workspaces/readlet/Sources/Readlet/CloudSync.swift) 先将云端音频无损迁回本地 `docs/<UUID>/narration/`，再清理云端副本，确保老用户升级后已生成的语音不丢失。
3. **局域网点对点直连同步（[`LanSync.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/LanSync.swift)）**：
   - 当 iCloud 尚未完成大体积 PDF 的后台下载时，同一局域网下的 Mac 与 iPhone/iPad 通过 Bonjour（`_readlet-sync._tcp`）自动发现并直接拉取缺失的 `original.pdf` 与 `narration/p*.json`。
   - 对云端已登记但本地尚未落盘的 PDF，统一使用 `iCloudPlaceholder.ensure(at:title:)` 生成带 `X-Readlet-Placeholder: 1` 标记的轻量占位 PDF，并在下载后校验 `isUsablePDFFile`（排除占位文件与损坏文件）。

---

## 5. AI 语音解读（Narrator）与远程 TTS 性能规范

1. **首段未缓存时独占通道（零竞争）**：
   - 在 [`Narrator.play(page:seg:)`](file:///Users/mac/workspaces/readlet/Sources/Readlet/Narrator.swift) 中，若当前待播放段落尚未缓存（`!hasClip`），必须先取消后台 `prefetchTask` 及非当前段的合成任务，**等当前段合成完毕并调用 `pl.play()` 开始播放后**，才启动后续段落的 `prefetch` 与下一页讲稿生成，避免预取任务抢占网关连接导致首字迟迟不出声。
2. **远程 TTS 并发上限与超时重连**：
   - 主网关（`gemini-3.8-flash-tts` 等）在同一 HTTP/2 连接上并发超过 2 路时容易挂起流，因此 `Narrator.prefetch` 与 `NarrationExport` 的远程 TTS 并发窗口上限固定为 `2`。
   - [`RemoteTTS+Synth.swift`](file:///Users/mac/workspaces/readlet/Sources/Readlet/RemoteTTS+Synth.swift) 单次请求超时设为 `28s~38s`；第 1 次失败或超时后，重试必须使用全新的 `URLSession(configuration: .ephemeral)` 独立连接（`Connection: close`），防止死连接阻塞重试。
3. **跨页/跨段切换保留在途任务**：
   - 正常顺序播放切换到下一段或下一页时，`prefetch` 只取消不在新 `plan` 窗口内的孤儿任务，必须保留已经在合成中的后续段落任务，杜绝“刚合成一半就被取消重来”导致讲一段停一段。
4. **iOS 预渲染与后台保活对齐**：
   - iOS 端与 macOS 端全面对齐「准备全部讲解」（`NarrationExporter.shared.start(prepareOnly: true)`），支持在阅读器顶栏菜单、底部讲解面板及文库卡片长按菜单一键预生成全书讲稿与语音。
   - iOS 后台切换段落/页面等待网络返回期间，通过 `AVAudioSession`（`.playback` + `.spokenAudio`）与低幅静音帧保活流（`keepAlivePlayer`）维持后台运行不被系统挂起。
