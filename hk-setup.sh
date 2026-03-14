#!/usr/bin/env bash
# =============================================================================
#  hk-setup.sh  —  香港中转节点一键运维脚本
#  版本：v1.0
#  用法：sudo bash hk-setup.sh
#  模式：1) 全新安装  2) 备份  3) 恢复
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 固定常量 ──────────────────────────────────────────────────────────────────
readonly PANEL_DOMAIN="panel.flytoex.net"
readonly PANEL_APIKEY="flyto20221227.com"
readonly WG_CONF="/etc/wireguard/wg0.conf"
readonly V2BX_CONF="/etc/V2bX/config.yml"
readonly SING_CONF="/etc/V2bX/sing_origin.json"
readonly PANEL_IP_FILE="/etc/hk-setup/panel_ip"
readonly UPDATE_PANEL_SCRIPT="/usr/local/bin/update-panel-route.sh"

# ── 全局变量（各函数间共享）──────────────────────────────────────────────────
HK_PUB_IP=""
HK_GW=""
HK_WAN_IF=""
HK_WG_PRIV=""
HK_WG_ADDR=""
US_WG_PUBKEY=""
US_WG_ENDPOINT=""
US_WG_ADDR=""
WG_KEEPALIVE="25"
NODE_ID=""
PANEL_IP=""

# =============================================================================
#  工具函数
# =============================================================================

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
success() { echo -e "  ${GREEN}✓${NC}  $*"; }
fail_msg(){ echo -e "  ${RED}✗${NC}  $*"; }

confirm() {
  local msg="$1"
  local ans
  while true; do
    read -rp "$(echo -e "  ${YELLOW}[?]${NC} ${msg} [y/n]: ")" ans
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "    请输入 y 或 n" ;;
    esac
  done
}

# 读取用户输入，支持默认值
# 用法：read_input "提示文字" 变量名 [默认值]
read_input() {
  local label="$1"
  local var_name="$2"
  local default="${3:-}"
  local value=""

  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$(echo -e "  ${CYAN}›${NC} ${label} [${YELLOW}${default}${NC}]: ")" value
      value="${value:-$default}"
    else
      read -rp "$(echo -e "  ${CYAN}›${NC} ${label}: ")" value
    fi
    if [[ -n "$value" ]]; then
      break
    fi
    warn "不能为空，请重新输入"
  done
  printf -v "$var_name" '%s' "$value"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "此脚本必须以 root 身份运行"
    error "请执行：sudo bash $0"
    exit 1
  fi
}

check_debian() {
  if ! grep -qi 'debian' /etc/os-release 2>/dev/null; then
    warn "当前系统可能不是 Debian，脚本针对 Debian 12 优化，其他系统可能存在问题"
    confirm "是否继续？" || exit 0
  fi
}

# =============================================================================
#  主菜单
# =============================================================================

show_menu() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║        香港中转节点  运维脚本  v1.0                  ║"
  echo "  ║        HK Transit Node  Setup Script                ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  请选择运行模式："
  echo ""
  echo -e "  ${BOLD}1)${NC}  全新安装   — 从零配置一台新的香港节点"
  echo -e "  ${BOLD}2)${NC}  备份模式   — 重装系统前，提取并保存当前 WG 配置"
  echo -e "  ${BOLD}3)${NC}  恢复模式   — 重装系统后，用备份信息完整恢复"
  echo ""
  echo -e "  ${BOLD}q)${NC}  退出"
  echo ""
}

# =============================================================================
#  MODE 2：备份模式
# =============================================================================

