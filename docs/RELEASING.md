# 正式发行 / Signed releases

正式发行与本地开发打包使用不同入口。本地 `./scripts/build_app.sh` 可以使用 Apple Development 或 ad-hoc 签名；它不执行公证。公开发行使用 `--release`，只接受 Developer ID Application 身份。不得把默认开发包上传成已公证版本。

本流程的输出包括应用与 DMG 的签名、Apple 公证结果和验证记录。干净 Mac 的实际安装、更新与语音体验需另行验收，不能由脚本成功替代。1.1.0 及更早的公开安装包未经公证；新版本以对应 GitHub Release 的证据为准。

## 1. 准备发行环境

需要 Apple Silicon Mac、可用 Xcode/Swift/Metal 工具链、Apple Developer Program 的 Developer ID Application 证书及对应私钥，以及该团队可用的公证认证。证书由开发者本人在 Apple 开发者账户和钥匙串中配置。

```bash
security find-identity -v -p codesigning
xcrun notarytool --help
xcrun stapler --help
```

同一开发者团队的有效 Developer ID Application 证书可用于多个项目，无需给 XiaoPen 单独购买或创建一套身份。每个新发行版本的 XiaoPen 应用及最终 DMG 仍须完成本项目的签名、公证、附票据与验证；其他项目的公证结果不能复用。

### 复用 Xcode 已登录的开发者账户

如果同一 Mac 的其他项目已经通过 Xcode 完成公证，可在 Xcode 的 **Settings → Accounts** 中确认既有账户仍有效，且能访问签名证书所属团队。使用 `--notary-via-xcode` 直接由 Xcode 管理已有账户认证与归档上传，不必为了 XiaoPen 另建 app-specific password 或 `notarytool` profile。

Xcode 登录状态与 `notarytool --keychain-profile` 是两种独立的认证入口。已经用 Xcode 公证过其他项目，并不表示本机存在可直接传给 `notarytool` 的 profile。无需提取、复制或导出 Xcode 的 token、账户数据库或钥匙串秘密；账户失效时由本人在 Xcode 中完成正常重新登录或验证。

### 使用 notarytool 钥匙串 profile

无人值守构建等场景也可使用已有 `notarytool` profile；相同团队的有效 profile 可跨项目复用。尚未配置时，按工具提示由本人交互式输入 Apple ID、团队 ID 和 app-specific password：

```bash
xcrun notarytool store-credentials XiaoPen-notary
```

也可按 Apple 官方说明使用 App Store Connect API key。`--notary-via-xcode` 与 `--notary-profile NAME` 必须二选一；Xcode 路径不使用 `--notary-keychain`。

认证材料仅保存在 Xcode、钥匙串或受保护的 CI secret 中，不得提交到仓库、命令日志、截图、Release 附件或诊断包。不要把密码作为脚本参数写进历史。签名私钥访问、钥匙串解锁及 Apple 账户验证由本人完成；不要通过修改信任或钥匙串访问策略来跳过提示。

## 2. 测试、构建与公证

在独立发行工作树中更新 `Resources/Info.plist` 的版本号和构建号，并核对 `CHANGELOG.md`、Release tag 与安装包版本一致。先完成修改与提交，确认 `git status --porcelain` 无输出，再开始正式构建；发行预检会拒绝有未提交修改或未追踪文件的源码。记录 `git rev-parse HEAD`，该提交也会写入本次 `release-summary.txt`。

```bash
swift test --parallel
python3 scripts/test_release_workflow.py
./scripts/build_app.sh --release --notary-via-xcode --keep-app
```

如果 Xcode 已安装 Metal Toolchain，但 `swift test` 仍提示找不到 Metal 编译器，可显式指定 `xcrun` 实际解析的工具后重试。打包脚本已为自身的构建自动传入这两个参数；测试需要独立运行并确认最终结果：

```bash
swift test --parallel \
  -Xxcbuild "METAL_EXEC=$(xcrun --find metal)" \
  -Xxcbuild "METALLIB_EXEC=$(xcrun --find metallib)"
```

已有 Xcode 账户的构建使用上面的 `--notary-via-xcode`。使用钥匙串 profile 时改为以下入口；有多个 Developer ID Application 身份时，明确选择证书 SHA-1 或完整名称：

```bash
./scripts/build_app.sh --release \
  --sign-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile XiaoPen-notary \
  --keep-app
```

