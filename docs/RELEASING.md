# 正式发行 / Signed releases

维护者使用 `scripts/release.py` 把分级、测试、签名、公证、草稿上传和公开下载核验串成可恢复的会话。`prepare` 生成草稿后停在待人工验收；`confirm` 记录真实观察；只有所有必需检查有效且显式批准当前 DMG 后，`publish` 才公开发行。重跑命令不会默默公开一个待验收版本。

本地 `./scripts/build_app.sh` 仍是独立开发打包入口，可以使用 Apple Development 或 ad-hoc 签名，不执行公证。每个新正式安装包都必须经过 Developer ID Application 签名、Hardened Runtime、安全时间戳、应用与最终 DMG 公证及票据验证。分级只决定人工回归范围，不跳过这些自动门槛。

<a id="release-workflow"></a>

## 1. 日常发行流程

以下是下一版本的维护步骤；`v1.1.1` 是已发布版本的比较基准，不是让当前 1.1.1 再发布一次。先在独立工作树中更新待发版本的 `Resources/Info.plist` 版本号、构建号及 CHANGELOG，提交修改，按仓库正常流程合入 `main` 并让对应提交完成 CI，再从干净的发行工作树准备候选。CLI 不替你合并 PR；`prepare` 要求该源码提交已合入 `origin/main`，且该精确提交最新的 `ci.yml` 运行已完成并成功，发布前还会重新核对。不能用其他提交或较早成功但最新重跑未完成的 CI 结果代替。

```bash
# 只读比较已提交的变更，输出分级、理由及必需人工检查
python3 scripts/release.py plan --base v1.1.1

# 构建、测试、签名、公证并上传 draft，随后等待人工验收
python3 scripts/release.py prepare --base v1.1.1 --notary-via-xcode

# 查看当前会话、产物、尚缺检查和错误
python3 scripts/release.py status
```

`--base` 应选择当前 GitHub Latest 的已公开稳定版 tag，不能选任意旧版本或预发布；示例 `v1.1.1` 需在未来 Latest 改变时替换。`plan` 只比较本地提交；`prepare` 会核对 GitHub 基准和 tag，缺少本地 tag 时自动从 `origin` fetch，本地 tag 若与 GitHub 不一致则拒绝覆盖。如果 `plan` 因本地缺 tag 而失败，可先运行 `git fetch origin tag v1.1.1`，再重跑计划。

`prepare` 默认复用 Xcode 已登录账户；也可以显式使用 `--notary-via-xcode`。使用已有钥匙串 profile 时改为 `--notary-profile XiaoPen-notary`；自定义钥匙串可增加 `--notary-keychain /absolute/path/to/signing.keychain-db`。Xcode 路径与 profile/keychain 路径互斥，私钥访问或账户验证仍由本人处理。

需要指定证书时，`prepare` 支持 `--sign-identity ID`；需要自定义草稿说明时可传 `--notes-file FILE`，公开前自行检查说明中不含秘密或本机私有路径。

会话默认保存在 `build/releases/v<Info版本>/state.json`。`prepare`、`status`、`confirm`、`publish` 可在各自子命令后加 `--session DIR`（`plan` 没有此参数），传入会话目录而不是 `state.json` 文件；例如 `python3 scripts/release.py status --session /absolute/path/to/release-session`。以命令实际输出的草稿 URL、DMG 完整 SHA-256、模板和状态文件为准。所有新包都要通过 Swift/发行安全测试、来源提交对应 CI、签名、公证、staple、Gatekeeper/适用的 syspolicy 检查；公开发行后还必须从 GitHub 下载回读并核对 SHA-256。

从草稿 Release 用浏览器下载此包，在干净环境与实体 Mac 中完成本次分级所需检查，按 `prepare` 生成的人工模板填写实际结果，再一次导入：

```bash
python3 scripts/release.py confirm --from /absolute/path/to/release-session/manual-checks.json
python3 scripts/release.py status
```

把上例路径替换为 `prepare` 实际输出的 `manual-checks.json`；自定义目录时，`confirm` 和 `publish` 也传相同的 `--session DIR`。模板只在首次准备时生成，重跑 `prepare` 不覆盖已经填写的稿件。

模板开始时每项 `result`、`tester`、`note`、`environment` 和每个 `observed` 都为 `null`。不要批量填“通过”：逐项执行，`result` 填 `pass` 或 `fail`，记录实际测试者、说明、环境及观察值；`usedOpenAnyway` 等要求未绕过的观察值应为 `false`，下载 hash 和版本必须与本次候选一致。需要时在 `evidence` 中列本地截图或记录文件。填写模板只是记录观察，CLI 只能核对结构、文件和产物绑定，不能代替现场判断、听感，也不能把模拟结果变成真实通过。

