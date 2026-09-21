#!/usr/bin/env bash
#
# url-to-audio —— 从视频链接提取音频的核心脚本
# 用法见 SKILL.md；本脚本封装 yt-dlp + ffmpeg 的命令规约。
#
# 关键设计（见 references/adr-0001-default-m4a-zero-reencode.md）：
#   - 默认输出 m4a 原样复制（零重编码，保真最优）。
#   - 无损格式（flac/alac/wav）为显式选项；对有损源只改变容器，不恢复失真。
#   - 只提取链接所指向的那一个 P（链接自带 p=N）。
#   - 默认匿名抓取；仅当显式传 --browser 才读取登录 cookie。

set -euo pipefail

# ---------- 参数 ----------
URL=""
OUTDIR="$HOME/Desktop"            # 默认输出到桌面
FORMAT="auto"                     # auto|mp3|flac|alac|wav
BROWSER="chrome"                  # 默认读 Chrome 登录态提音质；可选 safari|firefox 等；空=匿名
COOKIEFILE=""                     # 可选：Netscape 格式 cookie 文件，替代读取浏览器登录态
PAGE=""

usage() {
  cat <<'EOF'
语法: extract_audio.sh <视频链接> [选项]

选项:
  -o <dir>      输出目录（默认 ~/Desktop；写不进自动回退 ~/Downloads）
  -f <fmt>      音频格式：auto(默认,m4a原样复制)|mp3|flac|alac|wav
  -b <browser>  读取某浏览器登录 cookie 以获取更高音质（默认 chrome；chrome|safari|firefox 等）
  -c <file>     指定 Netscape 格式 cookie 文件路径，替代读取浏览器登录态
  -p <N>        只提取第 N 个分P（省略则按链接内置的 p= 指向）
  -h            帮助
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -f) FORMAT="$2"; shift 2 ;;
    -b) BROWSER="$2"; shift 2 ;;
    -c) COOKIEFILE="$2"; shift 2 ;;
    -p) PAGE="$2"; shift 2 ;;
    -h) usage ;;
    -*)
      echo "未知选项: $1" >&2; usage ;;
    *)
      if [[ -z "$URL" ]]; then URL="$1"; else echo "多余参数: $1" >&2; usage; fi
      shift ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "错误: 缺少视频链接" >&2; usage
fi

# ---------- 前置探测 ----------
if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "未检测到 yt-dlp。请先安装:  brew install yt-dlp   (需 ffmpeg: brew install ffmpeg)" >&2
  exit 127
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "未检测到 ffmpeg。请先安装:  brew install ffmpeg" >&2
  exit 127
fi

# ---------- 组装 yt-dlp 参数 ----------
# 输出目录：默认桌面；中度 TCC 拦截时自动回退 ~/Downloads（见 SKILL.md 输出位置决策）
mkdir -p "$OUTDIR" 2>/dev/null || true
if [[ ! -w "$OUTDIR" ]]; then
  OUTDIR="$HOME/Downloads"
  mkdir -p "$OUTDIR" 2>/dev/null || true
fi

# 输出文件名模板：默认用净化后的视频标题。yt-dlp 自动做平台兼容的文件名净化；
# 重名时输出到同目录会让 yt-dlp 追加序号，无需在此额外处理。
YT_OPTS=()

# 通用
YT_OPTS+=( -f "ba/b" )              # 最佳音轨；取不到纯音轨再取含音的视频流
YT_OPTS+=( --no-playlist )          # 不因链接误入播放列表/合集
YT_OPTS+=( -x )                     # 提取音频
YT_OPTS+=( -o "$OUTDIR/%(title)s.%(ext)s" )
YT_OPTS+=( --no-progress )          # 静默执行，不刷下载进度

# 登录态：优先用指定 cookie 文件；否则默认读 Chrome（或其他浏览器）登录态提音质。
# 若失败，重试时以匿名回退，不因登录失败而中断。
COOKIE_AUTH=()
AUTH_MODE="匿名"
if [[ -n "$COOKIEFILE" ]]; then
  COOKIE_AUTH+=( --cookies-from-browser "$BROWSER" )
  COOKIE_AUTH+=( --cookies "$COOKIEFILE" )
  AUTH_MODE="cookiefile:$COOKIEFILE"
