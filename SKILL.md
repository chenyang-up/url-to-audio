---
name: url-to-audio
display_name: 视频链接转音频
display_name_en: URL to Audio
description_zh: 从视频链接（Bilibili BV 号等）提取音轨并保存成本地音频文件，默认 m4a 原样复制以保真，可显式转 mp3/flac/alac/wav。当用户给出视频链接并要求「提取音频/下载音频/转成 mp3/flac」时触发。
description_en: Extract the audio track from a video URL (Bilibili BV links and any site supported by yt-dlp) and save it as a local audio file. Defaults to a lossless-preserving m4a stream copy, with explicit mp3/flac/alac/wav conversion. Trigger when the user provides a video link and asks to extract, download, or convert its audio.
version: 1.0.0
description: 从视频链接（Bilibili BV 号等）提取音轨到本地，默认 m4a 原样复制，可选 mp3/flac/alac/wav。当用户给出视频链接并要「提取音频/转成 mp3/flac」时触发。
---

# 视频链接转音频 (url-to-audio)

从视频链接（默认以 Bilibili BV 号为第一验收目标，兼容 yt-dlp 支持的所有平台）提取音轨到本地，并回传输出路径、标题、时长等结构化信息供后续 agent 复用。

## 何时触发

- 用户给出一个**视频链接**（如 `https://www.bilibili.com/video/BVxxxx`）并要求「提取/下载音频」「转成 mp3/flac」。
- 用户手里只有链接，需要把声音存成本地文件（用于听、剪、转写等）。

## 前置依赖（缺失时提示安装，不静默安装）

- `yt-dlp`（下载+提取）：`brew install yt-dlp`
- `ffmpeg`（转码/remux）：`brew install ffmpeg`

脚本启动时会探测，缺失即打印安装提示并退出（code 127），避免 agent 擅动系统。

## 核心命令规约

不要手搓 `yt-dlp` 长参数，统一调用封装脚本（路径相对本 skill 根目录）：

```bash
scripts/extract_audio.sh <视频链接> [选项]
选项:
  -o <dir>      输出目录（默认 ~/Desktop；桌面被系统拦截时自动回退 ~/Downloads）
  -f <fmt>      格式：auto(默认,m4a原样复制) | mp3 | flac | alac | wav
  -b <browser>  读取某浏览器登录 cookie 拿更高音质（默认 chrome；none=纯匿名）
  -c <file>     Cookie 文件路径（Netscape 格式），替代读取浏览器登录态
  -p <N|all>    只提取第 N 个分P，或 all 提取整个合集（省略则按链接内置的 p=N 指向）
退出码：0 成功 | 1 提取失败 | 2 参数不合法 | 127 缺少依赖
```

### 设计决策速查

| 维度 | 规则 |
| ---- | ---- |
| 默认格式 | `m4a` 原样复制（零重编码）。源是 AAC 时 remux 即可，保真最优。**不要默认转 flac/wav。** |
| 无损格式 | 用户显式要求时才用 `-f flac/alac/wav`；对有损源只是换容器，不恢复失真（`alac` 落在 `.m4a` 容器里）。 |
| 分P | 只处理**链接指向的那一个 P**（URL 自带 `p=N`）。用户显式说「整个合集/全部P」时才传 `-p all`，说「要第 N 个」时传 `-p N`，不默认全拉。 |
| 登录态 | **默认尝试读 Chrome 登录态**提音质（读不到则匿名回退继续抓取）。其他浏览器显式传 `-b <browser>`；`-b none` 回到纯匿名；或用 `-c <cookiefile>` 传 Netscape 格式 cookie 文件。失败时提示可登录后重试。 |
| 音质档位 | 分辨率与音质是**两个独立维度**：切到 4K 不会让音轨更好；更高音质档位由登录态/大会员解锁。 |
| 文件命名 | 交给 yt-dlp（自动净化非法字符、重名加序号），不写死。 |
| 输出位置 | 默认 `~/Desktop`；脚本自动 `mkdir -p` 并**真实试写**探测 macOS TCC 写权限，**写不进自动回退 `~/Downloads`** 并明确告知实际落盘位置。可用 `-o` 显式指定（显式指定的目录写不进就直接报错，不再擅自改路径）。 |
| 进度可见性 | **静默执行**，不刷下载进度；完成才回传结果（路径/标题/时长/格式），失败给失败信息。 |

详细背景见 `references/adr-0001-default-m4a-zero-reencode.md` 与 `references/adr-0002-default-read-chrome-cookies-for-higher-audio.md`，术语定义见 `references/glossary.md`。

## 执行步骤

1. 确认依赖存在（脚本会挡）。
2. 按用户意图拼参数调用脚本：
   - 用户只给链接、没提格式 → 最大可能用默认 `m4a 原样复制`（不必纠结）。
   - 用户明确要 mp3/flac/wav → `-f <fmt>`。
   - 用户只说「要第 N 个 P」→ `-p N`；说「整个合集」→ `-p all`。
   - 用户强调音质、会员视频 → 提示脚本默认已读 Chrome 登录态；若登录信息在别的浏览器，用 `-b <browser>`。
3. 捕获脚本末尾 `### 提取结果 ###` 块，提取 `outdir / file / files / title / duration / format`。
   - `file` 是实际落盘文件的绝对路径（合集模式下为最后一个，文件总数为 `files`）。
4. 用结构化结果回复用户（音频文件实际路径、标题、时长、格式），并提示已就绪的去处（如「已存到桌面」）。

## 错误处理

- `exit 127`：依赖缺失 → 告诉用户装 `brew install yt-dlp ffmpeg` 后重试。
- `exit 2`：参数不合法（`-f m4a2`、未知选项、`-p 0x`、`-c` 指向的文件读不到、`-b` 传了 yt-dlp 不支持的浏览器、显式 `-o` 目录不可写）→ 按提示修正取值。
- yt-dlp 报错（404/需要登录/版权/地区限制）→ 如实回传原始错误；若疑似登录问题，改用 `-b` 指定正确浏览器或 `-c` 传 cookie 文件。
- 输出目录 "Operation not permitted"（macOS TCC 隐私拦截）→ 脚本会自动回退 `~/Downloads` 并告知；显式 `-o` 时报错，引导改用 `~/Downloads`，或去 系统设置>隐私与安全性>文件与文件夹 授予访问权。
- 脚本会识别「源站存在更高音质档位」并在结果前给出登录提示；这不算失败。
- 提取成功后元数据查询失败（title/duration 拿不到）→ 音频仍有效，结构化字段填 `<unknown>`，不当作失败。

## 安全与隐私

- **默认尝试读取 Chrome 登录态**（见 `references/adr-0002-*`），以换取更高音质档位；读不到会自动匿名回退继续抓取，不会因此失败。
- 读取的只是你本机浏览器的登录 cookie，仅在本机交给 yt-dlp 使用，**不外传**；想纯匿名可传 `-b none`，想换来源可传 `-b <browser>` 或 `-c <cookiefile>`。
- 不写入任何 token/账号信息到 skill 或脚本，全部走 yt-dlp 的 `--cookies-from-browser` / `--cookies`。
