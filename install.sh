#!/usr/bin/env bash
# ==========================================================================
# 多 IP SOCKS5 出口安装脚本（Xray）
#   每个本机公网 IPv4 起一个 SOCKS5 入站，出站 sendThrough 绑定该 IP，
#   实现「连哪个端口 = 用哪个 IP 出去」。
#
# 与原始脚本的差别：
#   1. 使用 JSON 配置（Xray 全版本通用，含当前 25.x），不再用 TOML
#   2. 启动前必须通过 `xray -test`，配置错了不会上线
#   3. 预检：架构 / 包管理器 / 依赖 / 端口占用 / IP 是否真的在本机
#   4. 不再清空 iptables、不删 firewalld 规则，只放行自己的端口
#   5. 同时支持 RHEL 系（dnf/yum）与 Debian 系（apt）
#   6. 启动后逐个端口校验监听状态，失败返回非 0
#
# 用法（推荐一键执行，见 README）：
#   bash install.sh
#   LISTEN_IPS="1.2.3.4 5.6.7.8" PORT_BASE=5100 bash install.sh
#   XRAY_VERSION=latest bash install.sh
#   XRAY_ZIP_URL=file:///root/Xray-linux-64.zip bash install.sh
#   bash install.sh --help
# ==========================================================================
set -Eeuo pipefail

PORT_BASE="${PORT_BASE:-5000}"
XRAY_VERSION="${XRAY_VERSION:-26.11.9}"
XRAY_SHA256="${XRAY_SHA256:-}"
XRAY_ZIP_URL="${XRAY_ZIP_URL:-}"
LISTEN_IPS="${LISTEN_IPS:-}"

XRAY_DIR="/root/e1"
XRAY_BIN="${XRAY_DIR}/xray"
CONF_DIR="/etc/xray"
CONF="${CONF_DIR}/serve.json"
UNIT="/etc/systemd/system/xray.service"

log()  { printf '\033[1;37m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help)
    cat <<'USAGE'
多 IP SOCKS5 出口安装脚本（Xray）

用法:
  bash install.sh [--help]

环境变量:
  PORT_BASE      起始端口，默认 5000
  LISTEN_IPS     手动指定 IP，空格或逗号分隔（默认自动探测）
  XRAY_VERSION   Xray 版本，默认 26.11.9（最新稳定版），可填 latest
  XRAY_ZIP_URL   自定义 zip 地址，支持 file:// 本地文件
  XRAY_SHA256    期望的 sha256（可选，官方源会自动取 .dgst）

产物:
  /root/e1/xray                     二进制
  /etc/xray/serve.json              配置（权限 600）
  /etc/systemd/system/xray.service  服务
  /root/<时间>_socks5_ip.txt        出口IP:端口:用户名:密码

示例:
  PORT_BASE=5100 bash install.sh
  LISTEN_IPS="1.2.3.4 5.6.7.8" bash install.sh
USAGE
    exit 0 ;;
  "") ;;
  *) die "未知参数：$1（用 --help 查看用法）" ;;
esac

