#!/bin/sh
# =============================================================================
# scripts/inject-secrets.sh — 把本地凭据注入待打包的预置目录
# -----------------------------------------------------------------------------
# 输入：preset/secrets.env（默认，git 忽略）或环境变量 SECRETS_FILE 指定路径
# 输出：package/tenda-preset/files/usr/share/tenda/secrets.env（0600，随固件下发）
#
# 设计取舍：
#   · 凭据不进 /etc/config（那是 conffiles，且会被 uci 回显到 LuCI 备份），
#     而是单独一个 0600 文件，由首启脚本 99-tenda-preset 读完即移到 /tmp。
#   · 公开构建没有 secrets.env → 直接跳过，固件保持占位符，不会报错。
#   · 全程不回显任何值，避免 CI 日志泄漏（GitHub Actions 掩码只覆盖显式 ::add-mask::）。
# =============================================================================

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SECRETS_FILE:-$ROOT/preset/secrets.env}"
OUT="$ROOT/package/tenda-preset/files/usr/share/tenda/secrets.env"
KEEP="${KEEP_SECRETS:-1}"

# 不打包模式：把已有产物移出（不用 rm，便于事后排查）
if [ "$KEEP" = "0" ]; then
	if [ -f "$OUT" ]; then
		mkdir -p "$ROOT/.cache"
		mv -f "$OUT" "$ROOT/.cache/secrets.env.stale.$$"
		chmod 600 "$ROOT/.cache/secrets.env.stale.$$" 2>/dev/null || true
		echo "▸ KEEP_SECRETS=0：已跳过凭据打包"
	fi
	exit 0
fi

if [ ! -f "$SRC" ]; then
	echo "▸ 未找到 $SRC —— 公开构建，产出无凭据固件"
	echo "  需要打包自己的配置：cp preset/secrets.env.example preset/secrets.env 后填写"
	exit 0
fi

umask 077
TMP="$OUT.tmp.$$"
mkdir -p "$(dirname "$OUT")"

{
	echo "# 由 scripts/inject-secrets.sh 生成 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "# 首启时被 /etc/uci-defaults/99-tenda-preset 读取并移出 /usr/share"
	grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SRC" || true
} >"$TMP"

mv -f "$TMP" "$OUT"
chmod 0600 "$OUT"

# 必填项体检（只报缺哪个键，不打印值）
miss=""
for k in PPPOE_USER PPPOE_PASS WIFI_PSK; do
	if ! grep -qE "^${k}=.+" "$OUT"; then
		miss="$miss $k"
	fi
done
if [ -n "$miss" ]; then
	echo "▸ ⚠️ 以下键为空，固件里将保留占位/空值:$miss"
else
	echo "▸ 凭据已注入（4 类：PPPoE / WiFi / WOL / root）"
fi

echo "▸ 输出：package/tenda-preset/files/usr/share/tenda/secrets.env (0600)"