elif [[ -n "$BROWSER" ]]; then
  COOKIE_AUTH+=( --cookies-from-browser "$BROWSER" )
  AUTH_MODE="browser:$BROWSER"
fi

# 分P（可选；省略即按链接内置 p=N 指向）
if [[ -n "$PAGE" ]]; then
  YT_OPTS+=( --playlist-items "$PAGE" )
fi

# 格式与保真策略
case "$FORMAT" in
  auto)
    # 默认：m4a 原样复制（零重编码；源已是 AAC 时 yt-dlp 只 remux，不做二次编码）
    YT_OPTS+=( --audio-format m4a --audio-quality 0 )
    ;;
  mp3|flac|alac|wav)
    # 显式转码到目标格式（无损格式对有损源只是换容器，见 ADR-0001）
    YT_OPTS+=( --audio-format "$FORMAT" )
    [[ "$FORMAT" == "mp3" ]] && YT_OPTS+=( --audio-quality 0 )   # 0≈最高码率(VBR)
    ;;
  *)
    echo "不支持的格式: $FORMAT（应为 auto|mp3|flac|alac|wav）" >&2; exit 2 ;;
esac

# ---------- 执行 ----------
echo "提取音轨: $URL"
echo "  -> 格式: ${FORMAT} | 输出: $OUTDIR | 登录: $AUTH_MODE"

run_dl() {  # $1 = auth args array name to append
  local -n _auth="$1"
  local log; log="$(mktemp)"
  if yt-dlp "${YT_OPTS[@]}" "${_auth[@]}" "$URL" >"$log" 2>&1; then
    rm -f "$log"; return 0
  fi
  cp "$log" "$DL_LAST_LOG"; rm -f "$log"; return 1
}

DL_LAST_LOG="$(mktemp)"
NOAUTH=()

# 第一遍：带登录态（默认 Chrome cookie）
if ! run_dl COOKIE_AUTH; then
  # 失败诱因判定：登录/cookie 相关，或输出目录无权限
  if grep -qi "operation not permitted\|permission denied" "$DL_LAST_LOG"; then
    # TCC 拦截：回退到 ~/Downloads 再匿名重试一次
    OUTDIR="$HOME/Downloads"; mkdir -p "$OUTDIR" 2>/dev/null || true
    YT_OPTS+=( -o "$OUTDIR/%(title)s.%(ext)s" )
    echo ":: 桌面写入被拦截，已回退输出到 $OUTDIR"
    if ! run_dl COOKIE_AUTH; then
      cat "$DL_LAST_LOG" >&2; rm -f "$DL_LAST_LOG"; exit 1
    fi
  elif grep -qi "cookie\|authentication\|login\|--cookies" "$DL_LAST_LOG"; then
    # 登录态失效/不可用 → 匿名回退重试
    echo ":: 登录态($AUTH_MODE)不可用，匿名回退重试"
    if ! run_dl NOAUTH; then
      cat "$DL_LAST_LOG" >&2
      echo ":: 提示：登录后重试可获得更高音质。" >&2
      rm -f "$DL_LAST_LOG"; exit 1
    fi
  else
    cat "$DL_LAST_LOG" >&2; rm -f "$DL_LAST_LOG"; exit 1
  fi
fi
rm -f "$DL_LAST_LOG"

# ---------- 回传结构化结果 ----------
# 解析元数据供 agent 复用：目录、标题、时长(yt-dlp 原生格式，可能为 4:09 或秒)。非致命失败不打断。
DUR="$(yt-dlp --no-playlist --get-duration "$URL" 2>/dev/null || true)"
TITLE="$(yt-dlp --no-playlist --get-title "$URL" 2>/dev/null || true)"
echo ""
echo "### 提取结果 ###"
echo "outdir= $OUTDIR"
echo "title= ${TITLE:-<unknown>}"
[[ -n "${DUR:-}" && "$DUR" != "NA" ]] && echo "duration= $DUR"
echo "format= $FORMAT"
echo "### end ###"
