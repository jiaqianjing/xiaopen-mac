<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/assets/readme-hero.png" width="100%" alt="XiaoPen mascot beside a Mac mini, an external microphone and a speaker. Concept illustration.">
</p>

<h1 align="center">XiaoPen</h1>

<p align="center">
  <strong>Turn your Mac mini into an AI smart speaker.</strong><br>
  Choose its brain. Reuse your ChatGPT subscription. Just speak.
</p>

<p align="center">
  <a href="https://github.com/jiaqianjing/xiaopen-mac/releases"><img src="https://img.shields.io/github/v/release/jiaqianjing/xiaopen-mac?style=flat-square&amp;color=d7b996&amp;labelColor=292622" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-d7b996?style=flat-square&amp;labelColor=292622" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/chip-Apple%20Silicon-d7b996?style=flat-square&amp;labelColor=292622" alt="Apple Silicon required">
  <img src="https://img.shields.io/badge/voice-Mandarin-d7b996?style=flat-square&amp;labelColor=292622" alt="Mandarin voice workflow">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-d7b996?style=flat-square&amp;labelColor=292622" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/jiaqianjing/xiaopen-mac/releases"><strong>⬇ Download</strong></a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#choose-your-brain">Models &amp; ChatGPT</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="https://github.com/jiaqianjing/xiaopen-mac/issues">Feedback</a>
</p>

---

Give the **Mac mini you already own** a voice. XiaoPen is a native macOS app that lives in the menu bar. Connect an external microphone, install XiaoPen and set up a model. Say **“小喷小喷”** to chat, check the weather, set a reminder or change the Mac's volume, then keep the conversation going with a follow-up question.

Already have a **ChatGPT subscription**? Sign in and use your existing allowance for model replies, without a separate model API key. You can also choose a model provider, connect a compatible API or run Ollama locally.

**Language:** the current release has a Chinese interface and a Mandarin voice workflow. Other Apple Silicon Macs can use XiaoPen too.

**Cost:** XiaoPen is a free, MIT-licensed app. Third-party models and cloud speech recognition may charge separately. ChatGPT account limits apply, and its allowance does not include cloud speech-recognition charges.

## A voice companion for your home

| 🏠 Use the Mac you own | 🧠 Choose its brain |
| --- | --- |
| Turn a Mac mini with a microphone into a voice assistant for everyday questions, weather and reminders. | Use your ChatGPT subscription, model APIs, compatible endpoints or local Ollama. |
| **💬 Keep the conversation going** | **🔒 Know where your data goes** |
| Ask follow-up questions, use a global shortcut, or enable cloud-backed voice interruption. | Wake-phrase recognition runs on the Mac. Speech recognition and model replies have separate, documented data flows. |

### Try saying…

Wake XiaoPen with **“小喷小喷”** (xiǎo pēn, xiǎo pēn). You can change the wake phrase in settings.

| At home | Mandarin voice command | Meaning |
| --- | --- | --- |
| 🌦 Before heading out | “明天会下雨吗？” | Will it rain tomorrow? |
| ⏰ While cooking | “十分钟后提醒我关火” | Remind me to turn off the stove in ten minutes. |
| 💬 During a conversation | “换个更简单的说法” | Explain that more simply. |
| 🔉 When your hands are busy | “音量调到 40%” | Set the Mac's volume to 40%. |

Reminder and volume commands run locally, without a model request. Reminders survive app restarts. Weather uses Open-Meteo and can use your city automatically or a city you set yourself.

<details>
<summary><strong>More voice controls and features</strong></summary>

- **Follow-ups:** keep talking after a reply without repeating the wake phrase.
- **Voice interruption:** speaking to interrupt requires cloud speech recognition and active echo cancellation. Wake-phrase interruption works with on-device or cloud recognition. Voice wake-up must be enabled; Bluetooth microphone input disables voice interruption.
- **Global shortcut:** **⌥⌘K** starts listening, sends your question early, or interrupts a reply from any app.
- **Optional natural voice:** download Qwen3-TTS in the app (about 3.1 GB) for speech generated on the Mac's GPU.
- **Optional web search:** enable it with the Qianwen provider for questions that need current information. Provider charges may apply.
- **Response speed:** where supported, XiaoPen defaults to disabled or low-effort reasoning. Available controls depend on the provider and model.

</details>

## Quick start

**Requirements:** Apple Silicon · macOS 14 or later · Mandarin Chinese dictation resources.

### Prepare your Mac mini

| What you need | Setup |
| --- | --- |
| 🎙 **External microphone** | Mac mini has no built-in microphone. Connect a microphone recognized by macOS and select it in **System Settings → Sound → Input**. |
| 🔊 **Audio output** | Use the built-in speaker or select a connected speaker in the system's sound settings. |
| 🟢 **An awake Mac** | Keep XiaoPen running with voice wake-up enabled. While it waits for the wake phrase, XiaoPen keeps the Mac from going to sleep on its own; the display can still turn off and the screen can lock. Choosing **Sleep** manually still puts it to sleep. Pickup distance depends on the microphone, its placement and the room. |

