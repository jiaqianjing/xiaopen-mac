# 本机语音方案（2026-10-09）

目标是中文桌面语音对话，优先自然的表达、本机可运行和流式出声。当前选择 Qwen3-TTS-12Hz-1.7B-CustomVoice 的 MLX 8-bit 转换，模型及音频 codec 合计 3,075,602,023 字节，连同配置约 3.08GB。支持中文预设声音及自然语言语气控制。权重遵循 Apache-2.0；推理使用 MLX Audio Swift。

模型保存在用户的 Application Support 中，安装包只包含原生 Swift 推理组件。加载使用本机文件，推理期间不访问 Hugging Face 或千问语音接口。助手回答仍由用户选择的文本模型生成；麦克风转写仍是 Apple 本机识别。

## 选型依据

| 模型 | 适配与取舍 |
| --- | --- |
| Qwen3-TTS 1.7B CustomVoice | 中文、9 种预设音色、语气指令、MLX/Swift 流式实现；先实测再用于此 Mac |
| Qwen3-TTS 0.6B | 8-bit 约 1.97GB，但官方模型表未提供语气指令控制，作为性能备用 |
| CosyVoice3 | 中文及方言能力强，参考音频与推理集成比 CustomVoice 更复杂 |
| Fish Audio S2 Pro | MLX 8-bit 约 6.72GB，16GB 常驻更吃紧，Research License 需单独评估 |
| VoxCPM2 | 高质量、多语种、48kHz、已有 MLX 移植，值得后续同文听感比较 |

不存在覆盖所有音色、语言及设备的唯一 SOTA 结论。这里选的是有公开先进能力、同时适合本应用条件的候选。官方的 97ms 低延迟来自其测试环境，不代表此 Mac 的运行结果；中文自然度仍需用户试听。

## 固定模型与安全安装

- HF 仓库：`mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`
- 固定版本：`41d3337e8b7f2843a75841595fc14e4b9a7a4b96`
- 发布文件摘要：`model-manifest.json`，来自上述固定版本 HF API 的文件元数据。
- 大文件验证 SHA-256，配置文件验证 Git blob SHA-1；任何来源下载都以此为准。
- 未完成下载以临时文件保存，校验成功后才移动到推理组件读取的位置。
- 原生依赖锁定在 Package.swift / Package.resolved；开发环境需要 Xcode Metal Toolchain，安装好的应用自带编译结果，用户无需安装该工具链。

## 此 Mac 实测

Apple M6、16GB 内存，Serena 固定中文短句，24kHz 单声道，0.32 秒音频块，原生 Swift 推理：

| 运行 | 首段音频 | 完整生成 | 生成音频长度 |
| --- | ---: | ---: | ---: |
| 首次冷运行 | 11.957 秒 | 15.819 秒 | 5.76 秒 |
| 热身后 1 | 0.322 秒 | 3.547 秒 | 4.72 秒 |
| 热身后 2 | 0.304 秒 | 3.458 秒 | 5.12 秒 |

模型加载 3.860 秒，MLX 内存峰值 3.724GB。热身后的生成速度快于播放速度。首次加载及 GPU 准备较慢，因此组件在 `ready` 前静默合成固定短句，启动时后台准备；打断后的替换组件也重新准备。以上不含麦克风断句、回答模型接口时间或音频输出硬件延迟，也不是语音唤醒端到端验收。

WAV 检查：所有样本有限、非静音、无削波，峰值 0.33–0.45。客观信号检查不能代替中文发音和自然度试听。原始测试记录与 WAV 位于 `build/local-tts-probe/results/`。

### 安装包与应用验证

XiaoPen 1.0.5（build 6）已安装到 `/Applications/XiaoPen.app`，沿用旧版 Apple Development 指定要求，应用与 helper 的 deep/strict 签名验证通过，DMG 校验通过。模型文件以固定 HF 版本的摘要校验完成，106 项 Release 测试通过。

安装包内 helper 的准备过程含静默预热，实测 12.59 秒；连续两次请求首段音频分别为 0.267 和 0.188 秒，总生成分别为 2.16 和 1.83 秒，对应音频长度 3.28 和 3.68 秒。正常 EOF 退出为 0。记录在 `build/speech-worker-validation/benchmark.json`。

正式应用默认启用了本机 Qwen3-TTS、Serena 和自然轻松的中文语气。设置页面显示模型已就绪；连续试听、试听结束恢复待命、生成期间打断和打断后重新试听均通过 UI 与进程检查。三次完成试听的开始朗读日志为提交后 1.13、0.85、0.85 秒，包含应用调度与播放准备。退出应用后未残留推理组件；重新启动后仅运行一个组件。

试听时系统未检测到麦克风输入设备；最终重启后已启动本机中文识别，并收到 48kHz 单声道音频 buffer。真实说话唤醒和完整语音对话尚未验收，也未以这些信号检查代替用户听感评价。应用日志在 `build/installed-voice-validation.log` 与 `build/installed-voice-relaunch.log`。

## 运行与打断

模型在独立的原生进程中保持就绪，同一时间只处理一个语音段。App 通过私有管道传递文本和 24kHz Float32 音频，不开放网络端口。管道输出有长度、采样率及有限数值校验，不记录语音或转写内容。

音频分块播放，等生成结束且最后一块真实播完后才结束语音会话。新会话、打断或音频输出设备变化会使旧 token 失效并停止旧推理组件；迟到回调不能影响新会话。生成或播放失败显示提示，保留模型的文字回答，待文字生成结束后恢复待命。组件退出、加载超时和生成无响应都有明确的恢复路径。

## 来源

- [Qwen 官方模型说明与声音列表](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
- [Qwen 技术报告](https://arxiv.org/abs/2601.15621)
- [MLX 8-bit 权重](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit)
- [MLX Audio Swift 的 Qwen3-TTS 实现](https://github.com/Blaizzy/mlx-audio-swift/tree/dbe5eaac964e8257785f9d015c81f819a38016a8/Sources/MLXAudioTTS/Models/Qwen3TTS)
- [CosyVoice3](https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512)
- [Fish S2 Pro](https://huggingface.co/fishaudio/s2-pro)
- [VoxCPM2](https://huggingface.co/openbmb/VoxCPM2)
