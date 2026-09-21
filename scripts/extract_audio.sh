#!/usr/bin/env bash
#
# url-to-audio —— 从视频链接提取音频的核心脚本
# 用法见 SKILL.md；本脚本封装 yt-dlp + ffmpeg 的命令规约。
#
# 关键设计：
#   - 默认输出 m4a 原样复制（零重编码，保真最优）。          [ADR-0001]
#   - 无损格式（flac/alac/wav）为显式选项；对有损源只换容器，不恢复失真。
#   - 默认读 Chrome 登录态提音质，读不到则匿名回退继续抓取。  [ADR-0002]
#   - 只提取链接所指向的那一个 P（链接自带 p=N）；-p N|all 显式指定。
#
# 兼容性：macOS 自带 bash 3.2 —— 不可用 nameref，空数组展开需用 ${a[@]+...} 特判。

set -euo pipefail

# ---------- 参数 ----------
URL=""
OUTDIR="$HOME/Desktop"            # 默认输出到桌面
OUTDIR_EXPLICIT=0                 # 用户是否显式传了 -o
FORMAT="auto"                     # auto|mp3|flac|alac|wav
BROWSER="chrome"                  # 默认读 Chrome 登录态提音质；none/空=匿名；也支持 safari|firefox 等
COOKIEFILE=""                     # 可选：Netscape 格式 cookie 文件，替代读取浏览器登录态
PAGE=""                           # 空=链接内置 p=N；N=只取第 N 个分P；all=整个合集

usage() {
  cat <<'EOF'
语法: extract_audio.sh <视频链接> [选项]

选项:
  -o <dir>      输出目录（默认 ~/Desktop；桌面被系统拦截时自动回退 ~/Downloads）
  -f <fmt>      音频格式：auto(默认,m4a原样复制)|mp3|flac|alac|wav
  -b <browser>  读取某浏览器登录 cookie 以获取更高音质（默认 chrome；none 或空串=纯匿名）
  -c <file>     指定 Netscape 格式 cookie 文件路径，替代读取浏览器登录态
  -p <N|all>    只提取第 N 个分P，或 all 提取整个合集（省略则按链接内置 p= 指向）
  -h            帮助

退出码: 0 成功 | 1 提取失败 | 2 参数不合法（含显式输出目录不可写） | 127 缺少依赖
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then echo "错误: -o 需要一个目录参数" >&2; exit 2; fi
      OUTDIR="$2"; OUTDIR_EXPLICIT=1; shift 2 ;;
    -f)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then echo "错误: -f 需要一个格式参数" >&2; exit 2; fi
      FORMAT="$2"; shift 2 ;;
    -b)
      if [[ "$#" -lt 2 ]]; then echo "错误: -b 需要一个浏览器名（纯匿名用 -b none 或 -b ''）" >&2; exit 2; fi
      BROWSER="${2:-none}"; shift 2
      [[ -z "$BROWSER" ]] && BROWSER="none" ;;   # 空串=匿名
    -c)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then echo "错误: -c 需要一个 cookie 文件路径" >&2; exit 2; fi
      COOKIEFILE="$2"; shift 2 ;;
    -p)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then echo "错误: -p 需要正整数或 all" >&2; exit 2; fi
      PAGE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "未知选项: $1" >&2; usage 2 ;;
    *)
      if [[ -z "$URL" ]]; then URL="$1"; else echo "多余参数: $1" >&2; usage 2; fi
      shift ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "错误: 缺少视频链接" >&2; usage 2
fi

# ---------- 格式校验 + 构建提取参数（先于依赖探测，参数错误优先暴露） ----------
case "$FORMAT" in
  # 源为 AAC/m4a 时 yt-dlp 只 remux（日志："file is already in target format"），零重编码
  auto) FMT_OPTS=( -x --audio-format m4a --audio-quality 0 ) ;;
  mp3)  FMT_OPTS=( -x --audio-format mp3 --audio-quality 0 ) ;;   # 0≈最高码率(VBR)
  flac|alac|wav) FMT_OPTS=( -x --audio-format "$FORMAT" ) ;;       # 对有损源只是换容器(ADR-0001)
  *) echo "不支持的格式: ${FORMAT}（应为 auto|mp3|flac|alac|wav）" >&2; exit 2 ;;