mode_backup() {
  header "备份模式：提取当前 WireGuard 配置"

  # 检查前提条件
  if ! command -v wg &>/dev/null; then
    error "未检测到 wireguard-tools"
    error "当前系统可能尚未安装 WireGuard，无需备份，直接运行「全新安装」"
    exit 1
  fi

  if [[ ! -f "$WG_CONF" ]]; then
    error "未找到 ${WG_CONF}"
    error "WireGuard 配置文件不存在，无需备份，直接运行「全新安装」"
    exit 1
  fi

  info "正在从 ${WG_CONF} 提取配置..."

  # 从 wg0.conf 提取字段（容错：字段不存在时返回空）
  local priv_key addr peer_pubkey endpoint allowed_ips keepalive
  priv_key=$(  grep -E '^\s*PrivateKey'          "$WG_CONF" | awk '{print $NF}' || echo "")
  addr=$(      grep -E '^\s*Address'              "$WG_CONF" | awk '{print $NF}' || echo "")
  peer_pubkey=$(grep -E '^\s*PublicKey'           "$WG_CONF" | awk '{print $NF}' || echo "")
  endpoint=$(  grep -E '^\s*Endpoint'             "$WG_CONF" | awk '{print $NF}' || echo "")
  allowed_ips=$(grep -E '^\s*AllowedIPs'          "$WG_CONF" | awk '{print $NF}' || echo "")
  keepalive=$( grep -E '^\s*PersistentKeepalive'  "$WG_CONF" | awk '{print $NF}' || echo "25")

  # 推导本机公钥（需要私钥非空）
  local pub_key="（无法推导，请手动记录）"
  if [[ -n "$priv_key" ]]; then
    pub_key=$(echo "$priv_key" | wg pubkey 2>/dev/null || echo "（推导失败）")
  fi

  # 自动检测网络信息
  local wan_if hk_gw hk_pub_ip
  wan_if=$(    ip route show default | awk '/default/ {print $5}' | head -1 || echo "（未检测到）")
  hk_gw=$(     ip route show default | awk '/default/ {print $3}' | head -1 || echo "（未检测到）")
  hk_pub_ip=$( curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null        || echo "（获取失败，请手动填写）")

  # ── 输出备份信息 ──────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${YELLOW}  ┌─────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${YELLOW}  │            请完整复制以下内容，保存到安全位置                  │${NC}"
  echo -e "${BOLD}${YELLOW}  │            重装系统后「恢复模式」需要用到这些值                │${NC}"
  echo -e "${BOLD}${YELLOW}  └─────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo "# ───────────────── WireGuard 备份信息 ─────────────────"
  echo "HK_PRIV_KEY=${priv_key}"
  echo "HK_PUB_KEY=${pub_key}"
  echo "HK_WG_ADDR=${addr}"
  echo "HK_WG_PEER_PUBKEY=${peer_pubkey}"
  echo "HK_WG_ENDPOINT=${endpoint}"
  echo "HK_WG_ALLOWED_IPS=${allowed_ips}"
  echo "HK_WG_KEEPALIVE=${keepalive}"
  echo ""
  echo "# ───────────────── 网络信息 ────────────────────────────"
  echo "HK_WAN_IF=${wan_if}"
  echo "HK_GW=${hk_gw}"
  echo "HK_PUB_IP=${hk_pub_ip}"
  echo "# ────────────────────────────────────────────────────────"
  echo ""

  warn "私钥（HK_PRIV_KEY）极度敏感，请勿通过聊天/邮件/截图传输"
  warn "建议保存在本地加密文档中（如 KeePass、1Password 等）"
  echo ""

  confirm "已确认复制并安全保存以上信息？" || { warn "请先保存备份信息再退出"; exit 0; }

  echo ""
  echo -e "${BOLD}下一步操作：${NC}"
  echo "  1. 重装服务器系统（推荐 Debian 12）"
  echo "  2. 重装完成后，将此脚本上传到新系统"
  echo "  3. 执行：sudo bash hk-setup.sh"
  echo "  4. 选择「3) 恢复模式」，粘贴刚才保存的备份值"
  echo ""
  info "备份完成，退出。"
}

# =============================================================================
#  公共步骤：基础系统配置
# =============================================================================

