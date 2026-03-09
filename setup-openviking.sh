#!/usr/bin/env bash
# ============================================================
# setup-openviking.sh — OpenViking × OpenClaw 一键配置脚本
#
# 项目主页: https://github.com/volcengine/OpenViking
# 本脚本:   https://github.com/kite/openviking-setup
#
# 适用环境:
#   - macOS (Apple Silicon 或 Intel)
#   - Homebrew 已安装
#   - OpenClaw >= 3.0 已安装
#
# 脚本边界（你能控制什么）:
#   ✅ 脚本自动完成: venv 创建、AGFS 库编译、配置文件生成
#                   插件下载与注册、LaunchAgent 创建、Gateway 重启
#   🔑 需要你提供:  EdgeFN API Key（或任何 OpenAI 兼容服务的密钥）
#   ✋ 你的选择权:  覆盖已有配置前会询问、API 端点和模型可自定义
#
# ============================================================

set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

# ── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

ask_yn() {
  local prompt="$1" default="${2:-y}"
  while true; do
    echo -en "${YELLOW}?${RESET} $prompt [${default^^}/n] "
    read -r answer < /dev/tty
    answer="${answer:-$default}"
    case "${answer,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

# ── 路径配置（全部基于 $HOME，无硬编码）─────────────────────
VENV="$HOME/.openviking/venv"
OV_CONF="$HOME/.openviking/ov.conf"
WORKSPACE="$HOME/openviking_workspace"
PLUGIN_DIR="$HOME/.openclaw/extensions/memory-openviking"
OVCLI_CONF="$HOME/.openviking/ovcli.conf"
GATEWAY_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
OPENVIKING_REPO="$HOME/OpenViking"
LOG_DIR="$HOME/.openviking/logs"

# ── API 配置（你的选择）──────────────────────────────────────
# 默认使用 EdgeFN（白山智算），支持 BAAI/bge-m3 和 GLM-4.5V
# 可替换为任何 OpenAI 兼容服务（SiliconFlow、NVIDIA NIM 等）
API_BASE="${OPENVIKING_API_BASE:-https://api.edgefn.net/v1}"
API_KEY="${OPENVIKING_API_KEY:-}"
EMB_MODEL="${OPENVIKING_EMB_MODEL:-BAAI/bge-m3}"
VLM_MODEL="${OPENVIKING_VLM_MODEL:-GLM-4.5V}"
EMB_DIM="${OPENVIKING_EMB_DIM:-1024}"

# ── 辅助函数 ─────────────────────────────────────────────────
reinject_gateway_env() {
  # gateway install --force 会重写 plist，必须在之后重新注入 env vars
  local plist="$GATEWAY_PLIST"
  [ -f "$plist" ] || { warn "Gateway plist 不存在，跳过 env 注入"; return 0; }
  local dylib
  dylib=$(find "$OPENVIKING_REPO" -name "libagfsbinding.dylib" 2>/dev/null | head -1)
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OPENVIKING_PYTHON $VENV/bin/python3" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OPENVIKING_CONFIG_FILE $OV_CONF" "$plist" 2>/dev/null || true
  [ -n "$dylib" ] && /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:AGFS_LIB_PATH $dylib" "$plist" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  sleep 1
  launchctl load "$plist"
  success "Gateway env vars 注入完成"
}

# ── 主程序 ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  OpenViking × OpenClaw 一键配置脚本              ║${RESET}"
echo -e "${BOLD}║  原项目: github.com/volcengine/OpenViking         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# ── 前置检查 ──────────────────────────────────────────────────
info "检查前置条件..."
command -v python3 >/dev/null 2>&1 || error "找不到 python3，请先运行: brew install python@3.14"
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
  error "Python $PY_VER 不支持，需要 >= 3.10。请运行: brew install python@3.14 && export PATH=/opt/homebrew/bin:\$PATH"
fi
success "Python $PY_VER OK"
command -v openclaw >/dev/null 2>&1 || error "找不到 openclaw，请先安装 OpenClaw >= 3.0"
success "OpenClaw: $(openclaw --version 2>/dev/null | head -1 || echo 'found')"

# ── API Key 获取 ──────────────────────────────────────────────
if [ -z "$API_KEY" ]; then
  echo ""
  echo -e "${BOLD}需要一个 OpenAI 兼容的 API Key（用于 Embedding 和 VLM）${RESET}"
  echo "  推荐: EdgeFN 白山智算 https://ai.baishan.com  (支持 $EMB_MODEL + $VLM_MODEL)"
  echo "  也可: SiliconFlow / NVIDIA NIM / 其他 OpenAI 兼容服务"
  echo ""
  echo -en "${YELLOW}?${RESET} 请输入 API Key: "
  read -r API_KEY < /dev/tty
  [ -z "$API_KEY" ] && error "API Key 不能为空"
fi

echo ""
echo -e "${BOLD}配置预览:${RESET}"
echo "  API Base:       $API_BASE"
echo "  Embedding 模型: $EMB_MODEL (dim=$EMB_DIM)"
echo "  VLM 模型:       $VLM_MODEL"
echo "  venv 路径:      $VENV"
echo "  ov.conf:        $OV_CONF"
echo "  插件目录:       $PLUGIN_DIR"
echo ""

ask_yn "确认以上配置，继续安装？" y || { echo "已取消。"; exit 0; }

# ── Step 1: Python venv ───────────────────────────────────────
echo ""
info "[1/7] 创建 Python venv..."
if [ -d "$VENV" ]; then
  if ask_yn "  venv 已存在于 $VENV，跳过重建？" y; then
    success "跳过 venv 创建"
  else
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install openviking --upgrade -q
    success "venv 已重建"
  fi
else
  mkdir -p "$HOME/.openviking" "$WORKSPACE"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install openviking --upgrade -q
  success "venv 创建完成: $VENV"
fi

# ── Step 2: Go 环境 ───────────────────────────────────────────
info "[2/7] 检查 Go 环境（编译 AGFS 库需要）..."
if ! command -v go &>/dev/null; then
  info "  安装 Go..."
  brew install go
fi
success "Go: $(go version)"

# ── Step 3: AGFS 库 ───────────────────────────────────────────
info "[3/7] 构建 AGFS 库 (libagfsbinding.dylib)..."
if [ -d "$OPENVIKING_REPO" ]; then
  if ask_yn "  $OPENVIKING_REPO 已存在，跳过 clone？" y; then
    success "跳过 clone，使用现有目录"
  else
    rm -rf "$OPENVIKING_REPO"
    git clone --depth=1 https://github.com/volcengine/OpenViking.git "$OPENVIKING_REPO"
  fi
else
  git clone --depth=1 https://github.com/volcengine/OpenViking.git "$OPENVIKING_REPO"
fi
DYLIB=$(find "$OPENVIKING_REPO" -name "libagfsbinding.dylib" 2>/dev/null | head -1)
if [ -z "$DYLIB" ]; then
  info "  编译 AGFS 库（首次需要几分钟）..."
  cd "$OPENVIKING_REPO"
  "$VENV/bin/pip" install -e . -q
  DYLIB=$(find "$OPENVIKING_REPO" -name "libagfsbinding.dylib" 2>/dev/null | head -1)
fi
[ -n "$DYLIB" ] && success "AGFS 库: $DYLIB" || warn "未找到 libagfsbinding.dylib，可能需要手动编译"

# ── Step 4: ov.conf ───────────────────────────────────────────
info "[4/7] 写入 ov.conf..."
if [ -f "$OV_CONF" ]; then
  warn "  $OV_CONF 已存在"
  if ! ask_yn "  覆盖现有配置？" n; then
    success "跳过 ov.conf，保留现有配置"
  else
    _write_conf=true
  fi
else
  _write_conf=true
fi
if [ "${_write_conf:-false}" = true ]; then
  mkdir -p "$(dirname "$OV_CONF")"
  cat > "$OV_CONF" << OVEOF
{
  "storage": { "workspace": "$WORKSPACE" },
  "log": { "level": "INFO", "output": "stdout" },
  "embedding": {
    "dense": {
      "api_base": "$API_BASE",
      "api_key": "$API_KEY",
      "provider": "openai",
      "dimension": $EMB_DIM,
      "model": "$EMB_MODEL"
    },
    "max_concurrent": 10
  },
  "vlm": {
    "api_base": "$API_BASE",
    "api_key": "$API_KEY",
    "provider": "openai",
    "model": "$VLM_MODEL",
    "max_concurrent": 10
  }
}
OVEOF
  success "ov.conf 已写入: $OV_CONF"
fi

# ── Step 5: 环境变量注入 ──────────────────────────────────────
info "[5/7] 注入环境变量..."
cat > "$HOME/.openclaw/openviking.env" << ENVEOF
OPENVIKING_PYTHON="$VENV/bin/python3"
OPENVIKING_CONFIG_FILE="$OV_CONF"
ENVEOF
if [ -f "$GATEWAY_PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$GATEWAY_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OPENVIKING_PYTHON $VENV/bin/python3" "$GATEWAY_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OPENVIKING_CONFIG_FILE $OV_CONF" "$GATEWAY_PLIST" 2>/dev/null || true
  [ -n "${DYLIB:-}" ] && /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:AGFS_LIB_PATH $DYLIB" "$GATEWAY_PLIST" 2>/dev/null || true
  success "env vars 已注入 gateway plist"
fi

# ── Step 6: OpenClaw 插件 ─────────────────────────────────────
info "[6/7] 部署 OpenClaw 插件..."
mkdir -p "$PLUGIN_DIR"
cd "$PLUGIN_DIR"
BASE="https://raw.githubusercontent.com/volcengine/OpenViking/main/examples/openclaw-memory-plugin"
for f in index.ts config.ts client.ts process-manager.ts memory-ranking.ts text-utils.ts openclaw.plugin.json package.json; do
  if [ ! -f "$f" ]; then
    curl -fsSL "$BASE/$f" -o "$f" && echo "    ✓ $f" || warn "    下载失败: $f"
  else
    echo "    ↷ 已存在: $f"
  fi
done
npm install -q
openclaw config set plugins.enabled true
openclaw config set plugins.slots.memory memory-openviking
openclaw config set plugins.entries.memory-openviking.config.mode local
openclaw config set plugins.entries.memory-openviking.config.configPath "$OV_CONF"
openclaw config set plugins.entries.memory-openviking.config.targetUri "viking://user/memories"
openclaw config set plugins.entries.memory-openviking.config.autoRecall true --json
openclaw config set plugins.entries.memory-openviking.config.autoCapture true --json
openclaw config set plugins.allow '["memory-openviking"]' --json
success "OpenClaw 插件配置完成"

# ── Step 7: 重启 Gateway ──────────────────────────────────────
info "[7/7] 重启 OpenClaw Gateway..."
openclaw gateway stop 2>/dev/null || true
sleep 2
openclaw gateway install --force
# ⚠️ gateway install --force 会重写 plist，必须在之后重新注入 env vars
reinject_gateway_env

# ── ov CLI ───────────────────────────────────────────────────
info "检查 ov CLI..."
if ! command -v ov &>/dev/null; then
  info "安装 ov CLI..."
  mkdir -p "$HOME/.local/bin"
  INSTALL_DIR="$HOME/.local/bin" curl -fsSL https://raw.githubusercontent.com/volcengine/OpenViking/main/crates/ov_cli/install.sh | bash || warn "ov CLI 安装失败，可手动安装"
  export PATH="$HOME/.local/bin:$PATH"
fi

# ── ovcli.conf ───────────────────────────────────────────────
cat > "$OVCLI_CONF" << CLIEOF
{"url": "http://127.0.0.1:1933", "timeout": 60.0, "output": "table"}
CLIEOF

# ── 状态验收 ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  安装完成！以下是当前服务状态                  ${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
echo ""

echo -e "${BOLD}[健康检查]${RESET}"
sleep 3  # 等待 gateway 加载插件
HEALTH=$(curl -s http://127.0.0.1:1933/health 2>/dev/null || echo '{"status":"not running"}')
echo "  OpenViking health: $HEALTH"

if command -v ov &>/dev/null; then
  echo ""
  echo -e "${BOLD}[ov status]${RESET}"
  ov status 2>/dev/null || warn "ov status 失败，服务可能还在启动中"
  echo ""
  echo -e "${BOLD}[已处理的记忆 — viking://user/memories/]${RESET}"
  ov ls viking://user/memories/ 2>/dev/null || info "  暂无记忆（首次安装正常）"
else
  warn "ov CLI 未找到，请重启终端后运行: ov status"
fi

echo ""
echo -e "${BOLD}[Gateway 插件确认]${RESET}"
if [ -f "$HOME/.openclaw/logs/gateway.log" ]; then
  PLUGIN_LOG=$(grep "memory-openviking" "$HOME/.openclaw/logs/gateway.log" 2>/dev/null | tail -1)
  if [ -n "$PLUGIN_LOG" ]; then
    success "插件已接入: $PLUGIN_LOG"
  else
    warn "gateway.log 中未找到 memory-openviking 记录，请稍等片刻再检查"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}✅ OpenViking × OpenClaw 配置完成！${RESET}"
echo ""
echo "  下次查看状态: ov status"
echo "  搜索记忆:     ov find \"你的搜索词\""
echo "  浏览记忆:     ov ls viking://user/memories/"
echo "  查看日志:     tail -f $HOME/.openclaw/logs/gateway.log"
echo ""
