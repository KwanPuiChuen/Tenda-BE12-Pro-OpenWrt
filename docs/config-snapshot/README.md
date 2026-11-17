# 刷机前配置快照（脱敏）

采集时间：2026-11-17，设备：Tenda BE12 Pro @ 192.168.100.254
固件：ImmortalWrt/OpenWrt SNAPSHOT，内核 6.18.54，已装 262 包，overlay 17.5M / 42.1M。

| 文件 | 说明 |
|---|---|
| `uci-export-redacted.txt` | 全量 `uci export` 脱敏文本（817 行），用于刷机后逐项核对 |
| `packages.txt` | 已装包名（去版本号，262 条） |
| `packages-missing-in-base.txt` | 实机有、`configs/base.config` 未显式声明的包（多为自动依赖） |

## 脱敏规则

- `password` / `key` / `username` / `secret` / `token` / `psk` / `mac` → `<REDACTED>`
- 形如 `1[3-9]xxxxxxxxx@xxx` 的宽带账号 → `<REDACTED_USER>`
- 不含：`/etc/shadow`、dropbear 主机密钥、`tailscaled.state`、zerotier identity

本目录可作为「刷机前设备长什么样」的公开留档，**不可直接导入**（值已被替换）。
未脱敏快照在 `preset/backup/<时间>/`，不入库。