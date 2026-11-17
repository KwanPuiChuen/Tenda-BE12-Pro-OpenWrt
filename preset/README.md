# 配置预设与还原（preset）

本目录解决一件事：**把在用路由器（Tenda BE12 Pro @ 192.168.100.254）的现状带进新固件**，
能固化的固化，固化不了的可一键还原。

数据来源：2026-11-17 实机采集（内核 6.18.54，262 个包，overlay 17.5M/42.1M）。

---

## 1. 三层处置策略

| 配置类别 | 具体项 | 处置方式 | 落点 |
|---|---|---|---|
| **A. 可直接覆盖** | `network`、`wireless` | 随包直装（无 apk 归属冲突） | `package/tenda-preset/files/etc/config/` |
| **B. 有归属、只能首启写** | `dhcp`、`system`、`firewall`、`dropbear` | 首启 `uci batch`（普通文件写入，绕开归属检查） | `/etc/uci-defaults/99-tenda-custom` + `99-tenda-preset` |
| **C. 插件配置** | `luci`、`argon`、`mwan3`、`tailscale`、`zerotier`、`frpc`、`collectd`、`luci_statistics`、`luci-wol`、`etherwake`、`attendedsysupgrade`、`uhttpd` | 随包放到非冲突路径，首启 `cp` 进 `/etc/config` | `files/usr/share/tenda/config/` → `99-tenda-preset` |
| **D. 凭据** | PPPoE 账号密码、WiFi PSK、root hash、WOL MAC | 构建时注入 `secrets.env`，首启读取后即刻移出 | `scripts/inject-secrets.sh` |
| **E. 不能打包** | tailscale 节点身份、zerotier identity、dropbear 主机密钥、shadow、rrd 历史、运行态 | 备份 → 刷机后还原 | `preset/scripts/backup-*` / `restore-*` |

为什么不能全部塞进 `/etc/config`：apk 严格校验文件归属。
`dhcp` 属 dnsmasq、`firewall` 属 firewall4、`luci` 属 luci-base、`dropbear` 属 dropbear，
别的包直接覆盖会报 `trying to overwrite etc/config/xxx owned by yyy`，
`package/install` 整体失败，固件根本产不出来（Run #9 实测）。
`network` 与 `wireless` 无归属声明，才能随包直装。

为什么 `wireless` 必须直装、不能只靠首启 `uci set`：
该文件默认不在 rootfs 里，由 `/sbin/wifi config` 运行时生成；
缺文件时 `uci set` 会造出段类型错误的伪段，随后被整体洗掉 ——
现象是「配了 WiFi 却没生效、设备以开放网络上线」（坑 10）。

---

## 2. 固化进固件的内容

### 2.1 网络（与实机一致）

- LAN `192.168.100.254/24`，DNS `223.5.5.5` / `119.29.29.29`
- WAN1 = `eth2`（2.5G，电信光猫路由模式，DHCP，metric 10）
- WAN2 = `lan3`（1G，移动光猫桥接，PPPoE，metric 20）
- `tailscale0` 无协议接口（供 tailscale 插件接管）
- 双 WAN 同属 `wan` 防火墙区，mwan3 权重 **电信:移动 = 3:1**

### 2.2 无线

| 频段 | 信道 | 带宽 | 监管域 | SSID |
|---|---|---|---|---|
| 2.4G（radio0） | 1 | EHT20 | CN | ASUS |
| 5G（radio1） | 36 | EHT160 | AU | ASUS |

> 5G 用 `country AU` 是为了开出 160MHz（36–64 连续信道）。国内使用属超监管范围，
> 对功率/DFS 行为无 CN 约束。要合规就改 `country 'CN'` + `htmode 'EHT80'`。

### 2.3 主题与界面

- 默认主题 **Aurora**（`/luci-static/aurora`），Argon 保留可选
- Argon：深色模糊 10、透明度 0.5、`online_wallpaper 'bing'`
- 简体中文，`ttylogin 0`（串口不弹登录）、`conloglevel 8`（调试级日志）

### 2.4 插件

mwan3（3.6.12）、tailscale（1.104.4）、zerotier（1.16.2）、frpc（0.71.0）、
collectd + rrdtool 统计（CPU/接口/无线/负载/内存/网络）、网络唤醒（WOL）、
attendedsysupgrade（在线升级）。

`zerotier`、`frpc` 默认 `enabled 0` —— 装好不启用，避免每次开机去连一个不存在的服务端。

### 2.5 防火墙