### Install and say hello

1. Download the latest `XiaoPen-x.y.z.dmg` from [GitHub Releases](https://github.com/jiaqianjing/xiaopen-mac/releases) and drag XiaoPen into **Applications**.
2. **The current binary is not Apple-notarized.** If macOS blocks the first launch, follow the first-open guidance in **System Settings → Privacy & Security → Open Anyway**. On systems that offer it, right-click the app and choose **Open**.
3. Follow the app's onboarding for microphone and speech-recognition permissions. Enable **Mandarin Chinese (China mainland)** dictation in **System Settings → Keyboard → Dictation** so macOS can recognize the wake phrase locally.
4. [Choose a brain](#choose-your-brain), then select speech recognition in **设置 (Settings) → 通用 (General)**. Cloud recognition uses a Qianwen API key; a missing key or network failure falls back to on-device recognition.
5. Say **“小喷小喷”**, ask a question and try a follow-up. Check that both the microphone and speaker work as expected.

## Choose your brain

### ♻️ Your existing ChatGPT subscription

Open **设置 (Settings) → 大脑 (Brain)**, select **ChatGPT 订阅**, sign in and authorize it in your browser, then select a model. Replies use your existing ChatGPT allowance without a separate model API key. You need network access to OpenAI, and your account's usage limits still apply.

Speech recognition is configured separately. To use cloud recognition, first select **千问 AI 平台** in the Brain settings and save its API key, then switch back to **ChatGPT 订阅**. Recognition continues to use the saved Qianwen key and may incur separate charges. You can choose on-device recognition in General settings instead.

### ☁️ Your model provider or compatible API

Built-in entries include **Qianwen, DeepSeek, Kimi, MiniMax, Zhipu GLM, Volcengine Ark (Doubao), OpenRouter and Anthropic Claude**, alongside OpenAI-compatible and Anthropic-compatible endpoints.

Choose a provider in Brain settings, use its console link to get an API key, and enter the key and model. Fast models are useful for voice conversations; check your provider's console for its current model names. Keys are stored in the macOS Keychain.

### 🖥️ Local Ollama

Run Ollama on your Mac and prepare a model. Select the local Ollama entry in Brain settings, then configure the service address and model. Replies are generated locally; the speech-recognition choice in General settings still applies independently.

## Privacy

XiaoPen has no backend of its own and collects no analytics.

| Stage | What happens |
| --- | --- |
| **Waiting for the wake phrase** | Recognition runs on the Mac. Audio is not saved as recording files or continuously uploaded; a short buffer remains in memory for activation. |
| **After activation with cloud recognition** | Audio from about **2.5 seconds before the wake phrase** through the end of your question is sent to Qianwen. You can choose on-device recognition instead. |
| **Speaking to interrupt in cloud mode** | About **1 second of buffered audio**, plus the interruption, is sent to Qianwen to confirm you are speaking. On-device mode does not use this cloud confirmation. |
| **Generating a reply** | Transcribed text and recent conversation context go to your selected model provider; Ollama runs locally. |
| **Checking weather** | Your city or coordinates at roughly 1 km precision go to Open-Meteo. |
| **Storing data** | Conversations stay in memory and are cleared on exit, clearing or model changes. Reminders stay on the Mac. API keys and ChatGPT tokens live in the macOS Keychain. |

See the [full privacy explanation](docs/PRIVACY.md) (Chinese) for permissions and service details.

## Help make it better

Found an awkward wake-up, cut-off sentence or follow-up that did not work? [Open an issue](https://github.com/jiaqianjing/xiaopen-mac/issues) and describe your setup.

In **设置 (Settings) → 关于 (About) → 导出诊断信息… (Export diagnostics)**, you can export logs and a configuration summary without keys. Recognized text is excluded by default. If you enabled **记录识别文字 (Record recognized text)** during that run, review the export before sharing it.

## Support XiaoPen ☕

XiaoPen is a spare-time open-source project maintained by one developer. Sponsorship is optional; starring the repo, reporting issues and sharing ideas also help.

**[Sponsor on Afdian](https://afdian.com/a/kenjia)** · Monthly support is available.

<details>
<summary><strong>WeChat & Alipay</strong></summary>

<table>
  <tr>
    <td align="center"><img src="Sources/XiaoPen/Resources/SponsorWeChat.png" width="220" alt="WeChat sponsorship QR code"><br>WeChat</td>
    <td align="center"><img src="Sources/XiaoPen/Resources/SponsorAlipay.png" width="220" alt="Alipay sponsorship QR code"><br>Alipay</td>
  </tr>
</table>

The same sponsorship options are available in the app's **About → 支持小喷 (Support XiaoPen)** section.

</details>

## Build from source

```bash
swift test
./scripts/build_app.sh            # Creates build/XiaoPen-x.y.z.dmg
```

[Development guide](docs/DEVELOPMENT.md) · [Changelog](CHANGELOG.md) · [MIT License](LICENSE)

The development guide and changelog are currently in Chinese. The header artwork is a concept illustration, not an app screenshot.
