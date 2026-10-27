# Readlet Agent Guidelines (`AGENTS.md`)

## 1. 官网 macOS 安装包（`Readlet-<VERSION>.zip`）发布规范（强制）

**上传到官网（`https://readlet.novarock.io/download/`）的 macOS 安装包，始终必须先完成 Apple Developer ID 签名、公证（Notarize）与票据订合（Staple），严禁上传未公证的安装包。**

### 标准流程与强制校验步骤
1. **构建、签名、公证与订合**：
   运行 [`./build_app.sh`](file:///Users/mac/workspaces/readlet/build_app.sh)，确保脚本完成以下步骤：
   - 使用 `Developer ID Application: Weifeng Luo (BDH2HLQA9V)`（Hardened Runtime + Timestamp）对 `build/Readlet.app` 签名；
   - 使用 `xcrun notarytool submit dist/Readlet-<VERSION>.zip ... --wait` 提交 Apple 公证并等待返回 `status: Accepted`；
   - 使用 `xcrun stapler staple build/Readlet.app` 将公证票据订合进 App Bundle；
   - 重新打包订合后的 `build/Readlet.app` 生成最终的 `dist/Readlet-<VERSION>.zip`。

2. **上传官网前的强制校验（缺一不可）**：
   在将 `dist/Readlet-<VERSION>.zip` 同步到官网前，必须执行以下两条校验命令并确认通过：
   ```bash
   xcrun stapler validate build/Readlet.app
   spctl -a -vvv -t exec build/Readlet.app
   ```
   必须确认输出包含：
   - `The validate action worked!`
   - `build/Readlet.app: accepted`
   - `source=Notarized Developer ID`

3. **同步部署到官网**：
   确认上述校验通过后，再生成 `landing/download/latest.json`（含最新 `sha256` 与 `size`）并发布至 `novarocks` 集群。