[[ ${EUID} -eq 0 ]] || die "请用 root 运行：sudo -i"
command -v systemctl >/dev/null 2>&1 || die "没有 systemd，本脚本不适用"
[[ "$PORT_BASE" =~ ^[0-9]+$ ]] || die "PORT_BASE 必须是数字：$PORT_BASE"
PORT_BASE=$((10#$PORT_BASE))          # 防止 0100 被当成八进制 64
(( PORT_BASE >= 1 && PORT_BASE <= 65000 )) || die "PORT_BASE 超出范围：$PORT_BASE"
if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
  die "缺少 ss / netstat，无法检查端口占用（装 iproute2 或 net-tools）"
fi

# ---------------------------------------------------------------- 依赖
if   command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
elif command -v apt-get >/dev/null 2>&1; then PM=apt
else die "无法识别包管理器（只支持 dnf / yum / apt-get）"
fi

log "包管理器：${PM}，安装 unzip / curl / ca-certificates"
if [[ "$PM" == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq unzip curl ca-certificates
else
  "$PM" install -y -q unzip curl ca-certificates
fi
command -v unzip >/dev/null 2>&1 || die "unzip 装不上，退出"

# ---------------------------------------------------------------- 架构
case "$(uname -m)" in
  x86_64|amd64)   ZIP_NAME="Xray-linux-64.zip" ;;
  aarch64|arm64)  ZIP_NAME="Xray-linux-arm64-v8a.zip" ;;
  *) die "不支持的架构：$(uname -m)（仅 x86_64 / aarch64）" ;;
esac

# ---------------------------------------------------------------- 版本
if [[ "$XRAY_VERSION" == latest ]]; then
  XRAY_VERSION="$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1 || true)"
  [[ -n "$XRAY_VERSION" ]] || die "取不到最新版本号，请用 XRAY_VERSION=26.x.y 指定"
fi
log "目标版本：v${XRAY_VERSION}"
maj="${XRAY_VERSION%%.*}"
if [[ "$maj" =~ ^[0-9]+$ ]] && (( maj < 25 )); then
  warn "v${XRAY_VERSION} 属于旧分支（当前主线 26.x），建议 XRAY_VERSION=latest"
fi

# ---------------------------------------------------------------- 取 IP
detect_ips() {
  ip -o -4 addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker|veth|br-|virbr|tun|tap|wg|zt|cni|flannel|kube)/ {
           split($4, a, "/"); print a[1]
         }' |
    sort -u
}