esac

# ---------- 前置探测（缺失只提示安装，不静默安装） ----------
if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "未检测到 yt-dlp。请先安装:  brew install yt-dlp   (另需 ffmpeg: brew install ffmpeg)" >&2
  exit 127
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "未检测到 ffmpeg。请先安装:  brew install ffmpeg" >&2
  exit 127
fi

# ---------- 登录态（默认读 Chrome；-c 优先；none/空=匿名） ----------
AUTH_ARGS=()
AUTH_MODE="匿名"
if [[ -n "$COOKIEFILE" ]]; then
  if [[ ! -r "$COOKIEFILE" ]]; then
    echo "错误: 无法读取 cookie 文件: $COOKIEFILE" >&2; exit 2
  fi
  AUTH_ARGS+=( --cookies "$COOKIEFILE" )
  AUTH_MODE="cookiefile:$COOKIEFILE"
elif [[ -n "$BROWSER" && "$BROWSER" != "none" ]]; then
  AUTH_ARGS+=( --cookies-from-browser "$BROWSER" )
  AUTH_MODE="browser:$BROWSER"
fi

# ---------- 分P / 合集选择 ----------
if [[ -z "$PAGE" ]]; then
  PART_OPTS=( --no-playlist )                    # 默认：只取链接指向的那一个 P
elif [[ "$PAGE" == "all" ]]; then
  PART_OPTS=( --yes-playlist )                   # 显式要求：整个合集/全部分P
