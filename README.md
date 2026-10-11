# 小喷 · 住在菜单栏里的语音伙伴

<p align="center"><img src="Sources/XiaoPen/Resources/Mascot.png" width="128" alt="小喷"></p>

叫一声“小喷小喷”，就能和 Mac 聊天、查天气、定提醒、调音量。唤醒词在本机识别；叫醒后，你说的问题由千问云端识别（也可以选择完全离线的本机识别），回答由你选择的大模型生成。

## 能做什么

- **聊天问答**：内置千问 AI 平台、DeepSeek、Kimi、MiniMax、智谱 GLM、火山方舟（豆包）、OpenRouter、Anthropic Claude，也可以接任何 OpenAI 兼容或 Anthropic 兼容接口，以及本机 Ollama。默认关闭深度思考，回答更快。
- **ChatGPT 订阅**：用 ChatGPT 账号登录，直接使用你的 ChatGPT 订阅额度回答，不需要 API Key（需要能访问 openai.com）。
- **联网搜索**：使用千问 AI 平台时可开启，问新闻、比赛、行情等最新信息也能答。
- **天气**：“明天会下雨吗？”“北京后天冷不冷？” 自动定位所在城市，数据来自 Open-Meteo。
- **提醒和计时**：“十分钟后提醒我关火”“明天早上八点叫我起床”“我有哪些提醒”。在本机执行，重启后不丢。
- **系统音量**：“音量调到 40%”“静音”。在本机执行，不经过模型。
- **语音打断**：小喷说话或思考时，直接开口就能打断它、问新问题；也可以设成说唤醒词才打断（依赖回声消除，蓝牙耳机下不可用）。
- **连续对话**：回答完可以直接接着问，不用再叫唤醒词。
- **全局快捷键 ⌥⌘K**：在任何应用里开始说话、提前发送或打断回答。
- **自然语音（可选）**：在应用内下载 Qwen3-TTS 模型（约 3.1 GB），在本机 GPU 上生成更自然的朗读声音。

## 安装

要求：macOS 14 或更新，Apple 芯片（M 系列）的 Mac。

1. 从 [Releases](https://github.com/jiaqianjing/xiaopen-mac/releases) 下载最新的 `XiaoPen-x.y.z.dmg`，把小喷拖进“应用程序”。
2. 当前版本尚未经过苹果公证。首次打开时如果提示“无法验证开发者”：在“应用程序”里**右键点击小喷 → 打开 → 打开**；或在“系统设置 → 隐私与安全性”底部点击“仍要打开”。只需要一次。
3. 跟着首次使用引导完成授权、选择大模型平台并试喊一次唤醒词。

需要在“系统设置 → 键盘 → 听写”中开启普通话（中国大陆），系统才能在本机识别中文。Mac mini 等没有内置麦克风的机型需要外接麦克风。

## 获取模型 API Key

在设置 → 大脑中选择平台后，点击“在控制台获取 API Key”。推荐使用各平台的快速模型（如千问 AI 平台的 `deepseek-v4.1-flash`、DeepSeek 的 `deepseek-v4-flash`），语音对话体验更好。密钥只保存在 macOS 钥匙串中。

## 隐私

- 唤醒词在本机识别，没叫“小喷”之前的声音不会离开这台 Mac。
- 默认使用云端识别问题：叫醒后，从唤醒前约 2.5 秒开始到你说完的录音会发送到千问 AI 平台识别。可以在“设置 → 通用”改为完全离线的本机识别。
- 唤醒后识别出的**文字**会发送给你选择的模型平台，以生成回答。
- 查天气时，城市名和约 1 公里精度的坐标会发送给 Open-Meteo。
- 对话只保存在内存里，退出即清除；提醒保存在本机。

详见 [隐私说明](docs/PRIVACY.md)。

## 反馈问题

设置 → 关于 → “导出诊断信息…” 可以生成一份不含对话内容和密钥的日志，附在 [Issues](https://github.com/jiaqianjing/xiaopen-mac/issues) 里会很有帮助。

## 支持小喷

小喷是一个人业余维护的开源项目。如果它帮到了你，欢迎请作者喝杯咖啡 ☕️

- 爱发电：[afdian.com/a/kenjia](https://afdian.com/a/kenjia)（支持按月赞助）
- 微信 / 支付宝扫码：

<table>
  <tr>
    <td align="center"><img src="Sources/XiaoPen/Resources/SponsorWeChat.png" width="220" alt="微信赞赏"><br>微信</td>
    <td align="center"><img src="Sources/XiaoPen/Resources/SponsorAlipay.png" width="220" alt="支付宝赞赏"><br>支付宝</td>
  </tr>
</table>

也可以在应用的“设置 → 关于 → 支持小喷”里扫码。给项目点个 Star、提交问题和建议，同样是很大的支持。

## 开发

```bash
swift test
./scripts/build_app.sh            # 生成 build/XiaoPen-x.y.z.dmg
```

架构、打包、签名与各模块细节见 [开发说明](docs/DEVELOPMENT.md)。更新记录见 [CHANGELOG](CHANGELOG.md)。

项目采用 [MIT License](LICENSE)。
