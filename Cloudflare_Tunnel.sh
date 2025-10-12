#!/bin/bash
# Cloudflare Tunnel 一键安装脚本（幂等 / 长期运行版）
# 适用于 Ubuntu / Debian 系统
# 作者: 胡博涵 （长期稳定 / 强安全版）
set -euo pipefail

# --- 配置 ---
CLOUD_BIN=/usr/local/bin/cloudflared
CLOUD_DIR=/root/.cloudflared
SYSTEMD_UNIT=/etc/systemd/system/cloudflared.service

# --- 日志函数 ---
log() { echo "==> $*"; }
info() { echo "ℹ️  $*"; }
warn() { echo "⚠️  $*"; }
err()  { echo "❌  $*" >&2; }

# --- 确保 root ---
if [ "$EUID" -ne 0 ]; then
  err "请使用 root 权限运行：sudo bash $0"
  exit 1
fi

# --- 安装必要包 ---
log "更新 apt 缓存并安装 curl/wget（如需）"
apt update -y >/dev/null
apt install -y curl wget >/dev/null

# --- 安装 cloudflared（仅在不存在时） ---
if [ -x "$CLOUD_BIN" ]; then
  info "检测到 cloudflared 已存在：$CLOUD_BIN"
else
  log "下载并安装 cloudflared..."
  wget -q -O "$CLOUD_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$CLOUD_BIN"
  info "cloudflared 已安装"
fi

# --- 尝试打印版本 ---
if ! $CLOUD_BIN --version >/dev/null 2>&1; then
  warn "无法执行 cloudflared --version，请检查二进制。"
else
  $CLOUD_BIN --version
fi

# --- 登录（如果未登录则 login） ---
mkdir -p "$CLOUD_DIR"
if [ -f "$CLOUD_DIR/cert.pem" ]; then
  info "检测到 Cloudflare 已登录凭证（$CLOUD_DIR/cert.pem），跳过 login 步骤"
else
  log "登录 Cloudflare 账户（会输出需要打开的链接）"
  echo "请按提示用浏览器完成登录，完成后回到终端按回车继续。"
  read -p "按 Enter 继续..."
  if ! $CLOUD_BIN tunnel login; then
    err "cloudflared tunnel login 失败，请手动运行 'cloudflared tunnel login' 并重试。"
    exit 1
  fi
fi

# --- 询问隧道名称与域名 ---
read -p "请输入隧道名称（例如 home-server）: " TUNNEL_NAME
if [ -z "$TUNNEL_NAME" ]; then
  err "隧道名称不能为空。"
  exit 1
fi
read -p "请输入要绑定的域名（例如 www.example.com）: " DOMAIN
if [ -z "$DOMAIN" ]; then
  err "域名不能为空。"
  exit 1
fi

# --- 查找或创建隧道 ---
info "查找是否已存在隧道: $TUNNEL_NAME"
UUID=$($CLOUD_BIN tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$0 ~ name {print $1; exit}')
if [ -n "$UUID" ]; then
  info "找到已存在隧道，UUID=$UUID"
else
  log "未找到同名隧道，创建中..."
  CREATE_OUT=$($CLOUD_BIN tunnel create "$TUNNEL_NAME" 2>&1) || {
    err "创建隧道失败：$CREATE_OUT"
    exit 1
  }
  UUID=$(printf "%s\n" "$CREATE_OUT" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9a-f-]{36}$/) {print $i; exit}}')
  if [ -z "$UUID" ]; then
    UUID=$($CLOUD_BIN tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$0 ~ name {print $1; exit}')
  fi
  [ -z "$UUID" ] && { err "无法获取隧道 UUID"; exit 1; }
  info "隧道创建成功，UUID=$UUID"
fi

# --- 绑定域名 ---
info "尝试为隧道绑定 DNS: $DOMAIN"
if $CLOUD_BIN tunnel route dns "$TUNNEL_NAME" "$DOMAIN" >/dev/null 2>&1; then
  info "DNS 绑定成功（或已存在）。"
else
  warn "DNS 绑定可能失败（可能已存在），继续执行。"
fi

# --- 写入 config.yml ---
CFG="$CLOUD_DIR/config.yml"
NEW_CFG=$(mktemp)
cat >"$NEW_CFG" <<EOF
tunnel: $UUID
credentials-file: $CLOUD_DIR/${UUID}.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:80
  - service: http_status:404
EOF

if [ -f "$CFG" ] && cmp -s "$CFG" "$NEW_CFG"; then
  info "config.yml 无变化，跳过写入。"
  rm -f "$NEW_CFG"
else
  log "更新配置文件：$CFG"
  [ -f "$CFG" ] && cp -a "$CFG" "$CFG.$(date +%s).bak"
  mv "$NEW_CFG" "$CFG"
fi

# --- 加强凭证权限 ---
chmod 600 "$CLOUD_DIR"/*.json "$CLOUD_DIR/config.yml" 2>/dev/null || true

# --- systemd 服务单元 ---
read -r -d '' UNIT_CONTENT <<'UNIT' || true
[Unit]
Description=Cloudflare Tunnel (安全版)
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run %s
Restart=always
RestartSec=5s
User=root
ProtectSystem=full
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

printf -v UNIT_FILLED "$UNIT_CONTENT" "$TUNNEL_NAME"

if [ -f "$SYSTEMD_UNIT" ] && printf "%s" "$UNIT_FILLED" | cmp -s - "$SYSTEMD_UNIT"; then
  info "systemd 单元无变化，跳过。"
  RELOAD=false
else
  log "更新 systemd 单元：$SYSTEMD_UNIT"
  echo "$UNIT_FILLED" >"$SYSTEMD_UNIT"
  RELOAD=true
fi

if [ "$RELOAD" = true ]; then
  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared || warn "重启 cloudflared 服务失败，请检查。"
else
  systemctl enable cloudflared >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet cloudflared; then
    systemctl start cloudflared || warn "启动 cloudflared 服务失败。"
  fi
fi

info "✅ Cloudflare Tunnel 设置完成（长期运行版）"
echo "---------------------------------------------"
echo "隧道名称: $TUNNEL_NAME"
echo "隧道 UUID: $UUID"
echo "域名: $DOMAIN"
echo "配置文件: $CFG"
echo
echo "🩵 查看实时日志: journalctl -fu cloudflared"
echo "🩵 检查状态:      systemctl status cloudflared"
echo "🩵 更新版本:      $CLOUD_BIN update"
echo "---------------------------------------------"
