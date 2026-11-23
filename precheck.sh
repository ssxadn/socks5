#!/usr/bin/env bash
# ==========================================================================
# Xray 多 IP SOCKS5 安装前自检（只读：不装包、不改防火墙、不碰 systemd）
# 用法：
#   bash precheck.sh
#   LISTEN_IPS="1.2.3.4 5.6.7.8" PORT_BASE=5100 bash precheck.sh
# 退出码：0=可以装  1=有 WARN  2=有 FAIL（先修再装）
# ==========================================================================
set -uo pipefail

PORT_BASE="${PORT_BASE:-5000}"
LISTEN_IPS="${LISTEN_IPS:-}"
CNT_PASS=0; CNT_WARN=0; CNT_FAIL=0

pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; CNT_PASS=$((CNT_PASS+1)); }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; CNT_WARN=$((CNT_WARN+1)); }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; CNT_FAIL=$((CNT_FAIL+1)); }
info() { printf '\033[1;37m[INFO]\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1; }

if [[ ! "$PORT_BASE" =~ ^[0-9]+$ ]]; then
  printf '\033[0;31m[FAIL]\033[0m PORT_BASE 必须是数字：%s\n' "$PORT_BASE"; exit 2
fi
PORT_BASE=$((10#$PORT_BASE))
if (( PORT_BASE < 1 || PORT_BASE > 65000 )); then
  printf '\033[0;31m[FAIL]\033[0m PORT_BASE 超出范围：%s\n' "$PORT_BASE"; exit 2
fi

# ---------------------------------------------------------------- 基本环境
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  pass "root 权限"
else
  warn "当前不是 root，安装时必须用 root（只读检测可以继续）"
fi

. /etc/os-release 2>/dev/null || true
if [[ -n "${ID:-}" ]]; then
  info "系统：${PRETTY_NAME:-$ID ${VERSION_ID:-}}（${ID_LIKE:-$ID}）"
else
  warn "读不到 /etc/os-release，无法确认发行版"
fi

if need systemctl; then pass "systemd 可用"; else fail "没有 systemd，本方案不适用"; fi

case "$(uname -m)" in
  x86_64|amd64)  pass "架构 $(uname -m) → 需要 Xray-linux-64.zip" ;;
  aarch64|arm64) pass "架构 $(uname -m) → 需要 Xray-linux-arm64-v8a.zip（原脚本写死 amd64 包，会 Exec format error）" ;;
  *) fail "架构 $(uname -m) 无对应官方包" ;;
esac

if need dnf; then pass "包管理器 dnf"
elif need yum; then pass "包管理器 yum"
elif need apt-get; then pass "包管理器 apt-get（原脚本的 yum 会直接失败）"
else fail "无 dnf / yum / apt-get，无法装依赖"
fi

for c in curl wget unzip sha256sum ip; do
  if need "$c"; then pass "命令 $c 存在"; else warn "缺少 $c（安装脚本会自动补，但下载可能受影响）"; fi
done
if need ss || need netstat; then pass "端口检测工具 ss/netstat 可用"; else fail "缺 ss 和 netstat，无法判断端口占用"; fi
need sudo && pass "sudo 存在" || warn "没有 sudo（原脚本的 sudo unzip 会失败；直接 root 运行则无所谓）"

# ---------------------------------------------------------------- 防火墙
if need firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
  pass "firewalld 运行中（原脚本依赖它放行端口）"
elif need firewall-cmd; then
  warn "装了 firewalld 但没运行，原脚本的 firewall-cmd 会全部报错"
elif need ufw; then
  s="$(ufw status 2>/dev/null || true)"
  if [[ "$s" == *"Status: active"* ]]; then
    warn "使用 ufw 而非 firewalld，原脚本的 firewall-cmd 会报 command not found"
  else
    warn "未发现启用的 firewalld/ufw（端口可能默认开放，也可能由云安全组挡着）"
  fi
else
  warn "未发现启用的 firewalld/ufw（端口可能默认开放，也可能由云安全组挡着）"
fi

# ---------------------------------------------------------------- IP
detect_ips() {
  ip -o -4 addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker|veth|br-|virbr|tun|tap|wg|zt|cni|flannel|kube)/ {
           split($4, a, "/"); print a[1] }' | sort -u
}

