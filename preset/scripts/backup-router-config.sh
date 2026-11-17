#!/bin/sh
# =============================================================================
# preset/scripts/backup-router-config.sh
# -----------------------------------------------------------------------------
# 从在用路由器抓一份「可原样还原」的配置快照。
#
# 与固件预置的分工：
#   能固化的（network / wireless / firewall / 主题 / 插件配置）→ 已进固件
#   不能固化的（节点身份、主机密钥、shadow、运行态）        → 本脚本产出备份
#
# 用法：
#   ROUTER_PASS='...' ./preset/scripts/backup-router-config.sh [输出目录]
#
# 环境变量：
#   ROUTER_HOST  默认 192.168.100.254
#   ROUTER_USER  默认 root
#   ROUTER_PASS  必填（不写入任何文件，仅经 sshpass 传给 ssh）
#   SSH_PORT     默认 22
#   WITH_STATE   1=连 tailscale/zerotier 身份一起抓（默认 1，属高敏）
#
# 产物结构：
#   <out>/etc-config.tar.gz      /etc/config 全量
#   <out>/uci-export.txt         uci export 纯文本（易 diff、易审）
#   <out>/packages.txt           apk 已装清单（还原后比对用）
#   <out>/board.json             硬件描述（核对接口/无线路径）
#   <out>/sensitive/shadow       密码 hash
#   <out>/sensitive/dropbear/    SSH 主机密钥
#   <out>/sensitive/tailscale/   tailscaled.state（WITH_STATE=1）
#   <out>/sensitive/zerotier/    identity.secret 等
#   <out>/MANIFEST.txt + SHA256SUMS
# =============================================================================

set -eu

HOST="${ROUTER_HOST:-192.168.100.254}"
USER_="${ROUTER_USER:-root}"
PORT="${SSH_PORT:-22}"
WITH_STATE="${WITH_STATE:-1}"
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/backup/$(date +%Y%m%d-%H%M%S)}"

: "${ROUTER_PASS:?必须通过环境变量 ROUTER_PASS 提供密码（不要写进脚本）}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p $PORT"
rsh() { sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "$USER_@$HOST" "$@"; }

echo "▸ 目标 $USER_@$HOST:$PORT"
echo "▸ 输出 $OUT"

rsh 'echo ok' >/dev/null || { echo "✗ SSH 连接失败，检查地址/密码/端口"; exit 1; }

mkdir -p "$OUT/sensitive"
umask 077

echo "▸ 采集 /etc/config"
rsh 'tar -czf - -C /etc config' >"$OUT/etc-config.tar.gz"

echo "▸ 采集 uci export"
rsh 'uci export' >"$OUT/uci-export.txt"

echo "▸ 采集已装包清单"
rsh 'apk list --installed 2>/dev/null | awk "{print \$1}" | sort' >"$OUT/packages.txt" || \
	rsh 'opkg list-installed | awk "{print \$1}" | sort' >"$OUT/packages.txt"

echo "▸ 采集 board.json（接口/无线硬件描述）"
rsh 'cat /etc/board.json' >"$OUT/board.json"

echo "▸ 采集版本信息"
rsh 'ubus call system board 2>/dev/null || true' >"$OUT/system-board.json"

echo "▸ 采集敏感项"
rsh 'cat /etc/shadow' >"$OUT/sensitive/shadow"

if rsh 'test -d /etc/dropbear'; then
	mkdir -p "$OUT/sensitive/dropbear"
	rsh 'tar -czf - -C /etc/dropbear .' >"$OUT/sensitive/dropbear/dropbear.tar.gz"
	echo "  · dropbear 主机密钥"
fi

if [ "$WITH_STATE" = "1" ]; then
	if rsh 'test -f /etc/tailscale/tailscaled.state'; then
		mkdir -p "$OUT/sensitive/tailscale"
		rsh 'cat /etc/tailscale/tailscaled.state' >"$OUT/sensitive/tailscale/tailscaled.state"
		echo "  · tailscale 节点身份（还原后无需重新登录）"
	fi
	if rsh 'test -d /var/lib/zerotier-one'; then
		mkdir -p "$OUT/sensitive/zerotier"
		rsh 'tar -czf - -C /var/lib/zerotier-one . 2>/dev/null || true' \
			>"$OUT/sensitive/zerotier/identity.tar.gz"
		echo "  · zerotier 身份"
	fi
fi

cat >"$OUT/MANIFEST.txt" <<EOF
Tenda BE12 Pro 配置快照
时间      : $(date -u +%Y-%m-%dT%H:%M:%SZ)
来源      : $USER_@$HOST:$PORT
固件版本  : $(rsh '. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_DESCRIPTION"' || echo unknown)
内核      : $(rsh 'uname -r' || echo unknown)

还原方法（刷机后执行）：
  ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh $OUT

⚠️ sensitive/ 内含等价于「设备身份 + 登录凭据」的数据：
   shadow          → root 密码 hash
   dropbear/       → SSH 主机密钥（还原后指纹不变，客户端不会告警）
   tailscale/      → 节点私钥，拿到即可冒用你的 tailnet 身份
   zerotier/       → 同上
   请只保存在私有位置，切勿提交公开仓库。
EOF

(cd "$OUT" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + | sort -k2) >"$OUT/SHA256SUMS"

echo "✓ 完成：$OUT"
echo "  敏感目录请自行加密保管：$OUT/sensitive"