step_base_system() {
  header "步骤 1/5：基础系统配置"

  info "更新系统软件包..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq full-upgrade
  success "系统已更新"

  info "安装依赖包..."
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
    vim curl wget ca-certificates gnupg lsb-release \
    jq unzip zip tar net-tools cron \
    wireguard-tools nftables iproute2 iptables \
    tcpdump dnsutils ipset iptables-persistent
  success "依赖包安装完成"

  info "禁用 IPv6（防 IPv6 泄露）..."
  cat > /etc/sysctl.d/99-no-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system -q
  success "IPv6 已禁用"

  info "开启 IPv4 转发..."
  cat > /etc/sysctl.d/99-forward.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system -q
  success "IPv4 转发已开启"

  info "配置 IPv4 优先（/etc/gai.conf）..."
  grep -q 'ffff:0:0/96' /etc/gai.conf 2>/dev/null || \
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

  info "禁用 systemd-resolved，锁定 resolv.conf（防 DNS 泄露）..."
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved --quiet
  fi
  # 解除可能存在的 symlink
  rm -f /etc/resolv.conf
  cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate
EOF
  # 解锁（防止已经 chattr +i）再加锁
  chattr -i /etc/resolv.conf 2>/dev/null || true
  chattr +i /etc/resolv.conf
  success "resolv.conf 已锁定（chattr +i）"

  info "启用 nftables..."
  systemctl enable --quiet nftables
  systemctl start nftables
  success "nftables 已启用"

  echo ""
  success "基础系统配置完成"
}

# =============================================================================
#  公共步骤：收集网络信息
# =============================================================================

step_collect_network() {
  header "步骤 2/5：网络信息"

  # 自动检测
  local auto_wan_if auto_hk_gw auto_hk_pub_ip
  auto_wan_if=$(   ip route show default | awk '/default/ {print $5}' | head -1 || echo "")
  auto_hk_gw=$(    ip route show default | awk '/default/ {print $3}' | head -1 || echo "")
  auto_hk_pub_ip=$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null      || echo "")

  info "自动检测结果："
  echo "    公网网卡 : ${auto_wan_if:-未检测到}"
  echo "    默认网关 : ${auto_hk_gw:-未检测到}"
  echo "    公网 IP  : ${auto_hk_pub_ip:-未检测到}"
  echo ""
  info "请确认或修改（直接回车接受自动检测值）："
  echo ""

  read_input "公网网卡名（如 eth0 / ens3 / ens5）" HK_WAN_IF "$auto_wan_if"
  read_input "默认网关 IP" HK_GW "$auto_hk_gw"
  read_input "本机公网 IP（香港节点）" HK_PUB_IP "$auto_hk_pub_ip"

  echo ""
  info "确认填写的值："
  echo "    HK_WAN_IF = ${HK_WAN_IF}"
  echo "    HK_GW     = ${HK_GW}"
  echo "    HK_PUB_IP = ${HK_PUB_IP}"
  echo ""
  confirm "以上信息是否正确？" || step_collect_network
}

# =============================================================================
#  公共步骤：收集 WireGuard 配置（全新安装）
# =============================================================================

step_collect_wg_fresh() {
  header "步骤 3/5：WireGuard 配置（全新安装）"

  echo "  请准备以下信息（在美国节点执行 wg show 获取）："
  echo ""

  read_input "香港节点 WG 私钥（PrivateKey，可在美国机新建 peer 时生成）" HK_WG_PRIV
  read_input "香港节点 WG 隧道地址（如 10.0.0.3/32）" HK_WG_ADDR
  read_input "美国节点 WG 公钥（Peer PublicKey）" US_WG_PUBKEY
  read_input "美国节点 WG Endpoint（格式：IP:端口，如 5.6.7.8:51820）" US_WG_ENDPOINT
  read_input "美国节点 WG 隧道内 IP（如 10.0.0.1/32）" US_WG_ADDR "10.0.0.1/32"
  read_input "PersistentKeepalive（秒，建议 25）" WG_KEEPALIVE "25"

  echo ""
  info "确认填写的值："
  echo "    HK_WG_ADDR     = ${HK_WG_ADDR}"
  echo "    US_WG_PUBKEY   = ${US_WG_PUBKEY}"
  echo "    US_WG_ENDPOINT = ${US_WG_ENDPOINT}"
  echo "    US_WG_ADDR     = ${US_WG_ADDR}"
  echo "    KEEPALIVE      = ${WG_KEEPALIVE}s"
  echo ""
  confirm "以上信息是否正确？" || step_collect_wg_fresh
}

# =============================================================================
#  公共步骤：收集 WireGuard 配置（恢复模式）
# =============================================================================