仅 profile 路径的凭据在自定义钥匙串中时，增加 `--notary-keychain /absolute/path/to/signing.keychain-db`。`--skip-build --bin-dir /absolute/path/to/release/products` 仅用于复用已经核对来源与版本的 Release 构建。使用前必须确认 app、helper、资源和 Metal 库均来自当前发行提交，保留该提交的构建日志与产物哈希；源码干净以及摘要记录了 HEAD，并不能证明外部目录中二进制的来源。无法确认时重新构建。正式发行不接受 `--install` 和 `--no-dmg`。

正式流程应依次完成：

1. 检查源码工作树干净、Developer ID 身份、所选公证认证入口和工具，记录源提交。仅有 Apple Development 身份、身份不唯一或身份不可用时终止，不回退到 ad-hoc。
2. 对嵌入的可执行代码从内到外签名，再签主应用；使用 Hardened Runtime 与安全时间戳。主应用仅声明麦克风 `com.apple.security.device.audio-input` 和天气定位 `com.apple.security.personal-information.location` 访问；不绕过用户授权。当前 helper 使用原生 MLX / Metal，不增加 JIT 或关闭库验证的 entitlement。验证每份代码的签名和团队身份。
3. 通过所选入口提交应用：profile 路径上传临时 ZIP，立即保存 UUID，再执行 `wait` / `info` 并核对 Apple 返回 `Accepted`；Xcode 路径使用归档的 `exportArchive` 上传和 `exportNotarizedApp` 导出，并保存分发日志及提交信息。两种路径均须给应用附票据并通过 `stapler validate`；等待超时、中断或仅上传成功均不视为公证完成。
4. 用已附票据的应用制作并签署最终 DMG，保留拖到 Applications 的安装方式。profile 路径直接提交该 DMG；Xcode 路径将同一份已签名 DMG 放进仅用于上传的私有应用副本，由 Xcode 归档上传。该载体只存在于临时工作区，不进入最终 DMG，也不作为额外安装入口发布。核对复制前后 DMG 的哈希不变，并要求 Apple 日志中包含与最终 DMG 文件名和 cdhash 相符的票据，之后才给原始 DMG 附票据并验证；载体应用被接受，不能替代 DMG 本身的票据与验证。
5. 验证最终应用、helper、DMG 签名，运行适用的 Gatekeeper / `syspolicy_check` 检查；全部成功后才保留正式 DMG 并计算 SHA-256。

签名、时间戳、Apple 返回状态、附票据、容器创建和任一验证失败都会终止。正式发行没有 ZIP 降级路径。不要手工绕过失败步骤后发布同一文件。

## 3. 核对产物与证据

版本号由 Info.plist 读取。成功后的安装包为 `build/XiaoPen-<version>.dmg`，最终文件校验和为 `build/SHA256SUMS`；使用 `--keep-app` 时还保留已附票据的 `build/XiaoPen.app`。

每次运行的记录位于 `build/notarization/<version>-<build>-<UTC>-<random>/`，其中 `release-summary.txt` 记录版本、身份和源提交。profile 路径的 Apple 状态证据如下：

```text
build/notarization/<version>-<build>-<UTC>-<random>/
  app-submit.json           # 上传返回的 UUID
  app-wait.json
  app-info.json             # Apple 的最终状态
  app-notary-log.json
  dmg-submit.json
  dmg-wait.json
  dmg-info.json
  dmg-notary-log.json
  app-entitlements.plist
  signatures.log
  ... verification and stderr logs ...
  release-summary.txt       # 版本、身份、源提交、UUID、状态
```

Xcode 路径在同一证据目录中保留以下文件；归档和私有 DMG 载体只用于复查，不随 Release 作为安装附件发布：

```text
xcode/app.xcarchive/
xcode/dmg.xcarchive/
app-xcode-upload.log
app-xcode-export-XX.log
app-notary-log.json
app-xcode-result.json
dmg-xcode-upload.log
dmg-xcode-export-XX.log
dmg-notary-log.json
dmg-xcode-result.json
```

Xcode 导出仅在已知的 Apple 处理中状态下重试，最多等待 20 分钟；超时或其他错误会终止，不视为公证通过。两种入口均须保存最终应用和 DMG 的附票据与验证记录。

应保留成功及失败运行的提交 ID、公证日志和验证记录。profile 路径可通过 `notarytool info` / `notarytool log` 重新查询；Apple 仍在处理的提交可能没有公证日志，保留 `*-submit.json` 的 UUID 和 `*-info.json` 状态，待处理完成后再查询。Xcode 路径通过对应归档和分发日志复查；不要为了查询状态而提取账户 token 或假定存在 `notarytool` profile。不要把 Apple 认证凭据放入这些文件。发布附件前审查内容，移除与验证无关的本机路径或个人信息。