只有状态显示全部必需检查有效后，才执行最终公开动作。把 `FULL_CURRENT_DMG_SHA256` 替换为 `status` 显示的完整当前 DMG SHA-256，不能缩写；`--approver` 填实际最终确认者：

```bash
python3 scripts/release.py publish \
  --approve-sha FULL_CURRENT_DMG_SHA256 \
  --approver "实际最终确认者"
```

`publish` 不自动合并 PR、修改应用版本或关闭 Issue。公开成功后还会下载公开资产并核验；公开下载核验失败时状态仍未完成，修复网络等问题后重跑相同命令继续核验，不重新创建 Release 或替换已公开资产。

## 2. 如何分级

分级依据基准提交到源码提交的已提交 Git 变更，由 `scripts/release_policy.py` 的明确规则计算。输出包含基准、源码提交、文件变化、理由和检查列表；重命名同时检查旧、新路径，未知路径或文件类型保守按 `full`。工作树里的未提交修改不属于这个计划，正式准备会拒绝脏工作树。

| 分级 | 适用范围 | 人工验收 |
| --- | --- | --- |
| `none` | 只修改未进入安装包的已知文档、仓库元数据或原生测试，没有新发行输入 | 不生成或发布新二进制；不意味着可以给新包跳过签名或公证 |
| `standard` | 被规则明确允许的普通产品输入；Info.plist 只改版本/构建号或等价序列化 | 干净浏览器安装、真实旧版升级保留、实体 Mac 核心语音，共 3 项 |
| `full` | 包装/发行脚本、工作流、权限或身份元数据、音频、helper、依赖、存储、系统操作、认证等敏感输入，或未知变化 | `standard` 加离线首开、拒绝授权恢复及更完整的实体语音回归，共 10 项 |

只有两个版本字段变化不会自动升级为 `full`；Info.plist 的应用身份、隐私说明或其他字段变化会。应用中随包携带的 README 是产品输入，不能因后缀是 `.md` 就当作仓库文档。可查看计划里的具体理由，不能仅凭“改动很少”自行降级。

本次引入了发行脚本和 CI 改动，因此首次使用新流程发布的新包会判为 `full`；该版本成为新的已发布基准后，再按后续实际改动计算分级。

发现实际影响范围比自动分类更大时，显式升级：

```bash
python3 scripts/release.py prepare --base v1.1.1 --tier full --notary-via-xcode
```

只允许保留或提高检测分级，不允许把 `full` 改为 `standard`。`none` 即使手动提高分级，也不会获得发布新二进制的许可；需要新包时先更新实际发行输入，再重新计划。若签名身份、外部运行条件或人工判断提示额外风险，也应选择 `full` 并保留原因。

## 3. 人工验收、产物绑定与恢复

下表是显式分级后的人工门槛。`full` 是 `standard` 的超集；不属于本次分级的检查不能写成“已通过”。所有检查都针对草稿中下载的同一候选，使用它的完整 DMG SHA-256。

| 检查 ID | 分级 | 需要真实观察的结果 |
| --- | --- | --- |
| `clean_install` | 两级必需 | 浏览器下载 hash 与候选一致；新环境；保留 quarantine；Gatekeeper/SIP 开启；普通首次打开，没有使用“仍要打开”；在关于页读回 `candidateVersion` / `candidateBuild` 与本次候选一致，防止误开旧应用 |
| `upgrade_retention` | 两级必需 | 真实运行另一旧版本后升级到候选；配置、非空提醒、模型保留；正常应用复用已有认证，不用重新登录冒充复用 |
| `voice_smoke` | 两级必需 | 实体 Mac 唤醒、提问并听到清楚的回复；测试后恢复日常设置 |
| `offline_first_launch` | `full` 追加 | 另一份此前从未安装或评估过候选的干净分支，先隔离外网，再普通首次打开；下载 hash、quarantine、安全保护仍正确 |
| `permission_recovery` | `full` 追加 | 真实拒绝麦克风和语音识别，再从系统设置恢复；应用重新检测并读回已授权，不能只看系统开关 |
| `wake_modes` | `full` 追加 | 实体 Mac 分别执行“唤醒后停顿再问”和“唤醒词与问题连续说”，两组都听到清楚回复 |
| `follow_up` | `full` 追加 | 实体 Mac 在追问窗口内不重复唤醒词，成功听到清楚回复 |
| `local_tts` | `full` 追加 | 实体 Mac 本地模型就绪并实际听到清楚播放 |
| `system_voice` | `full` 追加 | 手动选择系统语音，实际试听完整清楚；不声称 Qwen3-TTS 自动回退 |
| `shortcut_replay` | `full` 追加 | 全局快捷键中途停止播放，之后完整清楚地重播恢复；不声称自然语音打断已验收 |