step_collect_wg_restore() {
  header "步骤 3/5：WireGuard 配置（从备份恢复）"

  echo "  请依次输入备份时记录的值："
  echo "  （格式参考：HK_PRIV_KEY=xxxxxxxx，只需输入 = 号后面的部分）"
  echo ""

  read_input "HK_PRIV_KEY（香港 WG 私钥）" HK_WG_PRIV
  read_input "HK_WG_ADDR（香港 WG 隧道地址，如 10.0.0.3/32）" HK_WG_ADDR
  read_input "HK_WG_PEER_PUBKEY（美国节点 WG 公钥）" US_WG_PUBKEY
  read_input "HK_WG_ENDPOINT（美国节点 Endpoint，格式 IP:端口）" US_WG_ENDPOINT
  read_input "美国节点 WG 隧道内 IP（如 10.0.0.1/32）" US_WG_ADDR "10.0.0.1/32"
  read_input "HK_WG_KEEPALIVE（PersistentKeepalive 秒数）" WG_KEEPALIVE "25"

  echo ""
  info "确认填写的值："
  echo "    HK_WG_ADDR     = ${HK_WG_ADDR}"
  echo "    US_WG_PUBKEY   = ${US_WG_PUBKEY}"
  echo "    US_WG_ENDPOINT = ${US_WG_ENDPOINT}"
  echo "    US_WG_ADDR     = ${US_WG_ADDR}"
  echo "    KEEPALIVE      = ${WG_KEEPALIVE}s"
  echo ""
  confirm "以上信息是否正确？" || step_collect_wg_restore
}

# =============================================================================
#  公共步骤：生成 wg0.conf 并启动 WireGuard
# =============================================================================

step_setup_wireguard() {
  header "步骤 4a/5：生成 WireGuard 配置"

  # ── 解析面板 IP（wg0 未启动时走 eth0，确保能解析）──────────────────────────
  info "解析面板域名 ${PANEL_DOMAIN}（wg0 启动前）..."
  local panel_ip
  panel_ip=$(dig +short "$PANEL_DOMAIN" @1.1.1.1 2>/dev/null \
             | grep -E '^[0-9]+\.' | tail -1 || echo "")

  if [[ -z "$panel_ip" ]]; then
    # 备用：使用 8.8.8.8
    panel_ip=$(dig +short "$PANEL_DOMAIN" @8.8.8.8 2>/dev/null \
               | grep -E '^[0-9]+\.' | tail -1 || echo "")
  fi

  if [[ -z "$panel_ip" ]]; then
    error "无法解析 ${PANEL_DOMAIN}，请检查网络连通性"
    exit 1
  fi

  success "面板 IP: ${panel_ip}"
  PANEL_IP="$panel_ip"

  # 写入 /etc/hosts（固定面板 IP，防止 wg0 启动后走 wg0 解析）
  sed -i "/${PANEL_DOMAIN}/d" /etc/hosts
  echo "${PANEL_IP}  ${PANEL_DOMAIN}" >> /etc/hosts
  success "面板域名已固定到 /etc/hosts"

  # 保存面板 IP 供 cron 比较
  mkdir -p "$(dirname "$PANEL_IP_FILE")"
  echo "$PANEL_IP" > "$PANEL_IP_FILE"

  # ── 解析美国节点 IP 和端口 ────────────────────────────────────────────────
  local us_pub_ip us_wg_port us_wg_tunnel_ip
  us_pub_ip=$(    echo "$US_WG_ENDPOINT" | cut -d':' -f1)
  us_wg_port=$(   echo "$US_WG_ENDPOINT" | cut -d':' -f2)
  us_wg_tunnel_ip=$(echo "$US_WG_ADDR"  | cut -d'/' -f1)

  # ── 生成 wg0.conf ─────────────────────────────────────────────────────────
  info "生成 ${WG_CONF}..."
  mkdir -p /etc/wireguard

  cat > "$WG_CONF" << EOF
# ─────────────────────────────────────────────────────────────────────────────
#  wg0.conf  —  香港中转节点 WireGuard 配置
#  生成时间：$(date '+%Y-%m-%d %H:%M:%S')
#  入口回包：source-based routing → eth0rt 表 → ${HK_WAN_IF}
#  主动出站：默认路由 → wg0 → 美国出口
# ─────────────────────────────────────────────────────────────────────────────

[Interface]
PrivateKey = ${HK_WG_PRIV}
Address    = ${HK_WG_ADDR}
Table      = off
# Table = off：禁止 wg-quick 自动接管路由表，由 PostUp 精确控制

# ── PostUp：建立路由规则（wg0 启动时执行）────────────────────────────────────

# 1. 注册自定义路由表（幂等）
PostUp = grep -q '^100 eth0rt$' /etc/iproute2/rt_tables || echo '100 eth0rt' >> /etc/iproute2/rt_tables

# 2. eth0rt 表：以香港公网 IP 为源的回包 → 走公网网关 → 从 ${HK_WAN_IF} 对称返回
PostUp = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} table eth0rt