独立核对最终文件；票据附加后不要再修改应用、重签、重新压缩或更改 DMG 内容：

```bash
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
cd build
shasum -a 256 -c SHA256SUMS
codesign --verify --strict --verbose=2 "XiaoPen-$VERSION.dmg"
xcrun stapler validate "XiaoPen-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "XiaoPen-$VERSION.dmg"
```

用 `hdiutil attach -readonly -nobrowse` 挂载最终 DMG，核对其中的 app 和 helper 仍具有正确 Developer ID 团队；对应用执行 `codesign --verify --deep --strict`、`xcrun stapler validate`、`spctl --assess --type execute`，支持该命令的系统还应执行 `syspolicy_check distribution`。验证后卸载镜像。

## 4. 从最终 GitHub 下载验收

可以先建立 draft Release，上传已通过前述检查的 DMG 和 `SHA256SUMS`，再通过浏览器从该 Release 下载进行验收。不要把本地打包文件的校验结果当成 GitHub 下载结果。记录下载 URL、tag、SHA-256、macOS 版本、机器或 VM 状态、在线/离线状态和检查结果。

以下步骤由获得本人同意的测试者在未给 XiaoPen 添加过放行例外的 Mac 或干净 Apple Silicon VM 中执行。不要清除 quarantine、关闭 Gatekeeper、安全启动或其他系统保护；不要使用“仍要打开”完成验收。

- [ ] 浏览器下载最终 DMG 和 `SHA256SUMS`；重新计算 SHA-256 并与附件一致。可用 `xattr -p com.apple.quarantine <DMG>` 只读核对下载标记，不删除它。
- [ ] 挂载并拖入 Applications，首次普通双击打开，无需进入“隐私与安全性”手动放行。系统正常的“从互联网下载，是否打开”确认可以保留。
- [ ] 在另一份干净 VM 快照中，先下载但不打开应用，断网后挂载并安装、首次打开，核对附票据支持离线 Gatekeeper 检查。离线打开验证不代表在线模型或云端语音识别可用。
- [ ] 新安装首次运行按引导请求麦克风、语音识别权限；拒绝后应有恢复入口，授权后能恢复。正常的钥匙串访问提示与 Gatekeeper 安装放行是不同事项，不要求这些提示全部消失。
- [ ] 在预装旧版的独立测试环境中升级，核对选择的大脑、唤醒词、设置、提醒、模型文件和已有钥匙串数据按预期保留。旧开发或 ad-hoc 签名切换到 Developer ID 后可能需要重新授权，记录实际结果。
- [ ] 按本人的明确同意开始麦克风测试：喊唤醒词后停顿，再测试“唤醒词 + 立即提问”、回答及不重复唤醒词的连续追问。确认实际声音和交互；日志与测试通过不能代替听感验收。
- [ ] 已安装本地 Qwen3-TTS 模型的环境中生成并听到回复，确认已签名 helper 能加载模型、使用 Metal 并正确完成播放。Qwen3-TTS 不会自动回退到系统语音。
- [ ] 在设置中手动选择系统语音，确认实际播放正常。
- [ ] 以全局快捷键停止试听后重新播放，确认停止与重播恢复；自然语音打断需另行验收。

## 5. 发布与状态记录

Release 说明应写清版本、构建号、Developer ID 团队、应用和 DMG 的 Apple `Accepted` 提交 ID、票据/Gatekeeper 验证、最终 SHA-256，以及上面哪些真机或 VM 步骤已完成、哪些仍待确认。不应只写“已签名”，也不应把 Apple 公证通过写成“所有权限无需授权”。

上传完成后重新下载 Release 附件并独立计算 SHA-256，与本地最终文件和 `SHA256SUMS` 一致；再据实际结果更新中英文 README、更新记录和 Issue #7。未完成的验收保持未勾选，Issue 不应仅因新增脚本而标为全部解决。正式公开前记录原生构建、打包及最终 Release/tag 的各自提交和差异。后续仅变更测试或文档时，核对实际构建与打包输入未变，并保留差异记录及最终产物 SHA-256；实际输入改变时，重新完成对应构建、公证与验证。

<!-- release-verification:v1.1.1:start -->
## 1.1.1 发行验证记录

