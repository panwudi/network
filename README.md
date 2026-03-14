# hk-setup.sh — 香港中转节点运维手册

> **适用场景**：香港节点作为代理入口，美国节点作为出口，构建低泄露代理链路（Google / Gemini 可用性优化）。  
> **推荐系统**：Debian 12（其他系统可能运行，但未做充分测试）。

---

## 目录

- [架构说明](#架构说明)
- [快速开始](#快速开始)
- [三种运行模式](#三种运行模式)
  - [模式 1：全新安装](#模式-1全新安装)
  - [模式 2：备份模式](#模式-2备份模式)
  - [模式 3：恢复模式](#模式-3恢复模式)
- [脚本做了什么](#脚本做了什么)
- [固定常量](#固定常量)
- [验证部署结果](#验证部署结果)
- [日常运维命令](#日常运维命令)
- [故障排查](#故障排查)
- [重要设计说明](#重要设计说明)

---

## 架构说明

```
客户端
  │  VLESS + REALITY
  ▼
香港中转节点（入口）
  ├─ eth0  ← 接收客户端入站；入站回包也从此口原路返回（source-based routing）
  └─ wg0   → 代理出站，所有目标网站请求从此出，经美国节点 NAT 后到达目标
  ▼
美国出口节点
  └─ wg0 对端 + NAT MASQUERADE
  ▼
目标网站（Google / Gemini / ...）
```

**两类流量的路径必须分开：**

| 流量 | 正确出口 | 违反后果 |
|---|---|---|
| 客户端入站的**回包**（SSH、VLESS 回包） | `eth0`（原路返回） | 连接不对称 → SSH/443 间歇断连 |
| 香港节点**代理发起**的新连接 | `wg0` → 美国 | 出口变香港 IP → Gemini 地区受限 |

分离机制：`source-based policy routing`。以香港公网 IP 为源的包查 `eth0rt` 路由表走 `eth0`；其余主动出站查主路由表走 `wg0`。

---

## 快速开始

```bash
# 1. 下载脚本（在香港节点以 root 执行）
wget -O hk-setup.sh https://your-host/hk-setup.sh
chmod +x hk-setup.sh

# 2. 运行
sudo bash hk-setup.sh
```

启动后出现交互菜单，选择对应模式即可。

---

## 三种运行模式

### 模式 1：全新安装

**适用**：全新 Debian 12 系统，从未配置过 WireGuard。

**需要提前准备**（在美国节点执行 `wg show` 获取）：

- 香港节点 WG 私钥（`PrivateKey`）
- 香港节点 WG 隧道地址（如 `10.0.0.3/32`）
- 美国节点 WG 公钥（`public key`）
- 美国节点 WG Endpoint（`IP:端口`，如 `5.6.7.8:51820`）
- 美国节点 WG 隧道内 IP（如 `10.0.0.1/32`）
- V2bX 节点 ID（从面板获取，纯数字）

**执行流程**：

```
基础系统配置
  ├─ apt upgrade + 依赖安装
  ├─ 检测并修复 lo 接口 127.0.0.1 绑定（见下方说明）
  ├─ 禁用 IPv6
  ├─ 开启 IPv4 转发
  ├─ 禁用 systemd-resolved，锁定 resolv.conf
  └─ 启用 nftables
  ↓
网络信息采集（自动检测 + 人工确认）
  ↓
WireGuard 配置输入
  ↓
生成 wg0.conf，启动 WireGuard
  ↓
三项验证（握手 / 出口 IP / 回包路径）
  ↓（验证失败则退出并给出排查提示）
V2bX 安装（交互式菜单，选 1 安装）→ 覆盖配置文件
  ↓
部署面板 IP 定时监控 cron
  ↓
打印部署摘要
```

---

### 模式 2：备份模式

**适用**：即将重装香港节点系统，先保存当前 WireGuard 配置。

**注意**：脚本会临时关闭 wg0 以获取正确的本机网络信息（wg0 运行时 curl 返回美国 IP）。备份完成后 wg0 不会恢复，因为下一步就是重装系统。

**输出示例**：

```
# ───────────────── WireGuard 备份信息 ─────────────────
HK_PRIV_KEY=<私钥>
HK_PUB_KEY=<公钥>
HK_WG_ADDR=10.0.0.3/32
HK_WG_PEER_PUBKEY=<美国节点公钥>
HK_WG_ENDPOINT=5.6.7.8:51820
HK_WG_ALLOWED_IPS=0.0.0.0/0
HK_WG_KEEPALIVE=25

# ───────────────── 网络信息 ────────────────────────────
HK_WAN_IF=eth0
HK_GW=1.2.3.1
HK_PUB_IP=1.2.3.4
```

> ⚠️ **私钥（HK_PRIV_KEY）极度敏感**，请保存在本地加密文档中（KeePass、1Password 等），不要通过聊天 / 邮件 / 截图传输。

---

### 模式 3：恢复模式

**适用**：系统重装完成，用备份内容恢复配置。

**操作**：运行脚本 → 选 3 → 把备份内容**整块粘贴**（所有行一次粘贴，最后回车一次结束），脚本自动解析。

**支持的格式**：
- `KEY=VALUE` 每行一条
- `# 注释行`自动忽略
- 空白行结束输入

与全新安装的唯一区别是 WG 信息来源，后续所有步骤完全相同。

---

## 脚本做了什么

### 步骤 1：基础系统配置

| 操作 | 说明 | 幂等 |
|---|---|---|
| `apt upgrade` + 依赖安装 | 含 wireguard-tools、nftables、ipset 等 | ✓ |
| **lo 接口检查与修复** | 见下方专项说明 | ✓ |
| 禁用 IPv6 | 写入 `/etc/sysctl.d/99-no-ipv6.conf` | ✓ |
| 开启 IPv4 转发 | 写入 `/etc/sysctl.d/99-forward.conf` | ✓ |
| IPv4 优先 | 写入 `/etc/gai.conf` | ✓ |
| 禁用 systemd-resolved | stop + disable + mask | ✓ |
| 锁定 resolv.conf | `chattr +i`，先解锁再写入 | ✓ |
| 启用 nftables | restart（若已运行）或 start | ✓ |

#### lo 接口 127.0.0.1 修复说明

部分云厂商（已知问题）提供的镜像中，`lo` 接口不绑定 `127.0.0.1`，导致：

- sing-box / V2bX 内部服务无法监听 127.x.x.x
- DNS 解析在某些场景异常
- 本地服务互联失败

脚本的处理逻辑：

```
检测：ip addr show lo | grep 127.0.0.1
  ├─ 存在 → 正常，跳过
  └─ 不存在
        ├─ 立即添加：ip addr add 127.0.0.1/8 dev lo
        └─ 持久化：部署 lo-127-fix.service（systemd oneshot）
                   Before=network-pre.target
                   WantedBy=sysinit.target
                   确保重启后、任何网络配置之前自动执行
```

验证服务状态：

```bash
systemctl status lo-127-fix.service
ip addr show lo
```

---

### 步骤 2：网络信息采集

脚本在采集前会先检测 wg0 是否在运行：

- **wg0 未运行**：直接采集（`ip route` + `curl ifconfig.io`）
- **wg0 在运行**（重复运行的场景）：先停止 wg0，若 PostDown 未恢复默认路由则从 `eth0rt` 表捞出旧记录补回，再采集

采集完成后需人工确认，可手动修改任一字段。

---

### 步骤 3：WireGuard 配置

- **全新安装**：逐字段输入
- **恢复模式**：整块粘贴备份内容，自动解析

---

### 步骤 4：WireGuard 路由配置

脚本生成的 `wg0.conf` 核心逻辑：

```
Table = off          # 禁止 wg-quick 自动改主路由表

PostUp：
  1. 注册 eth0rt 路由表（编号 100）
  2. eth0rt 表：default via <HK_GW> dev <HK_WAN_IF>
  3. ip rule：from <HK_PUB_IP>/32 → lookup eth0rt   ← 回包走 eth0
  4. host route：<US_PUB_IP>/32 via <HK_GW> dev <HK_WAN_IF>   ← 隧道外层封包不走 wg0
  5. host route：<PANEL_IP>/32 via <HK_GW> dev <HK_WAN_IF>    ← 面板直连
  6. <US_WG_TUN_IP>/32 dev wg0
  7. default dev wg0   ← 所有主动出站走 wg0

PostDown：
  逐条清理，恢复 default via <HK_GW> dev <HK_WAN_IF>
```

---

### 步骤 4b：WireGuard 三项验证

| 验证项 | 命令 | 期望 |
|---|---|---|
| ① WG 握手 | `wg show wg0 latest-handshakes` | 握手时间 < 5 分钟 |
| ② 出口 IP | `curl -4 https://ifconfig.io` + ipinfo.io 地区查询 | 地区 = US |
| ③ 回包路径 | `ip route get 8.8.8.8 from <HK_PUB_IP>` | dev = `<HK_WAN_IF>` |

三项全部通过才继续，任一失败则打印排查提示并退出。

---

### 步骤 5：V2bX 安装

1. 下载 [V2bX-script](https://github.com/wyx2685/V2bX-script) 的 `install.sh`
2. 提示用户在交互菜单中选择「安装」（数字 1）
3. 安装完成后，脚本覆盖 `/etc/V2bX/config.yml` 和 `/etc/V2bX/sing_origin.json`
4. `v2bx` 管理命令完整保留

**固定配置**（无需修改）：

```yaml
ApiHost: https://panel.flytoex.net
ApiKey:  flyto20221227.com
NodeType: vless
Core: sing
SniffEnabled: false   # 关闭：当前架构不依赖 sniff，减少行为变量
```

**sing_origin.json 设计**：

- DNS `strategy: ipv4_only`（防 IPv6 泄露）
- 私网目标 block
- 其他全部 direct → 交给系统路由 → wg0 → 美国出口

---

### 面板 IP 定时监控

`panel.flytoex.net` 的 IP 写入了 `wg0.conf` PostUp 的例外路由和 `/etc/hosts`。若 IP 变更，V2bX 拉取面板配置的流量可能走 wg0 出美国，导致面板连接失败。

脚本部署 `/usr/local/bin/update-panel-route.sh`，cron 每小时第 5 分钟执行：

```
dig panel.flytoex.net @8.8.8.8
  ├─ IP 未变 → 退出（0 操作）
  └─ IP 已变
        ├─ 删除旧 /32 host route
        ├─ 添加新 /32 host route
        ├─ 更新 /etc/hosts
        ├─ 更新 /etc/hk-setup/panel_ip
        └─ 写日志
```

查看日志：

```bash
tail -f /var/log/update-panel-route.log
```

手动触发更新：

```bash
/usr/local/bin/update-panel-route.sh
```

---

## 固定常量

| 常量 | 值 | 说明 |
|---|---|---|
| 面板地址 | `https://panel.flytoex.net` | 硬编码，不可修改 |
| 面板 ApiKey | `flyto20221227.com` | 硬编码，不可修改 |
| 节点类型 | `vless` | REALITY 配置由面板下发 |
| WG AllowedIPs | `0.0.0.0/0` | 全流量通过隧道 |
| WG PersistentKeepalive | `25`（默认） | 可在输入时修改 |

---

## 验证部署结果

### 路由结构验证

```bash
# 策略路由规则（期望有 pref 100 from <HK_PUB_IP>/32 lookup eth0rt）
ip rule list

# 主路由表（期望 default dev wg0）
ip route show

# eth0rt 路由表（期望 default via <HK_GW> dev <HK_WAN_IF>）
ip route show table eth0rt

# 回包路径（期望 dev <HK_WAN_IF>，不能是 wg0）
ip route get 8.8.8.8 from <HK_PUB_IP>

# 主动出站路径（期望 dev wg0）
ip route get 8.8.8.8

# WG Endpoint 路径（期望 dev <HK_WAN_IF>，不能是 wg0）
ip route get <US_PUB_IP>
```

### 出口与泄露验证

```bash
# 出口 IP 应为美国
curl -4 https://ifconfig.io
curl -4 https://ipinfo.io/json

# IPv6 应不可达
curl -6 --max-time 5 https://ifconfig.io
```

浏览器无痕验证：

| 检测工具 | 期望 |
|---|---|
| dnsleaktest.com | 仅美国 DNS，无中国 / 香港 DNS |
| browserleaks.com/webrtc | 无本地 IP 暴露 |
| browserleaks.com/ip | 美国 IP |

---

## 日常运维命令

### WireGuard

```bash
# 查看状态（含握手时间）
wg show

# 重启
systemctl restart wg-quick@wg0

# 查看日志
journalctl -u wg-quick@wg0 -n 50
```

### V2bX（支持 v2bx 管理命令）

```bash
# 查看状态
systemctl status V2bX
v2bx status          # 等价

# 重启
systemctl restart V2bX
v2bx restart         # 等价

# 实时日志
journalctl -u V2bX -f
tail -f /etc/V2bX/error.log

# 更新 V2bX
v2bx update
```

### 面板 IP 监控

```bash
# 查看当前记录的面板 IP
cat /etc/hk-setup/panel_ip

# 实时解析对比
dig +short panel.flytoex.net @8.8.8.8

# 手动触发更新
/usr/local/bin/update-panel-route.sh

# 查看更新日志
tail -20 /var/log/update-panel-route.log
```

### lo 修复服务

```bash
# 查看服务状态
systemctl status lo-127-fix.service

# 确认 lo 当前绑定情况
ip addr show lo
```

---

## 故障排查

### SSH / 443 公网入站间歇断连

**原因**：入口回包没走 `eth0`，source-based routing 失效。

```bash
ip rule list | grep eth0rt
# 若无输出 → policy rule 未建立

ip route show table eth0rt
# 若为空 → eth0rt 表未填充

# 确认 wg0 正常运行（PostUp 必须完整执行过）
systemctl status wg-quick@wg0
journalctl -u wg-quick@wg0 -n 30
```

---

### `wg-quick up wg0` 后 SSH 立即断开

**原因**：`wg0.conf` 缺少 `Table = off`，WireGuard 自动接管了默认路由。

**恢复**（通过 VNC / 控制台登录）：

```bash
# 临时恢复默认路由
ip route replace default via <HK_GW> dev <HK_WAN_IF>

# 检查 wg0.conf 是否有 Table = off
grep 'Table' /etc/wireguard/wg0.conf

# 重新运行脚本（会重新生成 conf）
bash hk-setup.sh  # 选 1 或 3
```

---

### wg show 无握手记录

```bash
# 1. 美国节点公网 IP 是否可达
ping -c3 <US_PUB_IP>

# 2. WG Endpoint 路由是否走 eth0（不能走 wg0）
ip route get <US_PUB_IP>

# 3. 美国节点 WG 端口是否开放
nc -uvz <US_PUB_IP> <US_WG_PORT>

# 4. 在美国节点检查
wg show
systemctl status wg-quick@wg0
```

---

### 出口 IP 是香港而非美国

**原因**：wg0 默认路由未生效。

```bash
ip route show | grep default
# 应该是 "default dev wg0 scope link"
# 若是 "default via <HK_GW> dev <HK_WAN_IF>" → PostUp 第7条未执行

wg show
# 若无握手 → 隧道不通，路由加上也无效
```

---

### V2bX 无法拉取面板配置

```bash
# 1. 面板域名解析是否正确
dig panel.flytoex.net @8.8.8.8

# 2. 面板 IP 的路由是否走 eth0
PANEL_IP=$(cat /etc/hk-setup/panel_ip)
ip route get "$PANEL_IP"
# 期望：dev <HK_WAN_IF>，不能是 dev wg0

# 3. 直接 curl 面板
curl -v https://panel.flytoex.net --max-time 10

# 4. 查看错误日志
tail -50 /etc/V2bX/error.log
```

---

### 面板 IP 变更后 V2bX 断连

```bash
# 检查记录 IP 与实际解析是否一致
echo "记录IP: $(cat /etc/hk-setup/panel_ip)"
echo "当前IP: $(dig +short panel.flytoex.net @8.8.8.8 | tail -1)"

# 若不一致，手动触发更新
/usr/local/bin/update-panel-route.sh

# 查看日志
tail -20 /var/log/update-panel-route.log
```

---

### lo 接口没有 127.0.0.1（云厂商特殊情况）

```bash
# 查看当前状态
ip addr show lo

# 手动修复（临时）
ip addr add 127.0.0.1/8 dev lo
ip link set lo up

# 确认持久化服务状态
systemctl status lo-127-fix.service
systemctl is-enabled lo-127-fix.service
# 期望：enabled

# 若服务未启用
systemctl enable --now lo-127-fix.service
```

---

## 重要设计说明

### 为什么 `Table = off`

`AllowedIPs = 0.0.0.0/0` 时，若不加 `Table = off`，`wg-quick up` 会自动在主路由表添加默认路由并删除原有默认路由，导致 SSH 立即断开，且 WG Endpoint 本身的报文也会尝试走 wg0（自环）。`Table = off` 后，所有路由由 PostUp 手动精确写入，完全可控。

### 为什么 ip rule add 前先 del

`ip rule add` 不是幂等的。若 wg0 因崩溃等原因跳过了 PostDown，再次启动会产生重复的 policy rule，导致路由优先级混乱。脚本在 PostUp 中先执行 `ip rule del pref 100 ... 2>/dev/null || true` 再 `ip rule add`，保证任何情况下都只有一条规则。

### 为什么网络采集前要停 wg0

wg0 运行时，`ip route show default` 返回 `default dev wg0`，`curl ifconfig.io` 返回美国 IP，两个探测结果都是错的。脚本在 `step_collect_network` 开始时统一停止 wg0，确保采集到本机真实网络信息。后续 `step_setup_wireguard` 会重新生成配置并启动。

### sing-box 中 direct 的真实含义

sing-box 的 `direct` outbound 在此架构下并非"香港直出"，而是：

```
sing-box direct → 系统路由 → 主路由表 default → wg0 → 美国出口
```

sing-box 本身不承担任何路由决策，所有路由工作由 Linux 内核完成。

### 面板域名例外路由的必要性

V2bX 通过 `https://panel.flytoex.net` 拉取节点配置。若该域名的 IP 没有例外路由，流量会走 wg0 出美国，面板可能因为非预期来源 IP 拒绝请求，或因 wg0 握手尚未完成而超时。例外路由确保面板流量始终走 `eth0` 直连。
