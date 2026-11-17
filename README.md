# Tenda BE12 Pro — ImmortalWrt 25.12 固件

给 Tenda BE12 Pro（MT7987A / 512MB / 128MB SPI-NAND / MT7992E）编的
**ImmortalWrt 25.12** 固件。

> ## 这是什么分支
>
> 仓库有两个分支，**别搞混**：
>
> | 分支 | 基线 | 内核 | LuCI | 特点 |
> |------|------|------|------|------|
> | **`immortalwrt-25.12`**（当前） | ImmortalWrt 25.12 | 6.12 | 稳定版 | 固定可复现、国内软件源和插件全 |
> | `main` | OpenWrt SNAPSHOT | 6.18 | master（滚动） | 跟着主线走，修复最新 |
>
> 日常用哪个都行。**固件不要混刷** —— 两个分支的 rootfs 结构不同。

---

## 快速开始

```sh
git clone https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt.git
cd Tenda-BE12-Pro-OpenWrt
git checkout immortalwrt-25.12
./scripts/build.sh
```

CI 构建（推荐，约 80 分钟）：

```sh
# 在仓库页面 Actions 页面手动触发 build workflow
# 或用 API：
curl -X POST -H "Authorization: token <你的PAT>" \
  https://api.github.com/repos/r3zound/Tenda-BE12-Pro-OpenWrt/actions/workflows/build.yml/dispatches \
  -d '{"ref":"immortalwrt-25.12"}'
```

产物在 `bin/targets/mediatek/filogic/`：

```
openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade-YYYYMMDD.HHMM.bin
sha256sums
config.buildinfo
```

### 怎么认出固件是哪一版

**文件名后缀 = 编译时刻的北京时间**，形如 `-20261004.0031`。
同一个构建里，这两个地方的值保证一致：

| 位置 | 内容 | 举例 |
|---|---|---|
| LuCI → 系统 → 系统 | `OpenWrt SNAPSHOT <版本标识>` | `OpenWrt SNAPSHOT r1-9b95be917b-20261004.0031` |
| `.bin` 文件名后缀 | 同上的最后一段 | `-20261004.0031` |
| `config.buildinfo` 的 `build_stamp` / `built_at` | 同上，另给可读格式 | `2026-10-04 00:31 CST` |

```sh
# 想在设备上确认当前跑的是哪一版
cat /etc/openwrt_version      # r1-9b95be917b-20261004.0031
```

> 时间戳是在**构建机上算一次然后烧进固件**的，不是开机时按设备时钟算的。
> 所以改路由器时区不会让版本号变来变去。

---

## 这个分支做了什么（和 main 的差别）

ImmortalWrt 25.12 **官方没有这块板子**。本分支把它移植进来了，共三件：

| 文件 | 行数 | 作用 |
|------|------|------|
| `patches/immortalwrt-25.12/mt7987a-tenda-be12-pro.dts` | 390 | 设备树：GPIO、SPI-NAND 分区、AN8855 交换芯片、MT7992 无线、MAC 地址从 Factory 区读 |
| `patches/immortalwrt-25.12/board-port.mk` → `Build/tenda-mkdualimageheader` | 6 | 原厂私有镜像头（`"God1"` 魔数 + gzip CRC） |
| 同上 → `Device/tenda_be12-pro` | 14 | 板子定义：内存布局、打包方式 |

由 `scripts/apply-board-port.sh` 在克隆源码后自动追加，**幂等**。

> ⚠️ **`tenda-mkdualimageheader` 不能改也不能删** —— 原厂 bootloader
> 靠这个头识别镜像，缺了 sysupgrade 会直接失败。

MT7987 这颗 SoC 在 25.12 里是支持的（bpi-r4-lite、routerich_be7200 等），
缺的只是「这台机器的描述」，所以移植量很小。

### 已知的两个风险

1. **内核 6.12 vs 6.18** —— DTS 里用到的较新 binding
   （`airoha,an8855-ext-surge`、MT76 的 `band@0`/`band@1` 节点写法）
   6.12 未必认。构建失败先看 dtc 报的是哪个属性。