# 3. 策略路由规则：源地址是香港公网 IP → 查 eth0rt 表
PostUp = ip rule add pref 100 from ${HK_PUB_IP}/32 lookup eth0rt

# 4. 例外路由：美国节点公网 IP 必须走 eth0（WG 隧道外层封包，不能走 wg0）
PostUp = ip route replace ${us_pub_ip}/32 via ${HK_GW} dev ${HK_WAN_IF}

# 5. 例外路由：面板域名 IP 走 eth0（V2bX 拉配置必须直连面板）
PostUp = ip route replace ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}

# 6. 隧道对端 IP 路由（WG 内网地址）
PostUp = ip route replace ${us_wg_tunnel_ip}/32 dev wg0

# 7. 默认路由：所有主动出站（代理用户的目标访问）→ wg0 → 美国
PostUp = ip route replace default dev wg0

# ── PostDown：清理路由规则（wg0 关闭时执行）─────────────────────────────────

# 恢复默认路由（指向公网网关）
PostDown = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} onlink

# 清理 PostUp 添加的规则（2>/dev/null || true 防止不存在时报错）
PostDown = ip route del ${us_wg_tunnel_ip}/32 dev wg0                                  2>/dev/null || true
PostDown = ip route del ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}                  2>/dev/null || true
PostDown = ip route del ${us_pub_ip}/32 via ${HK_GW} dev ${HK_WAN_IF}                 2>/dev/null || true
PostDown = ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt                    2>/dev/null || true
PostDown = ip route flush table eth0rt                                                  2>/dev/null || true

[Peer]
PublicKey           = ${US_WG_PUBKEY}
Endpoint            = ${US_WG_ENDPOINT}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = ${WG_KEEPALIVE}
EOF

  chmod 600 "$WG_CONF"
  success "${WG_CONF} 已生成"

  # ── 启动 WireGuard ────────────────────────────────────────────────────────
  info "启动 wg-quick@wg0..."
  systemctl enable --quiet wg-quick@wg0
  # 若已在运行则先停止
  systemctl stop wg-quick@wg0 2>/dev/null || true
  sleep 1
  systemctl start wg-quick@wg0
  sleep 3

  if systemctl is-active --quiet wg-quick@wg0; then
    success "wg-quick@wg0 已启动"
  else
    error "wg-quick@wg0 启动失败，查看日志："
    journalctl -u wg-quick@wg0 --no-pager -n 30
    exit 1
  fi
}

# =============================================================================
#  公共步骤：WireGuard 三项验证
# =============================================================================