- `flow_offloading=0`：卸载会在 ingress 把连接钉死，绕过 mwan3 的 mangle 链，双 WAN 直接失效
- `fullcone=1`：改善 NAT 类型（游戏/P2P/视频通话）
- `tailscale` 独立区 + 三条 forwarding（ts↔lan、ts→wan）
- 保留 IPSec 放行（ESP / UDP 500），与 IPsec 组网方案配套

---

## 3. 凭据注入

```sh
cp preset/secrets.env.example preset/secrets.env
vi preset/secrets.env          # 填 PPPoE / WiFi / WOL / root
./scripts/build.sh             # 自动调用 scripts/inject-secrets.sh
```

- `secrets.env` 已在 `.gitignore`，不会入库
- 构建产物为固件内 `/usr/share/tenda/secrets.env`（0600）
- 首启 `99-tenda-preset` 读取后立即 `mv` 到 `/tmp`（重启即清），**不留备份**
- CI 上用 `KEEP_SECRETS=0` 或不提供文件 → 产出无凭据固件，WiFi 为占位密码
- 公开仓库只保留 `secrets.env.example`（全空）

注入的四类值：`PPPOE_USER/PPPOE_PASS`、`WIFI_SSID/WIFI_PSK`、`WOL_MAC`、`ROOT_PASSWORD_HASH`（或 `ROOT_PASSWORD`）。

---

## 4. 备份（刷机前）

```sh
ROUTER_PASS='...' ./preset/scripts/backup-router-config.sh
```

密码只经环境变量传递，不写进脚本、不落盘。产物（默认 `preset/backup/<时间>/`，已 gitignore）：

| 文件 | 内容 |
|---|---|
| `etc-config.tar.gz` | `/etc/config` 全量 |
| `uci-export.txt` | 可 diff 的纯文本 |
| `packages.txt` | 262 个已装包 |
| `board.json` | 接口/无线硬件路径 |
| `sensitive/shadow` | root 密码 hash |
| `sensitive/dropbear/` | SSH 主机密钥（还原后指纹不变，客户端不告警） |
| `sensitive/tailscale/` | 节点身份（还原后免重新登录） |
| `MANIFEST.txt` / `SHA256SUMS` | 元信息与校验 |

`sensitive/` 等价于「设备身份 + 登录凭据」，只放私有位置。

---

## 5. 还原（刷机后）

```sh
# 先看差异，不改动
ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh preset/backup/<时间> --dry-run

# 正式还原
ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh preset/backup/<时间>
```

脚本会先把当前 `/etc/config` 打包留底，再覆盖、还原 shadow/dropbear/tailscale，最后 `reload_config`。

**三条硬规则**：

1. 还原 `network` 后只用 `reload_config`。`/etc/init.d/network restart` 在双 WAN 下会让 netifd
   与 mwan3 抢接口，表现为 WAN 长时间拿不到地址。
2. 不要清 `/etc/config/wireless` 再 `wifi reload`（原因见上文坑 10）。
3. 首次还原先 `--dry-run`。

---

## 6. 刷机后验证清单

| 项 | 命令 / 位置 | 期望 |
|---|---|---|
| LAN 地址 | `ip -4 addr show br-lan` | 192.168.100.254/24 |
| WAN1 | `ubus call network.interface.wan status` | 有 IPv4 地址 |
| WAN2 | `ubus call network.interface.wan2 status` | PPPoE 已连接 |
| 负载均衡 | `mwan3 status` | 两条在线，权重 3:1 |
| WiFi | `uci show wireless \| grep -E 'ssid\|key'` | ASUS / 密码已生效 |
| 主题 | LuCI 首页 | Aurora 深色 |
| 插件菜单 | 网络 → 负载均衡 / 网络唤醒；统计 → 图表 | 均在 |
| 离线卸载 | `cat /proc/sys/net/netfilter/nf_conntrack_udp_timeout` | 正常读取（flow offload 未抢占） |
| 预置自检 | `logread -e tenda-preset` | 「预置配置应用完成（4/4 项自检通过）」 |

---

## 7. 已知边界

- **tailscale / zerotier 身份**：不随固件打包（等于私钥）。要么还原 `sensitive/`，要么刷后重新登录。
- **PPPoE 密码**：公开构建为空，必须在 LuCI「接口 → WAN2」填。
- **rrd 历史数据**（`/etc/collectd/`、`/srv/rrd`）：不打包，统计图从零开始。
- **代理类插件**（passwall / sing-box / xray）：本固件明确排除，配置自然不迁移。
- **`country AU`**：仅为 160MHz，合规性自负。
- **固件版本差**：实机内核 6.18.54，预置包按 snapshot 6.18.60 编译；`collectd` 配置项在
  小版本间有增减，首启若某项不被识别，`luci-app-statistics` 页面会显示为默认值，不影响启动。