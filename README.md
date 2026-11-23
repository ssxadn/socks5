# 多 IP SOCKS5 出口 · 一键安装（Xray）

给有多块公网 IPv4 的 VPS 用：**每个 IP 起一个 SOCKS5 端口，连哪个端口就从哪个 IP 出去**。

```
客户端 ──socks5──► 服务器:5000 ──sendThrough 1.2.3.4──► Internet（出口 1.2.3.4）
                            :5001 ──sendThrough 5.6.7.8──► Internet（出口 5.6.7.8）
```

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssxadn/socks5/main/install.sh)
```

不想用进程替换（`sh` 环境）：

```bash
curl -fsSL https://raw.githubusercontent.com/ssxadn/socks5/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

国内 VPS 上 `raw.githubusercontent.com` 被墙时，用 jsDelivr 镜像：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/ssxadn/socks5@main/install.sh)
```

安装完会打印一张表：

```
出口IP           端口   用户     密码     绑定IP
198.51.100.7     5000   AbCdEf   GhIjKl   203.0.113.10
198.51.100.8     5001   MnOpQr   StUvWx   203.0.113.11

[+] 账号信息：/root/2026-11-23_16_40_00_socks5_ip.txt
[+] 全部 2 个 SOCKS5 已监听
```

## 装之前先自检（可选）

只读，不改任何东西，30 秒告诉你这台机器能不能装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssxadn/socks5/main/precheck.sh)
```

| 输出 | 含义 |
|---|---|
| `结论：环境满足` | 直接装 |
| `结论：可以安装，但有 WARN` | 看 WARN 项（一般是防火墙不是 firewalld） |
| `结论：不可直接安装` | 先修 FAIL 项，通常是 IP 没绑在网卡上或端口被占 |

## 参数

全部通过环境变量传入，可组合：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT_BASE` | `5000` | 起始端口，第 n 个 IP 用 `PORT_BASE+n` |
| `LISTEN_IPS` | 自动探测 | 手动指定，空格或逗号分隔 |
| `XRAY_VERSION` | `26.11.9` | 当前最新稳定版；填 `latest` 自动取最新 |
| `XRAY_ZIP_URL` | 官方 + gitee 镜像 | 支持 `file://` 离线安装 |
| `XRAY_SHA256` | 空 | 期望哈希；官方源会自动抓 `.dgst` 校验 |

```bash
PORT_BASE=5100 LISTEN_IPS="1.2.3.4 5.6.7.8" bash install.sh
XRAY_VERSION=latest bash install.sh
XRAY_ZIP_URL=file:///root/Xray-linux-64.zip bash install.sh   # 完全离线
```

## 产物

| 路径 | 内容 |
|---|---|
| `/root/e1/xray` | 二进制 |
| `/etc/xray/serve.json` | 配置，权限 600 |
| `/etc/systemd/system/xray.service` | systemd 服务 |
| `/root/<时间>_socks5_ip.txt` | `出口IP:端口:用户名:密码`，一行一个 |

配置长这样（每个 IP 一组，`tag` 一一对应）：

```json
{
  "inbounds": [
    {"listen":"203.0.113.10","port":5000,"protocol":"socks","tag":"in-1",
     "settings":{"auth":"password","udp":true,
                 "accounts":[{"user":"AbCdEf","pass":"GhIjKl"}]}}
  ],
  "outbounds": [
    {"sendThrough":"203.0.113.10","protocol":"freedom","tag":"out-1"}
  ],
  "routing": {"rules":[{"type":"field","inboundTag":["in-1"],"outboundTag":"out-1"}]}
}
```

## 验证

```bash
systemctl status xray --no-pager
ss -lntp | grep -E ':(50[0-9][0-9])\b'
journalctl -u xray -n 30 --no-pager

# 命令行自测：应返回该端口对应的出口 IP
curl -x socks5h://用户名:密码@服务器IP:5000 https://api.ip.sb/ip
```

云厂商（阿里云/腾讯云/Oracle/AWS）的安全组要自己放行 `PORT_BASE` 起的端口段，脚本只改服务器内部的 firewalld/ufw。

## 相对网上流传版本的修正

| 问题 | 这里怎么处理 |
|---|---|
| 写死 `yum`，Debian 直接失败 | 自动识别 dnf / yum / apt |
| 写死 `Xray-linux-64.zip`，ARM 机器 `Exec format error` | 按 `uname -m` 选 amd64 / arm64 包 |
| 清空 `iptables`、删 firewalld 规则 | 完全不碰，只放行自己的端口段 |
| 没有 `xray -test`，配置错就无限重启 | 启动前强制校验，失败不上线 |
| 端口被占也照装，整个服务起不来 | 装前逐个检查，冲突直接中止 |
| `hostname -I` 混入 docker0/私网 | `ip -o -4 addr show scope global` + 过滤虚拟网卡 |
| 二进制无任何校验 | 官方源自动抓同名 `.dgst` 做 sha256 |
| 失败也打印成功 | 每步校验，最后逐端口确认监听，失败返回非 0 |

## 常见问题

**装完连不上**
1. `ss -lntp | grep :5000` 看有没有监听
2. 云安全组放行了吗
3. `curl -x socks5h://...` 在服务器本机试，排除客户端问题

**端口被占**
`PORT_BASE=5100` 换个段重跑。

**下载失败 / 被墙**
自己下 `Xray-linux-64.zip` 传到 `/root/`，然后 `XRAY_ZIP_URL=file:///root/Xray-linux-64.zip bash install.sh`。

**`$'\r': command not found`**
文件被转成了 CRLF：`sed -i 's/\r$//' install.sh`。

## 卸载

```bash
systemctl disable --now xray
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload
rm -rf /etc/xray /root/e1

firewall-cmd --permanent --remove-port=5000-5005/{tcp,udp} && firewall-cmd --reload
```

## 安全提示

- 脚本需要 **root** 权限，会写 `/etc` 与 `/root`，跑之前请先读代码。
- 公网暴露 SOCKS5 等于开放代理：密码只有 6 位字母、无 TLS、UDP 全开。**建议**加来源 IP 白名单（`firewall-cmd --add-rich-rule`）或改用 VLESS+REALITY。
- 默认安装 **v26.11.9**（2026-11-09 发布，当前最新稳定版）；想跟进新版用 `XRAY_VERSION=latest`。

## License

MIT