step_verify_wireguard() {
  header "步骤 4b/5：WireGuard 三项验证"

  local all_pass=true

  # ── ① 握手检测 ──────────────────────────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}① WireGuard 握手${NC}"
  local handshake_ts
  handshake_ts=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)

  if [[ -n "$handshake_ts" && "$handshake_ts" != "0" ]]; then
    local now ago
    now=$(date +%s)
    ago=$(( now - handshake_ts ))
    if [[ $ago -lt 300 ]]; then
      success "握手正常（${ago} 秒前）"
    else
      warn "握手存在，但距上次握手已 ${ago} 秒（>5 分钟，可能有延迟）"
    fi
  else
    fail_msg "无握手记录"
    warn "  排查："
    warn "    1. 确认美国节点 wg-quick@wg0 正在运行"
    warn "    2. 确认美国节点防火墙开放 UDP ${US_WG_ENDPOINT##*:}"
    warn "    3. 检查美国节点是否已将香港公钥加为 Peer"
    warn "    命令：ip route get ${US_WG_ENDPOINT%:*}   （期望走 ${HK_WAN_IF}）"
    all_pass=false
  fi

  # ── ② 出口 IP 检测 ──────────────────────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}② 出口 IP 地区（应为美国）${NC}"
  local out_ip out_country
  out_ip=$(curl -4 -s --max-time 12 https://ifconfig.io 2>/dev/null || echo "")

  if [[ -z "$out_ip" ]]; then
    fail_msg "无法获取出口 IP（curl 超时或失败）"
    warn "  排查："
    warn "    1. wg show 确认握手"
    warn "    2. 美国节点是否开启 NAT MASQUERADE"
    warn "    3. 美国节点 ip_forward 是否开启"
    all_pass=false
  else
    out_country=$(curl -s --max-time 6 "https://ipinfo.io/${out_ip}/country" 2>/dev/null | tr -d '[:space:]' || echo "未知")
    if [[ "$out_country" == "US" ]]; then
      success "出口 IP: ${out_ip}（美国 ✓）"
    else
      fail_msg "出口 IP: ${out_ip}，地区: ${out_country}（期望 US）"
      warn "  排查："
      warn "    1. 检查 ip route show → default 是否走 wg0"
      warn "    2. 检查美国节点 NAT 是否正常"
      warn "    命令：ip route show | grep default"
      all_pass=false
    fi
  fi

  # ── ③ 入口回包路径检测 ──────────────────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}③ 入口回包路径（应走 ${HK_WAN_IF}）${NC}"
  local route_dev
  route_dev=$(ip route get 8.8.8.8 from "${HK_PUB_IP}" 2>/dev/null \
              | grep -oP 'dev \K\S+' | head -1 || echo "")

  if [[ "$route_dev" == "$HK_WAN_IF" ]]; then
    success "回包路径: ${HK_PUB_IP} → ${HK_WAN_IF} ✓"
  else
    fail_msg "回包路径: ${HK_PUB_IP} → ${route_dev:-（无路由）}（期望 ${HK_WAN_IF}）"
    warn "  排查："
    warn "    ip rule list    → 是否有 pref 100 from ${HK_PUB_IP}/32 lookup eth0rt"
    warn "    ip route show table eth0rt  → 是否有 default via ${HK_GW} dev ${HK_WAN_IF}"
    all_pass=false
  fi

  # ── 结果判断 ────────────────────────────────────────────────────────────
  echo ""
  if [[ "$all_pass" == true ]]; then
    echo -e "  ${BOLD}${GREEN}三项验证全部通过，继续安装 V2bX${NC}"
    echo ""
    return 0
  else
    echo -e "  ${BOLD}${RED}存在验证失败项，请根据上方提示修复后重新运行脚本${NC}"
    echo ""
    echo "  快速诊断命令："
    echo "    ip rule list"
    echo "    ip route show"
    echo "    ip route show table eth0rt"
    echo "    wg show"
    echo "    curl -4 https://ifconfig.io"
    exit 1
  fi
}

# =============================================================================
#  公共步骤：安装并配置 V2bX
# =============================================================================