if [[ -n "$LISTEN_IPS" ]]; then
  ip_text="$(printf '%s' "${LISTEN_IPS//,/ }" | tr -s ' ' '\n')"
else
  ip_text="$(detect_ips)"
fi

if [[ -z "$ip_text" ]]; then
  fail "没有检测到对外 IPv4"
else
  ip_n=$(printf '%s\n' "$ip_text" | grep -c .)
  info "检测到 ${ip_n} 个候选 IP："
  printf '%s\n' "$ip_text" | sed 's/^/       /'
fi

ipdump="$(ip -o -4 addr show 2>/dev/null || true)"

# 逐个确认：IP 在本机网卡上 + 用该 IP 出去确有公网出口 + 对应端口空闲
port_in_use() {
  local p="$1" dump
  if need ss; then
    dump="$(ss -lntu 2>/dev/null || true)"
    awk -v p=":${p}" 'NR>1 && $5 ~ p"$" {f=1} END{exit !f}' <<<"$dump"
  else
    dump="$(netstat -lntu 2>/dev/null || true)"
    awk -v p=":${p}" '$4 ~ p"$" {f=1} END{exit !f}' <<<"$dump"
  fi
}

idx=0; conflict=0
while IFS= read -r ip; do
  [[ -n "$ip" ]] || continue
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    fail "非法 IPv4：${ip}（安装脚本会跳过它）"; continue
  fi
  port=$(( PORT_BASE + idx ))
  idx=$(( idx + 1 ))
  if ! grep -qE "inet +${ip//./\\.}/" <<<"$ipdump"; then
    fail "IP ${ip} 不在本机任何网卡上（原脚本 hostname -I 常把 docker0/私网也算进来），绑上去起不来"
    continue
  fi
  out="$(curl --interface "$ip" -fsS --max-time 8 https://api.ip.sb/ip 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$out" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    pass "IP ${ip} 可用，出口 ${out} → 端口 ${port}"
  else
    fail "IP ${ip} 绑定了但出不去（curl --interface 失败），该端口必不通"
  fi
  if port_in_use "$port"; then
    fail "端口 ${port} 已被占用（对应 ${ip}）"; conflict=1
  fi
done <<<"$ip_text"
if (( idx > 0 )); then
  (( conflict == 0 )) && pass "端口 ${PORT_BASE}–$(( PORT_BASE + idx - 1 )) 空闲"
fi

# ---------------------------------------------------------------- 下载源
check_url() {
  local u="$1" code
  code="$(curl -fsSL -r 0-0 -o /dev/null -w '%{http_code}' --max-time 20 "$u" 2>/dev/null)"
  [[ "$code" =~ ^(200|206)$ ]]
}

LATEST_XRAY="$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
  | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1 || true)"
[[ -n "$LATEST_XRAY" ]] || LATEST_XRAY="26.11.9"
info "Xray 最新版本：v${LATEST_XRAY}"

if check_url "https://github.com/XTLS/Xray-core/releases/download/v${LATEST_XRAY}/Xray-linux-64.zip"; then
  pass "可下载最新版：v${LATEST_XRAY}"
else
  fail "下不到 v${LATEST_XRAY}（404/超时/被墙），安装时需用 XRAY_ZIP_URL=file:// 离线包"
fi
if check_url "https://gitee.com/sk_gg/sk5/releases/download/Xray1.6.1/Xray-linux-64.zip"; then
  info "gitee 镜像可达（仅含 1.6.1 旧版本）"
else
  warn "gitee 镜像不可达（不影响装最新版）"
fi

if curl -fsS --max-time 8 https://api.ip.sb/ip >/dev/null 2>&1; then
  pass "api.ip.sb 可达（脚本用它查出口 IP）"
else
  fail "api.ip.sb 不可达；原脚本会把出口 IP 全写成 UNKNOWN"
fi

# ---------------------------------------------------------------- 现状
if systemctl cat xray.service >/dev/null 2>&1; then
  warn "已存在 xray.service（当前：$(systemctl is-active xray 2>/dev/null)），重装会覆盖"
else
  pass "无旧 xray.service"
fi
[[ -f /etc/xray/serve.toml ]] && warn "已存在旧配置 /etc/xray/serve.toml（会被新脚本忽略，建议备份后删除）"
if [[ -x /root/e1/xray ]]; then
  info "已有二进制 /root/e1/xray：$(/root/e1/xray version 2>/dev/null | head -1)"
fi
if need getenforce; then
  s="$(getenforce 2>/dev/null)"
  [[ "$s" == "Enforcing" ]] && warn "SELinux=Enforcing，可能拦非标端口（可用 semanage port -a 放行）" || pass "SELinux=${s:-未知}"
fi

# ---------------------------------------------------------------- 结论
echo
printf '结果：PASS %d / WARN %d / FAIL %d\n' "$CNT_PASS" "$CNT_WARN" "$CNT_FAIL"
if (( CNT_FAIL > 0 )); then
  printf '\033[0;31m结论：不可直接安装，先修 FAIL 项\033[0m\n'; exit 2
elif (( CNT_WARN > 0 )); then
  printf '\033[0;33m结论：可以安装，但有 WARN 项需确认\033[0m\n'; exit 1
else
  printf '\033[0;32m结论：环境满足，可执行安装脚本\033[0m\n'; exit 0
fi