else
  if [[ ! "$PAGE" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: -p 应为正整数或 all（收到: ${PAGE}）" >&2; exit 2
  fi
  # 注意：--playlist-items 与 --no-playlist 同时给会被忽略（实测退化成 P1），故此处不传 --no-playlist
  PART_OPTS=( --playlist-items "$PAGE" )
fi

# ---------- 输出目录：mkdir + 真实写入探测（TCC 拦截时回退） ----------
writable() {   # $1=目录；真写一个临时文件来探测，仅看 -w 在 TCC 下会误判为可写
  mkdir -p "$1" 2>/dev/null || return 1
  local probe
  probe="$(mktemp "$1/.u2a-write-test.XXXXXX" 2>/dev/null)" || return 1
  rm -f "$probe" 2>/dev/null || true
  return 0
}

abs_dir() { printf '%s' "$(cd "$1" && pwd)"; }   # 统一成绝对路径（-o 可能是相对路径）

unwritable_hint() {
  echo ":: 可能是 macOS TCC 隐私限制。请换目录（如 ~/Downloads），或到 系统设置>隐私与安全性>文件与文件夹 授权。" >&2
}

fallback_to_downloads() {   # 回退到 ~/Downloads 并确保可写（原因由调用方说明）
  OUTDIR="$HOME/Downloads"
  if ! writable "$OUTDIR"; then
    echo "错误: 回退目录也不可写: $OUTDIR" >&2; exit 1
  fi
  OUTDIR="$(abs_dir "$OUTDIR")"
}

if ! writable "$OUTDIR"; then
  if [[ "$OUTDIR_EXPLICIT" -eq 1 ]]; then
    echo "错误: 输出目录不可写: $OUTDIR" >&2
    unwritable_hint
    exit 2
  fi
  echo ":: 默认目录 $OUTDIR 不可写（macOS TCC 隐私限制），回退到 $HOME/Downloads"
  fallback_to_downloads
fi
OUTDIR="$(abs_dir "$OUTDIR")"

# 每次执行前重建参数（输出目录可能已变）
build_opts() {
  OPTS=( -f "ba/b" --no-progress --print "after_move:filepath"
         -o "$OUTDIR/%(title)s.%(ext)s" )
  OPTS+=( "${FMT_OPTS[@]}" )
  OPTS+=( "${PART_OPTS[@]}" )
}

DL_LOG=""
run_dl() {   # 用当前 OPTS + AUTH_ARGS 抓取；日志留在 DL_LOG 供失败时判定诱因
  local log
  log="$(mktemp)"
  DL_LOG="$log"
  yt-dlp "${OPTS[@]}" "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" "$URL" >"$log" 2>&1
}

echo "提取音轨: $URL"
echo "  -> 格式: ${FORMAT} | 输出: $OUTDIR | 登录: $AUTH_MODE"

build_opts
if ! run_dl; then
  if grep -qi "unsupported browser specified" "$DL_LOG"; then
    echo "错误: 不支持的浏览器: ${BROWSER}（可选 chrome|safari|firefox|edge|brave|chromium|opera|vivaldi|whale）" >&2
    rm -f "$DL_LOG"; exit 2
  elif grep -qi "cookie\|authentication\|login\|sign in" "$DL_LOG"; then
    # 登录态失效/不可用 → 匿名回退重试，不因登录失败而中断（ADR-0002）
    if [[ "${#AUTH_ARGS[@]}" -eq 0 ]]; then
      cat "$DL_LOG" >&2
      echo ":: 提示：登录后重试可获得更高音质。" >&2
      rm -f "$DL_LOG"; exit 1
    fi
    echo ":: 登录态($AUTH_MODE)不可用，匿名回退重试"
    AUTH_ARGS=()
    if ! run_dl; then
      cat "$DL_LOG" >&2
      echo ":: 提示：登录后重试可获得更高音质。" >&2
      rm -f "$DL_LOG"; exit 1
    fi
  elif grep -qi "operation not permitted\|permission denied\|read-only file system" "$DL_LOG"; then
    # TCC / 权限拦截；显式 -o 则如实报错，不擅自改用户指定目录
    if [[ "$OUTDIR_EXPLICIT" -eq 1 ]]; then
      echo "错误: 无法写入输出目录 $OUTDIR （被系统或权限拦截）" >&2
      unwritable_hint
      rm -f "$DL_LOG"; exit 2
    fi
    echo ":: 输出目录被系统拦截，回退到 $HOME/Downloads 重试"
    fallback_to_downloads
    build_opts
    if ! run_dl; then cat "$DL_LOG" >&2; rm -f "$DL_LOG"; exit 1; fi
  else
    cat "$DL_LOG" >&2; rm -f "$DL_LOG"; exit 1
  fi
fi

# ---------- 回传结构化结果（供 agent 复用） ----------
# 输出文件：yt-dlp 的 after_move:filepath 在日志里打印绝对路径（以输出目录开头）
FILE="$(awk -v d="$OUTDIR/" 'index($0, d) == 1 { p = $0 } END { if (p != "") print p }' "$DL_LOG")"
FILE_COUNT="$(awk -v d="$OUTDIR/" 'index($0, d) == 1 { n++ } END { print n + 0 }' "$DL_LOG")"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then FILE=""; fi

# 元数据：与下载使用同一组分P选择参数，保证 title/duration 对应实际下载的那一个 P
META_OPTS=( "${PART_OPTS[@]}" --skip-download --print "%(title)s" --print "%(duration_string)s" )
META="$(yt-dlp "${META_OPTS[@]}" "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}" "$URL" 2>/dev/null || true)"
TITLE="$(printf '%s\n' "$META" | sed -n '1p')"
DUR="$(printf '%s\n' "$META" | sed -n '2p')"
if [[ "$DUR" == "NA" ]]; then DUR=""; fi

# 源站存在更高档音轨时的提示（分辨率与音质是两个独立维度，登录/大会员才解锁更高档）
if grep -qi "premium member\|you have to become" "$DL_LOG"; then
  echo ":: 提示: 该视频存在更高音质档位，登录（或大会员）后重试可获取。"
fi
if [[ "$FILE_COUNT" -gt 1 ]]; then
  echo ":: 合集模式共提取 ${FILE_COUNT} 个文件，均已存入 $OUTDIR"
fi
rm -f "$DL_LOG"

echo ""
echo "### 提取结果 ###"
echo "outdir= $OUTDIR"
if [[ -n "$FILE" ]]; then echo "file= $FILE"; fi
echo "files= ${FILE_COUNT}"
echo "title= ${TITLE:-<unknown>}"
echo "duration= ${DUR:-<unknown>}"
echo "format= ${FORMAT/auto/m4a}"       # auto 的实际容器即 m4a
echo "### end ###"