step_setup_v2bx() {
  header "步骤 5a/5：安装 V2bX"

  echo ""
  read_input "请输入节点 ID（Node ID，从面板获取，纯数字）" NODE_ID

  # 验证是数字
  while ! [[ "$NODE_ID" =~ ^[0-9]+$ ]]; do
    warn "Node ID 应为纯数字"
    read_input "请重新输入节点 ID" NODE_ID
  done

  info "下载并安装 V2bX..."
  if ! bash <(curl -Ls https://raw.githubusercontent.com/wyx2685/V2bX/master/install.sh); then
    error "V2bX 安装失败，请检查网络或手动安装"
    exit 1
  fi
  success "V2bX 安装完成"

  # ── 生成 config.yml ───────────────────────────────────────────────────────
  info "生成 V2bX 配置文件..."
  mkdir -p /etc/V2bX

  cat > "$V2BX_CONF" << EOF
# ─────────────────────────────────────────────────────────────────────────────
#  V2bX config.yml
#  生成时间：$(date '+%Y-%m-%d %H:%M:%S')
#  节点类型：vless + REALITY（配置由面板下发）
# ─────────────────────────────────────────────────────────────────────────────

Log:
  Level: warn
  AccessPath: /etc/V2bX/access.log
  ErrorPath:  /etc/V2bX/error.log

Nodes:
  - ApiHost:  "https://${PANEL_DOMAIN}"
    ApiKey:   "${PANEL_APIKEY}"
    NodeID:   ${NODE_ID}
    NodeType: vless
    Core:     sing

    Options:
      ListenIP:     0.0.0.0
      SendIP:       0.0.0.0
      TCPFastOpen:  true
      SniffEnabled: false   # 关闭：当前架构不依赖 sniff 分流，减少行为变量
EOF

  # ── 生成 sing_origin.json ─────────────────────────────────────────────────
  cat > "$SING_CONF" << 'EOF'
{
  "dns": {
    "servers": [
      { "tag": "remote",  "address": "1.1.1.1" },
      { "tag": "remote2", "address": "8.8.8.8" }
    ],
    "strategy": "ipv4_only"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "remote",
        "strategy": "ipv4_only"
      }
    },
    {
      "tag": "block",
      "type": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "network": ["tcp", "udp"],
        "outbound": "direct"
      }
    ]
  },
  "experimental": {
    "cache_file": { "enabled": true }
  }
}
EOF

  success "配置文件已生成"
  success "  config.yml    → ${V2BX_CONF}"
  success "  sing_origin.json → ${SING_CONF}"
}

step_start_v2bx() {
  header "步骤 5b/5：启动 V2bX"

  systemctl enable --quiet V2bX
  systemctl restart V2bX
  sleep 3

  if systemctl is-active --quiet V2bX; then
    success "V2bX 已启动并运行"
  else
    error "V2bX 启动失败，查看日志："
    journalctl -u V2bX --no-pager -n 30
    echo ""
    warn "可能原因：节点 ID 不正确，或面板 API 不可达"
    warn "修复后执行：systemctl restart V2bX"
    exit 1
  fi
}

# =============================================================================
#  公共步骤：部署面板 IP 定时更新机制
# =============================================================================

