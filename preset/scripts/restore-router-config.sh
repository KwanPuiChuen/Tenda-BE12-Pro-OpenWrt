#!/bin/sh
# =============================================================================
# preset/scripts/restore-router-config.sh
# -----------------------------------------------------------------------------
# 把 backup-router-config.sh 的快照还原到刚刷好的路由器。
#
# 用法：
#   ROUTER_PASS='...' ./preset/scripts/restore-router-config.sh <备份目录> [--dry-run]
#
# ⚠️ 三条硬规则（踩过，别改）：
#   1. 还原 network 后只用 `reload_config`。`/etc/init.d/network restart`
#      在双 WAN 下会让 netifd 与 mwan3 抢接口，表现为 WAN 长时间没有地址。
#   2. 不要 `wifi reload` 前清 /etc/config/wireless —— 该文件不在 rootfs 中，
#      由 /sbin/wifi config 生成，缺段类型会造伪段、静默失效（坑 10）。
#   3. 刷机后第一次还原，先跑 --dry-run 看差异，再正式执行。
# =============================================================================

set -eu

SRC="${1:?用法: restore-router-config.sh <备份目录> [--dry-run]}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

HOST="${ROUTER_HOST:-192.168.100.254}"
USER_="${ROUTER_USER:-root}"
PORT="${SSH_PORT:-22}"
: "${ROUTER_PASS:?必须通过环境变量 ROUTER_PASS 提供密码}"

[ -d "$SRC" ] || { echo "✗ 备份目录不存在: $SRC"; exit 1; }
[ -f "$SRC/etc-config.tar.gz" ] || { echo "✗ 缺少 etc-config.tar.gz"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p $PORT"
rsh() { sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "$USER_@$HOST" "$@"; }
rcp() { sshpass -p "$ROUTER_PASS" scp $SSH_OPTS -q "$@"; }

echo "▸ 目标 $USER_@$HOST:$PORT"
rsh 'echo ok' >/dev/null || { echo "✗ SSH 连接失败"; exit 1; }

TMPD="/tmp/restore-$$"
rsh "mkdir -p $TMPD && chmod 700 $TMPD"

echo "▸ 上传快照"
rcp "$SRC/etc-config.tar.gz" "$USER_@$HOST:$TMPD/"
[ -f "$SRC/sensitive/shadow" ] && rcp "$SRC/sensitive/shadow" "$USER_@$HOST:$TMPD/shadow"
[ -f "$SRC/sensitive/dropbear/dropbear.tar.gz" ] && rcp "$SRC/sensitive/dropbear/dropbear.tar.gz" "$USER_@$HOST:$TMPD/"
[ -f "$SRC/sensitive/tailscale/tailscaled.state" ] && rcp "$SRC/sensitive/tailscale/tailscaled.state" "$USER_@$HOST:$TMPD/"

if [ "$DRY" = "1" ]; then
	echo "▸ dry-run：对比配置差异"
	rsh "cd $TMPD && tar -xzf etc-config.tar.gz && for f in config/*; do n=\$(basename \$f); if [ -f /etc/\$f ]; then echo \"--- \$n\"; diff -u /etc/\$f \$f || true; else echo \"+++ \$n 新增\"; fi; done" | head -200
	echo "▸ dry-run 结束，未做任何修改"
	rsh "mv -f $TMPD /tmp/.restore-dryrun.$$ 2>/dev/null || true"
	exit 0
fi

echo "▸ 备份当前 /etc/config → $TMPD/etc-config.before.tar.gz"
rsh "tar -czf $TMPD/etc-config.before.tar.gz -C /etc config"

echo "▸ 写入配置"
rsh "cd $TMPD && tar -xzf etc-config.tar.gz && cp -rf config/. /etc/config/ && chmod 0644 /etc/config/*"

if [ -f "$SRC/sensitive/shadow" ]; then
	echo "▸ 还原 root 密码 hash"
	rsh "cp -f $TMPD/shadow /etc/shadow && chmod 0600 /etc/shadow"
fi

if [ -f "$SRC/sensitive/dropbear/dropbear.tar.gz" ]; then
	echo "▸ 还原 SSH 主机密钥"
	rsh "mkdir -p /etc/dropbear && tar -xzf $TMPD/dropbear.tar.gz -C /etc/dropbear && chmod 0700 /etc/dropbear"
fi

if [ -f "$SRC/sensitive/tailscale/tailscaled.state" ]; then
	echo "▸ 还原 tailscale 节点身份"
	rsh "mkdir -p /etc/tailscale && cp -f $TMPD/tailscaled.state /etc/tailscale/tailscaled.state && chmod 0600 /etc/tailscale/tailscaled.state"
fi

echo "▸ 应用配置（reload_config，不用 network restart）"
rsh "reload_config"
sleep 3
rsh "/etc/init.d/log restart 2>/dev/null; /etc/init.d/dnsmasq reload 2>/dev/null; /etc/init.d/firewall reload 2>/dev/null; wifi reload 2>/dev/null"
rsh "/etc/init.d/tailscaled restart 2>/dev/null || true"

echo "▸ 清理临时目录"
rsh "mv -f $TMPD /tmp/.restore-done.$$ 2>/dev/null || true"

echo "▸ 复核"
rsh 'echo "--- WAN 地址"; ubus call network.interface.wan status 2>/dev/null | grep -o "\"address\": \"[^\"]*\"" || true;
     echo "--- WAN2 地址"; ubus call network.interface.wan2 status 2>/dev/null | grep -o "\"address\": \"[^\"]*\"" || true;
     echo "--- WiFi"; uci show wireless 2>/dev/null | grep -E "ssid|key" | sed "s/key=.*/key=****/";
     echo "--- mwan3"; mwan3 status 2>/dev/null | head -8 || true'

echo "✓ 还原完成。请用浏览器打开 http://$HOST 核对主题与插件菜单。"