command -v ip >/dev/null 2>&1 || die "缺少 ip 命令（iproute2），请先安装"
ipdump="$(ip -o -4 addr show 2>/dev/null || true)"
if [[ -n "$LISTEN_IPS" ]]; then
  ip_text="$(printf '%s' "${LISTEN_IPS//,/ }" | tr -s ' ' '\n')"
else
  ip_text="$(detect_ips)"
fi
[[ -n "$ip_text" ]] || die "没检测到对外 IPv4。可用 LISTEN_IPS='1.2.3.4 5.6.7.8' 手动指定"

# ---------------------------------------------------------------- 工具函数
port_in_use() {                       # $1=端口；占用返回 0
  local p="$1" dump
  if command -v ss >/dev/null 2>&1; then
    dump="$(ss -lntu 2>/dev/null || true)"
    awk -v p=":${p}" 'NR>1 && $5 ~ p"$" {f=1} END{exit !f}' <<<"$dump"
  else
    dump="$(netstat -lntu 2>/dev/null || true)"
    awk -v p=":${p}" '$4 ~ p"$" {f=1} END{exit !f}' <<<"$dump"
  fi
}

ufw_active() {                        # 先收全文再匹配，避免 grep -q 提前退出
  local s
  s="$(ufw status 2>/dev/null || true)"
  [[ "$s" == *"Status: active"* ]]
}

gen_str() {                           # 6 位随机字母，无 SIGPIPE 噪音
  local s=""
  while [[ ${#s} -lt 6 ]]; do
    s+="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z')"
  done
  printf '%s' "${s:0:6}"
}

port_open_firewall() {                # $1=起始 $2=结束
  local first="$1" last="$2" rng
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    if [[ "$first" == "$last" ]]; then rng="$first"; else rng="${first}-${last}"; fi
    firewall-cmd --permanent --add-port="${rng}/tcp" >/dev/null || return 1
    firewall-cmd --permanent --add-port="${rng}/udp" >/dev/null || return 1
    firewall-cmd --reload >/dev/null || return 1
    ok "firewalld 已放行 ${rng}/{tcp,udp}"
  elif command -v ufw >/dev/null 2>&1 && ufw_active; then
    if [[ "$first" == "$last" ]]; then
      ufw allow "${first}/tcp" >/dev/null || return 1
      ufw allow "${first}/udp" >/dev/null || return 1
    else
      ufw allow "${first}:${last}/tcp" >/dev/null || return 1
      ufw allow "${first}:${last}/udp" >/dev/null || return 1
    fi
    ok "ufw 已放行 ${first}:${last}/{tcp,udp}"
  else
    warn "未发现运行中的 firewalld/ufw，跳过放行；如云厂商有安全组请手动放行 ${first}-${last}"
  fi
}

public_ip_for() {                     # $1=本机 IP，输出该 IP 的出口公网 IP
  local ip="$1" body u
  for u in https://api.ip.sb/ip https://icanhazip.com https://ifconfig.me/ip; do
    body="$(curl --interface "$ip" -fsS --max-time 6 --connect-timeout 3 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$body" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$body"; return 0; fi
  done
  printf 'UNKNOWN'
}

# ---------------------------------------------------------------- 二进制
fetch_xray() {
  local urls=() u tmp rc=1 expect
  [[ -n "$XRAY_ZIP_URL" ]] && urls+=("$XRAY_ZIP_URL")
  urls+=("https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${ZIP_NAME}")
  # gitee 镜像只保留了少数旧版本，仅在明确指定这些版本时作为 GitHub 不通的兜底
  case "${ZIP_NAME}:${XRAY_VERSION}" in
    Xray-linux-64.zip:1.6.1) urls+=("https://gitee.com/sk_gg/sk5/releases/download/Xray1.6.1/Xray-linux-64.zip") ;;
    Xray-linux-64.zip:1.7.5) urls+=("https://gitee.com/sk_gg/sk5/releases/download/Xray1.7.5/Xray-linux-64.zip") ;;
  esac
  tmp="$(mktemp)"
  for u in "${urls[@]}"; do
    log "下载：$u"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 300 -o "$tmp" "$u"; then
      warn "下载失败，换下一个源"; continue
    fi
    # 优先用调用方给的哈希；官方 GitHub 源自动抓同名 .dgst 校验
    expect="$XRAY_SHA256"
    if [[ -z "$expect" && "$u" == https://github.com/* ]]; then
      expect="$(curl -fsSL --max-time 20 "${u}.dgst" 2>/dev/null \
        | grep -iE '^(SHA2-256|SHA256)=' | head -1 | cut -d= -f2- | tr -d ' \r' || true)"
    fi
    if [[ -n "$expect" ]]; then
      if ! printf '%s  %s\n' "$expect" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
        warn "SHA256 不匹配（来源可能被替换），丢弃该源"; continue
      fi
      ok "SHA256 校验通过（${expect:0:16}…）"
    else
      warn "无法校验来源（未设 XRAY_SHA256，且该源没有 .dgst）"
    fi
    mkdir -p "$XRAY_DIR"
    if ! unzip -o -q "$tmp" -d "$XRAY_DIR"; then warn "解压失败，换下一个源"; continue; fi
    rc=0; break
  done
  rm -f "$tmp"
  [[ $rc -eq 0 && -f "$XRAY_BIN" ]] || return 1
  chmod +x "$XRAY_BIN"
}

need_fetch=1
if [[ -x "$XRAY_BIN" ]]; then
  cur_ver="$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' || true)"
  if [[ -n "$cur_ver" && "$cur_ver" == "$XRAY_VERSION" ]]; then
    need_fetch=0
    log "已存在 v${cur_ver}，与目标一致，跳过下载"
  else
    warn "已安装 v${cur_ver:-未知}，目标 v${XRAY_VERSION}，重新下载覆盖"
  fi
fi
if (( need_fetch )); then
  fetch_xray || die "Xray 下载/解压全部失败（检查网络或换 XRAY_ZIP_URL）"
fi
"$XRAY_BIN" version >/dev/null 2>&1 || die "二进制无法执行（架构不匹配或被替换）：$("$XRAY_BIN" version 2>&1 | head -1 || true)"
"$XRAY_BIN" version 2>/dev/null | head -2 || true

# ---------------------------------------------------------------- 生成配置
log "生成配置并检查端口"
inbounds=""; outbounds=""; rules=""; records=""; idx=0; first_port=""; last_port=""

while IFS= read -r ip; do
  [[ -n "$ip" ]] || continue
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    warn "跳过非法 IPv4：$ip"; continue
  fi
  port=$(( PORT_BASE + idx ))
  (( port <= 65535 )) || die "端口超出范围，IP 太多，换 PORT_BASE"
  if ! grep -qE "inet +${ip//./\\.}/" <<<"$ipdump"; then
    die "IP ${ip} 不在本机任何网卡上，绑不上去（检查 LISTEN_IPS）"
  fi

  idx=$(( idx + 1 ))
  if port_in_use "$port"; then
    die "端口 ${port} 已被占用。用 PORT_BASE=$(( PORT_BASE + 20 )) 重跑，或先释放该端口"
  fi

  user="$(gen_str)"
  pass="$(gen_str)"
  [[ -n "$first_port" ]] || first_port="$port"
  last_port="$port"

  inbounds+=$(cat <<FRAG
{"listen":"${ip}","port":${port},"protocol":"socks","tag":"in-${idx}","settings":{"auth":"password","udp":true,"accounts":[{"user":"${user}","pass":"${pass}"}]}},
FRAG
)
  outbounds+=$(cat <<FRAG
{"sendThrough":"${ip}","protocol":"freedom","tag":"out-${idx}"},
FRAG
)
  rules+=$(cat <<FRAG
{"type":"field","inboundTag":["in-${idx}"],"outboundTag":"out-${idx}"},
FRAG
)
  records+="${ip}|${port}|${user}|${pass}"$'\n'
done <<<"$ip_text"

(( idx > 0 )) || die "没有可用的 IP，已中止"
inbounds="${inbounds%,}"; outbounds="${outbounds%,}"; rules="${rules%,}"

mkdir -p "$CONF_DIR"
umask 077
cat > "$CONF" <<CONF_EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
${outbounds}
  ],
  "routing": {
    "rules": [
${rules}
    ]
  }
}
CONF_EOF

# 关键一步：配置先校验，通过才碰服务
testlog="$(mktemp)"
if ! "$XRAY_BIN" run -test -c "$CONF" >"$testlog" 2>&1; then
  cat "$testlog" >&2
  rm -f "$testlog"
  die "配置校验失败，已中止（现有服务未被改动）"
fi
rm -f "$testlog"
ok "配置校验通过：${CONF}（${idx} 个入站）"

# ---------------------------------------------------------------- systemd
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Xray SOCKS5 multi-IP service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${CONF}
Restart=on-failure
RestartSec=15s
RestartPreventExitStatus=23
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || warn "systemctl enable 失败，重启后不会自动启动"
systemctl restart xray || true
sleep 2

if ! systemctl is-active --quiet xray; then
  systemctl status xray --no-pager -l 2>&1 | head -30 >&2 || true
  journalctl -u xray -n 30 --no-pager >&2 || true
  die "xray 启动失败"
fi

# ---------------------------------------------------------------- 防火墙
port_open_firewall "$first_port" "$last_port" || warn "放行端口时出错，请手动检查防火墙/安全组"

# ---------------------------------------------------------------- 校验
bad=0
while IFS='|' read -r ip port user pass; do
  [[ -n "$ip" ]] || continue
  if ! port_in_use "$port"; then
    warn "端口 ${port} 未监听（${ip}）"; bad=1
  fi
done <<<"$records"

record_file="/root/$(date +%F_%H_%M_%S)_socks5_ip.txt"
: > "$record_file"
printf '%s\t%s\t%s\t%s\t%s\n' "出口IP" "端口" "用户" "密码" "绑定IP"
while IFS='|' read -r ip port user pass; do
  [[ -n "$ip" ]] || continue
  exit_ip="$(public_ip_for "$ip")"
  [[ "$exit_ip" == UNKNOWN ]] && warn "${ip} 的出口 IP 探测失败（三个探测站点都不通）"
  printf '%s\t%s\t%s\t%s\t%s\n' "$exit_ip" "$port" "$user" "$pass" "$ip"
  printf '%s:%s:%s:%s\n' "$exit_ip" "$port" "$user" "$pass" >> "$record_file"
done <<<"$records"

ok "账号信息：${record_file}"
log "自测：curl -x socks5h://用户:密码@服务器IP:端口 https://api.ip.sb/ip"
if (( bad != 0 )); then
  journalctl -u xray -n 20 --no-pager >&2 || true
  die "部分端口未监听，安装未完成"
fi
ok "全部 ${idx} 个 SOCKS5 已监听"