step_setup_panel_watcher() {
  header "部署面板 IP 定时监控"

  info "生成监控脚本 ${UPDATE_PANEL_SCRIPT}..."

  # 注意：EOF 不加引号，允许变量展开（将当前值写死到脚本中）
  cat > "$UPDATE_PANEL_SCRIPT" << SCRIPT
#!/usr/bin/env bash
# =============================================================================
#  update-panel-route.sh
#  功能：定时检查面板域名 IP 是否变更，变更则更新路由和 /etc/hosts
#  部署方式：由 hk-setup.sh 自动安装，cron 每小时执行一次
# =============================================================================

set -euo pipefail

PANEL_DOMAIN="${PANEL_DOMAIN}"
PANEL_IP_FILE="${PANEL_IP_FILE}"
HK_GW="${HK_GW}"
HK_WAN_IF="${HK_WAN_IF}"
LOG="/var/log/update-panel-route.log"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG"; }

# 解析当前 IP
NEW_IP=\$(dig +short "\$PANEL_DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | tail -1 || echo "")

if [[ -z "\$NEW_IP" ]]; then
  log "ERROR: 无法解析 \$PANEL_DOMAIN，本次跳过"
  exit 1
fi

OLD_IP=\$(cat "\$PANEL_IP_FILE" 2>/dev/null || echo "")

# IP 未变，无需操作
if [[ "\$NEW_IP" == "\$OLD_IP" ]]; then
  exit 0
fi

log "检测到面板 IP 变更：[\$OLD_IP] → [\$NEW_IP]，开始更新..."

# 删除旧路由（旧 IP 不为空时）
if [[ -n "\$OLD_IP" ]]; then
  ip route del "\${OLD_IP}/32" via "\$HK_GW" dev "\$HK_WAN_IF" 2>/dev/null && \
    log "已删除旧路由：\$OLD_IP/32" || \
    log "WARN: 删除旧路由失败（可能已不存在）"
fi

# 添加新路由
if ip route replace "\${NEW_IP}/32" via "\$HK_GW" dev "\$HK_WAN_IF"; then
  log "已添加新路由：\$NEW_IP/32 via \$HK_GW dev \$HK_WAN_IF"
else
  log "ERROR: 添加新路由失败"
  exit 1
fi

# 更新 /etc/hosts
sed -i "/\$PANEL_DOMAIN/d" /etc/hosts
echo "\${NEW_IP}  \$PANEL_DOMAIN" >> /etc/hosts
log "已更新 /etc/hosts：\$PANEL_DOMAIN → \$NEW_IP"

# 更新记录文件
echo "\$NEW_IP" > "\$PANEL_IP_FILE"
log "更新完成"
SCRIPT

  chmod +x "$UPDATE_PANEL_SCRIPT"
  success "监控脚本已生成：${UPDATE_PANEL_SCRIPT}"

  # ── 注册 cron（每小时第 5 分钟，避开整点拥堵）────────────────────────────
  local cron_line="5 * * * * ${UPDATE_PANEL_SCRIPT} >> /var/log/update-panel-route.log 2>&1"
  # 先删除旧记录，再添加
  ( crontab -l 2>/dev/null | grep -v "$UPDATE_PANEL_SCRIPT" || true
    echo "$cron_line"
  ) | crontab -

  success "Cron 已注册（每小时第 5 分钟执行）"
  success "日志路径：/var/log/update-panel-route.log"

  # 立即执行一次，验证脚本可用（此时应输出「无变更」）
  info "立即执行一次验证..."
  "$UPDATE_PANEL_SCRIPT" && success "监控脚本运行正常" || warn "监控脚本执行有警告（可查看日志）"
}

# =============================================================================
#  最终输出摘要
# =============================================================================

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}  ║              部署成功！                             ║${NC}"
  echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}  配置摘要${NC}"
  echo "  ─────────────────────────────────────────────────────"
  echo "  香港公网 IP      : ${HK_PUB_IP}"
  echo "  公网网卡         : ${HK_WAN_IF}"
  echo "  WG 隧道地址      : ${HK_WG_ADDR}"
  echo "  WG 出口          : ${US_WG_ENDPOINT}"
  echo "  面板 NodeID      : ${NODE_ID}"
  echo "  面板域名当前 IP  : ${PANEL_IP}（每小时自动检测更新）"
  echo ""
  echo -e "${BOLD}  快速验证命令${NC}"
  echo "  ─────────────────────────────────────────────────────"
  echo "  wg show"
  echo "  curl -4 https://ifconfig.io"
  echo "  ip route show"
  echo "  ip route show table eth0rt"
  echo "  systemctl status V2bX"
  echo ""
  echo -e "${BOLD}  日志路径${NC}"
  echo "  ─────────────────────────────────────────────────────"
  echo "  V2bX 错误日志    : tail -f /etc/V2bX/error.log"
  echo "  面板 IP 更新日志 : tail -f /var/log/update-panel-route.log"
  echo ""
}

# =============================================================================
#  MODE 1：全新安装
# =============================================================================

mode_fresh() {
  header "全新安装模式"
  check_debian
  step_base_system
  step_collect_network
  step_collect_wg_fresh
  step_setup_wireguard
  step_verify_wireguard
  step_setup_v2bx
  step_start_v2bx
  step_setup_panel_watcher
  print_summary
}

# =============================================================================
#  MODE 3：恢复模式
# =============================================================================

mode_restore() {
  header "恢复模式"
  check_debian
  step_base_system
  step_collect_network
  step_collect_wg_restore
  step_setup_wireguard
  step_verify_wireguard
  step_setup_v2bx
  step_start_v2bx
  step_setup_panel_watcher
  print_summary
}

# =============================================================================
#  入口
# =============================================================================

require_root

while true; do
  show_menu
  read -rp "  请输入选项 [1/2/3/q]: " choice
  echo ""
  case "$choice" in
    1) mode_fresh;   break ;;
    2) mode_backup;  break ;;
    3) mode_restore; break ;;
    q|Q) echo "  已退出"; exit 0 ;;
    *) warn "无效选项，请输入 1、2、3 或 q"; sleep 1 ;;
  esac
done