- 发行日期：2026-11-01；构建号：12；团队：`UBS9FUBNFR`。
- 原生构建源码：`9353aca`；打包源码：`976aac9`。
- 最终 tag 与提交关系：[v1.1.1](https://github.com/jiaqianjing/xiaopen-mac/releases/tag/v1.1.1)；完整来源及验收记录：[verification.json](https://github.com/jiaqianjing/xiaopen-mac/releases/download/v1.1.1/verification.json)。
- 应用公证：`055dfa3d-fe79-4cf7-844c-a4c035a5da5f` / `Accepted`；最终 DMG：`d27371ac-833e-417a-8ba5-977400bdcb1c` / `Accepted`。
- SHA-256：`0af4af5e902643d69e3a3ecd94d5e3c3de05da841507c8d0664ea2783a7b3552`。

- Host 已有使用历史的 Mac：Chrome 下载的最终 DMG 校验一致，Finder 安装及正常首次打开保留 quarantine。用户确认 Qwen3-TTS/Serena 试听清楚，“唤醒后停顿再问”和“唤醒词与问题连续说”两组均成功并听到回复；使用本机识别和本地提醒查询。
- Guest 全新 Apple Silicon VM 在线首次打开：Safari 下载最终 DMG 与 SHA256SUMS，哈希一致并保留 quarantine，Gatekeeper/SIP 开启。实际安装为 Finder 从挂载 DMG 复制/粘贴到 Applications；失败的远程拖动未计为安装。普通“文件 → 打开”后出现 Apple 已检查、未发现恶意软件的正常确认及真实欢迎界面，未使用上下文菜单“打开”或“仍要打开”。
- Guest 另一份在首次挂载、安装或评估前复制的干净 VM 分支：隔离外网后，最终已附票据安装包的离线首次普通打开及真实应用界面已验证。该结论只覆盖离线安装放行和启动，不表示在线模型或云端识别离线可用。
- Guest 权限流程：真实拒绝麦克风与语音识别后，经系统隐私设置恢复，在正常应用中重新检测并读回两项授权均通过；关于页版本为 1.1.1（12）。此项是权限状态验收。
- Host 真实升级：运行 1.1.0（11）创建未来提醒，再以同一最终 DMG 原位替换为 1.1.1（12）。新版保留并列出非空提醒、旧大脑/模型与 Serena 模型就绪；正常大脑页恢复已有 ChatGPT 登录并通过服务/所选模型检查，无重新登录或凭据输入。测试后恢复日常应用、数据和偏好并移除测试提醒；钥匙串未导出、删除或回滚。
- Host 用户确认：提醒查询回答后，在追问窗口内不重复唤醒词询问当前音量，成功收到回复。
- Host 用户确认：在设置中手动选择系统语音后，实际听到正常试听。此项不代表 Qwen3-TTS 自动回退到系统语音。
- Host 用户确认：全局快捷键 ⌥⌘K 停止试听，随后重播恢复。该结果覆盖快捷键停止与重播，不声称验证了自然语音打断。

| Check | Status |
| --- | --- |
| 全新 Apple Silicon VM 在线安装与首次打开 / Fresh Apple Silicon VM online installation and first launch | 已验证 / Verified |
| 另一份未使用的干净 VM 分支离线首次打开 / Offline first launch on the separate unused clean VM branch | 已验证 / Verified |
| 真实 1.1.0→1.1.1 升级保留设置与非空提醒 / Actual 1.1.0→1.1.1 upgrade preserving settings and a non-empty reminder | 已验证 / Verified |
| 正常应用复用已有认证及服务/所选模型检查 / Existing credentials reused by the normal app with service/selected-model check | 已验证 / Verified |
| 麦克风与语音识别拒绝后的授权恢复 / Microphone and speech-recognition denial/recovery | 已验证 / Verified |
| 应用读回麦克风与语音识别授权状态 / App readback of microphone and speech-recognition authorization | 已验证 / Verified |
| 不重复唤醒词的追问及实际回复 / Follow-up without repeating the wake phrase and an actual reply | 已验证 / Verified |
| 手动选择系统语音后的播放听感确认 / Listener confirmation after manually selecting the system voice | 已验证 / Verified |
| 全局快捷键停止试听及重播恢复的听感确认 / Listener confirmation of global-shortcut stop and replay recovery | 已验证 / Verified |

Guest VM 无音频设备，未用它验收音频采集、语音识别或播放听感；已通过的Serena 播放、唤醒、追问、系统语音试听听感、快捷键停止/重播听感来自 Host 用户确认。干净环境结果来自 Apple Silicon VM，不声称测试了实体干净 Mac。系统语音由手动选择，Qwen3-TTS 没有自动回退到系统语音；快捷键停止/重播测试不等于自然语音打断验收。正常的互联网下载确认及麦克风、语音识别、钥匙串授权仍可出现。
<!-- release-verification:v1.1.1:end -->

## Apple 参考

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Signing a Mac app for distribution](https://developer.apple.com/documentation/xcode/signing-a-mac-app-for-distribution)