干净安装与权限状态可以在满足基线的 Apple Silicon VM 中观察；声音项必须来自实体 Mac 的实际测试和听感确认。没有音频设备的 VM 不能替代音频采集、识别或播放验收。开始麦克风测试前获得本人明确同意，不清除 quarantine，不关闭 Gatekeeper/SIP，不通过“仍要打开”完成验收。正常互联网下载确认和麦克风、语音识别、钥匙串授权仍可出现。

确认绑定当前会话、源码提交、基准/分级/检查计划、自动测试与公证证据、草稿 Release 和 DMG 字节。不能复制 1.1.1 或其他候选的确认来放行新包，也不要手改模板 `binding`、候选 hash 或检查 ID 来适配另一包。产物、来源、计划或已登记证据变化时，旧确认不再有效，最终发布批准也必须与当前有效确认一致。确认引用的本地证据文件不要在发布完成前移动或修改。

人工验收发现 bug 并修改源码后，旧会话会拒绝复用。保留旧会话目录和证据；仅在确认 GitHub 同版本条目确属该会话且仍是 draft 后，才在 GitHub 移除该草稿，再以新的 `--session DIR` 重新 `prepare`。不覆盖旧目录、不修改 `binding`、不删除任何 Git tag；已有 tag 或已公开发行时，改用新版本号和构建号。源码变更后的新候选与普通网络失败、上传续传分别处理，不能用 `--retry-build` 绕过来源不一致。

需要中断时保留整个会话、产物和证据。`state.json` 已存在时，重跑相同 `prepare` 只复核并继续草稿/资产同步，不重新构建或重复公证；若来源、分级或签名选项不一致就停止。它不会因为已有部分确认而自动调用 `publish`。

如果上次构建或公证中断、尚未生成完成的 `state.json`，普通重跑会停下，避免无意重复提交。先检查保留的 Apple 提交 UUID、日志和服务端状态；超时或网络故障既不表示被拒绝，也不表示通过。确认状态后确实需要新构建尝试时，才显式增加 `--retry-build`，并保持同一会话和其余准备参数：

```bash
python3 scripts/release.py prepare --base v1.1.1 --notary-via-xcode --retry-build
```

`--retry-build` 启动新的构建/公证尝试，不是悄悄接管尚在处理的 Apple 作业，也不允许复用另一包的人工确认。已有完成状态仍走恢复路径；不要为重试直接删除会话、UUID 或原始记录。

公开 `verification.json` 只含固定范围、版本/源码/分级、产物摘要、公证及验收摘要；操作者姓名、自由备注、环境标签、本机绝对路径和任意命令输出留在本地。关键公证原始日志自动复制至会话的 `raw-notarization/`，保留完整会话即可保有这些证明；完整底层 Xcode 归档及其他原始资料仍保留在 `build/notarization/`，随包只发布白名单 Apple 日志摘录。不要把密码、token、cookie、私有签名下载 URL 或钥匙串材料填进模板或发行附件。

## 4. 发行环境与身份

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

## 5. 底层构建与公证

日常发行优先使用上面的会话入口。直接调用 `build_app.sh --release` 只负责产物与发行验证，不完成分级人工确认或 GitHub 发布；不要据此把会话标为已发布。以下保留独立构建及排障步骤。

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

## 6. 公证与签名原始记录

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

## 7. 可选的长期干净测试模板

可在外部 QA 流程中预置没有 XiaoPen、偏好或历史放行记录的干净 Apple Silicon VM 模板，每次从该基线复制测试分支；`full` 的在线与离线分支应在任何候选首次挂载或评估前分开，保留基线和网络隔离证据。模板不应带有已有 XiaoPen 账号、偏好或放行记录；为本次验收下载的候选可在首次打开前显式保留并记录 hash，再从该未评估状态分出在线和离线分支。

这只是可选的长期 QA 组织方式，当前 CLI 不安装或创建 VM、VNC，不保存 Guest 密码，也不自动听声音。使用外部 VM 或工具仍按当次授权操作；人的权限确认和听感不能由 CLI 模拟。模板能减少环境准备，不会免除本次分级的检查或允许复用旧候选的通过记录。

公开前后记录原生构建、打包及最终 Release/tag 的各自提交和差异。后续仅变更测试或文档时，核对实际构建与打包输入未变，并保留差异记录及最终产物 SHA-256；实际输入改变时，重新完成对应构建、公证与验证。公开状态与本地记录分别读取，未核验的公开下载不能记为发行完成。

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
