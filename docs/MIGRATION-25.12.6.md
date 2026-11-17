# 基线迁移：OpenWrt 官方 releases/25.12.6

> 执行日期：2026-11-17　｜　目标分支：`openwrt-25.12`（GitHub 默认分支）
> 一句话：**整个仓库从 ImmortalWrt 25.12 分支切到 OpenWrt 官方 v25.12.6，
> 并把 SNAPSHOT 产线彻底移除，只留一版可刷固件。**

---

## 1. 为什么切

| 维度 | 旧（ImmortalWrt `openwrt-25.12`） | 新（OpenWrt 官方 `v25.12.6`） |
|---|---|---|
| 基线性质 | 滚动分支，随时接受新提交 | 固定 tag，commit `64900e756e` |
| 可复现性 | 每次 clone 可能不同 | 逐字节一致 |
| 内核 | 6.12（ImmortalWrt 侧 patch 集） | 6.12（官方） |
| feeds | immortalwrt/luci + immortalwrt/packages | openwrt/luci + openwrt/packages |
| 官方支持 | 板子由社区移植 | 板子仍无（需自带三件套） |

锁 tag 而不是锁分支，是为了让「今天编出来的固件」和「三个月后编出来的固件」
在源码层面完全一致。分支名只用于给人看，`versions.lock` 里的 40 位 SHA 才是真相。

---

## 2. 变更清单（文件级）

| 文件 | 变更 |
|---|---|
| `versions.lock` | 基线改 `OPENWRT_TAG=v25.12.6` + `OPENWRT_COMMIT=64900e756e…`；feeds 改 `openwrt/luci`@`5331286…`、`openwrt/packages`@`d0c8b473…`；板级移植说明改为「25.12.6 仍需自带」 |
| `patches/immortalwrt-25.12/` → `patches/openwrt-25.12/` | 目录改名，DTS 与 `board-port.mk` 内容不变 |
| `scripts/apply-board-port.sh` | 补丁路径、错误提示同步改名 |
| `scripts/gen-feeds.sh` / `gen-config.sh` / `build.sh` / `build-repo.sh` / `publish-repo.sh` | 基线文案与路径同步；源目录随分支名变为 `openwrt-25.12` |
| `.github/workflows/build.yml` | **删除周一 SNAPSHOT 定时构建**；`variant` 默认值 `main` → `25.12.6`；日志文案改「OpenWrt 25.12.6 <版本标识>」；只保留 `workflow_dispatch` 与 tag 触发 |
| `configs/base.config` | 删除官方基线中不存在的符号：`luci-mod-dhcp`、`luci-mod-firewall`（官方由 `luci-mod-network` 统一提供）、`usb-modeswitch`（官方 packages 无此包）、`lede`（无意义符号）；注释更新 |
| `scripts/verify-firmware.sh` | 版本串校验从「不含 SNAPSHOT rN-hash」改为「必须是 OpenWrt 25.12.6 + 时间戳」 |
| `README.md` | 双分支表格换成单产线说明；「已知的两个风险」换成移植完备性核对表 |
| `AGENTS.md` | 顶部新增「2026-11-17 基线变更」四条约；速览表三行更新 |
| `docs/HANDOVER-MIGRATION.md` | 加「历史文档」横幅（内容是 ImmortalWrt 时代的记录，保留作证据） |

---

## 3. 移植完备性核对（逐项实测，非推断）

对象：OpenWrt `v25.12.6`（commit `64900e756efa667774214f9c6b17c113222e01f7`，内核 6.12）

| 检查项 | 方法 | 结果 |
|---|---|---|
| 官方是否已收编该板 | `target/linux/mediatek/image/filogic.mk` 全量 grep `tenda` | ❌ 0 命中，DTS 也不存在 → 三件套必须自带 |
| DTS 与上游一致性 | 与 `openwrt/openwrt` main 分支同名文件比对 | ✅ 390 行逐字节一致 |
| DTS 引用的 label | 逐个对照 `mt7987a.dtsi` / `mt7987.dtsi` | ✅ 32 个 label 全部存在 |
| AN8855 交换芯片 | `patches-6.12/737-net-dsa-add-Airoha-AN8855.patch` + `filogic/config-6.12` | ✅ patch 在，`NET_DSA_AN8855`/`MFD_AIROHA_AN8855`/`NVMEM_AN8855_EFUSE`/`AIR_AN8855_PHY`/`MDIO_AN8855` 均 `=y` |
| MT7987 2.5G PHY | `patches-6.12/752-net-phy-mediatek-i2p5g-add-support-for-mt7987.patch` | ✅ 存在 |
| `DEVICE_PACKAGES` 四包 | `kmod-phy-airoha-en8811h`、`mt7987-2p5g-phy-firmware`、`airoha-en8811h-firmware`、`kmod-mt7992-firmware` | ✅ 均有定义 |
| `band@0` / `band@1` | 板级 DTS 自定义节点 vs dtsi | ✅ 无冲突 |
| `base.config` 74 个包符号 | 对照 openwrt/openwrt `package/`、openwrt/luci、openwrt/packages 的 v25.12.6/25.12 树 | ✅ 已剔除 4 个不存在的符号；其余为子包（`kmod-*`/`ppp-mod-*`/`collectd-mod-*`/`frpc`/`ip-full`/`uhttpd-mod-ubus`）或 i18n 自动生成包，父包均在 |
| 第三方主题 | `fetch-extra-packages.sh` 挂 `package/` | ⚠️ argon/aurora/all 三个仍走外部仓库锁 SHA；aurora 是给 LuCI master 编的，25.12 上可能渲染异常（唯一未消除风险） |

**结论**：设备树与内核依赖层面已完备，可进入编译验证。剩余风险只在第三方主题渲染。

---

## 4. SNAPSHOT 移除清单

| 项 | 处理 |
|---|---|
| 远端分支 `main` | 删除（SNAPSHOT 产线） |
| 远端分支 `immortalwrt-25.12` | 删除（已被 `openwrt-25.12` 取代） |
| 周一 03:17 UTC 定时构建 | 从 `build.yml` 删除 |
| `variant: main` 默认值 | 改 `25.12.6` |
| Release / tag | 仓库原本无 tag、无 Release；本次打 `v25.12.6-1` 产生**唯一**一版固件产物 |

---

## 5. 构建与验证

```sh
# 本地（需要能访问 github；慢网可用 CI 代替）
./scripts/gen-feeds.sh          # 生成 feeds.conf，校验 versions.lock
./scripts/apply-board-port.sh   # 注入 DTS + 私有镜像头 + Device 定义
./scripts/gen-config.sh         # 合并 base.config → make defconfig
make -j$(nproc)                 # 或直接交给 CI

# CI
gh workflow run build.yml -f variant=25.12.6
# 或：git tag v25.12.6-1 && git push origin v25.12.6-1   → 自动构建并发布 Release
```

刷机注意（与旧版一致，未变）：

1. 校验 `sha256sum -c sha256sums`
2. 首次从原厂固件进入需过渡固件（见 `AGENTS.md` §7 阶段一）
3. 升级**不要勾选「保留设置」**
4. 刷完不要 `network restart` 整栈重启（AN8855 软重置问题），用 `reload_config`