2. **aurora 主题** —— 锁的 commit 是给 LuCI master 编译的，
   25.12 是稳定版、API 可能有出入。症状是主题装上了但渲染不出来
   （下拉框空 / 界面花掉）。不行就回退到 argon。

---

## 刷机前必读

1. **校验 SHA256**
   ```sh
   cd bin/targets/mediatek/filogic && sha256sum -c sha256sums
   ```
2. 确认型号是 **Tenda BE12 Pro**
3. 从原厂固件进入需要**过渡固件**，步骤见 `main` 分支的 README §7
4. 升级时**不要勾选「保留设置」** —— 会带着旧配置，坑很多
5. **刷完不要用 `/etc/init.d/network restart`**！
   AN8855 交换芯片在 SNAPSHOT 系固件下对整栈软重置支持不良，
   整栈重启会导致 LAN 口失联、必须断电。一律用 `reload_config`（增量生效）

> 详细文档（坑位清单、救援流程、设计取舍）在 **`AGENTS.md`** 和 `main` 分支的 README。

---

## 刷机后

管理地址 `http://192.168.100.254`，双 WAN（电信 `eth2` / 移动 `lan3` PPPoE）、
主题、插件、mwan3 策略**都已预置**，正常情况下刷完即用。

- **无线**：`ASUS`
  - 自建固件（本地有 `preset/secrets.env`）：密码就是你自己的
  - 公开 Action 产物：密码是占位符 `CHANGE_ME_WIFI_PSK`，
    首启日志会告警，请先进 LuCI 改掉（否则等于半开放网络）
- **PPPoE**：自建固件已注入账号密码；公开产物为空，需在
  LuCI → 网络 → 接口 → WAN2 填写
- **mwan3**：已随固件安装并预置权重 3:1（电信:移动），无需再手动装
  ```sh
  mwan3 status                     # 两条线是否在线
  sh /usr/lib/tenda/install-mwan3.sh --check   # 体检（脚本仍保留，可重写配置）
  ```
- 预置是否生效，看日志：`logread -e tenda-preset`，
  出现「预置配置应用完成（4/4 项自检通过）」即正常
- 想恢复刷机前的完整状态（含 tailscale 节点身份、SSH 主机密钥）：
  见下节「配置预设与还原」

---

## 配置预设与还原

在用的路由器是 `192.168.100.254`（内核 6.18.54，262 个包）。它的配置按
「能固化就固化、不能固化就备份还原」分成两半：

| 部分 | 内容 | 位置 |
|---|---|---|
| 进固件 | 网络/无线/防火墙/主题/插件配置、双 WAN 策略 | `files/` + `package/tenda-preset/` |
| 进固件（可选） | PPPoE、WiFi、root 密码、WOL MAC | `preset/secrets.env` → 构建时注入 |
| 不进固件 | tailscale/zerotier 身份、SSH 主机密钥、shadow、rrd 历史 | `preset/backup/<时间>/sensitive/` |

```sh
# 1) 带自己的凭据编译
cp preset/secrets.env.example preset/secrets.env && vi preset/secrets.env
./scripts/build.sh

# 2) 刷机前抓快照
ROUTER_PASS='...' ./preset/scripts/backup-router-config.sh

# 3) 刷机后还原（先 --dry-run 看差异）
ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh preset/backup/<时间> --dry-run
ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh preset/backup/<时间>
```

详细说明（三层处置策略、注入机制、验证清单、已知边界）见
**[preset/README.md](preset/README.md)**；
刷机前的设备原貌（脱敏）见 `docs/config-snapshot/`。

---

## 不包含的东西

| 组件 | 状态 | 原因 |
|------|------|------|
| mwan3 | ✅ 已内置 | 官方版是 iptables 实现，在 fw4 上负载均衡已失效。改用 [dl12345/mwan3](https://github.com/dl12345/mwan3) 原生 nft 版，由 `scripts/fetch-extra-packages.sh` 直挂 `package/mwan3`，配置随固件预置 |
| passwall | ❌ 已排除 | 依赖解压 >150MB，超出 60MB overlay |
| 宽带凭据 | ❌ 永不进仓库 | 仓库公开 |

---

## 许可

源码遵循上游各自的许可。本仓库的预置配置与脚本部分见各文件头部声明。
