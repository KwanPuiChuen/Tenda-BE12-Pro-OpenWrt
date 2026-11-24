#!/usr/bin/env bash
# Apply pinned SONiC Full Cone NAT integration to OpenWrt 25.12 / Linux 6.12.
# Upstream: mufeng05/openwrt-sonic-fullcone
# Pinned upstream commit: f87ac2a95b77270af9180a16590cc548617336a1
# This build uses nftables/firewall4 only; iptables/fw3 patches are intentionally omitted.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/openwrt"
if [ "$#" -ge 1 ]; then SRC="$1"; fi

die() {
  echo "::error::$*" >&2
  exit 1
}

[ -d "$SRC/target/linux/generic/hack-6.12" ] || die "未找到 OpenWrt Linux 6.12 补丁目录：$SRC/target/linux/generic/hack-6.12"
[ -d "$SRC/package/libs/libnftnl" ] || die "未找到 package/libs/libnftnl"
[ -d "$SRC/package/network/utils/nftables" ] || die "未找到 package/network/utils/nftables"
[ -d "$SRC/package/network/config/firewall4" ] || die "未找到 firewall4 源码目录"
[ -d "$SRC/feeds/luci/applications/luci-app-firewall" ] || die "未找到 luci-app-firewall；请先执行 feeds update/install"

copy_patch() {
  local source="$1"
  local destination="$2"
  [ -s "$source" ] || die "补丁文件缺失或为空：$source"
  mkdir -p "$destination"
  cp -f "$source" "$destination/"
  echo "  ✓ $(basename "$source")"
}

echo "▸ 集成 SONiC FullCone NAT（OpenWrt 25.12 / Linux 6.12）"

# Kernel: FullCone is integrated into the existing nft_masq path; no standalone
# kmod-nft-fullcone package is needed.
KERNEL_DIR="$SRC/target/linux/generic/hack-6.12"
copy_patch "$ROOT/patches/fullcone/kernel/984-add-sonic-fullcone-support.patch" "$KERNEL_DIR"
copy_patch "$ROOT/patches/fullcone/kernel/986-add-sonic-fullcone-to-nft.patch" "$KERNEL_DIR"
copy_patch "$ROOT/patches/fullcone/kernel/987-sonic-fullcone-fix-races-and-drops.patch" "$KERNEL_DIR"

# nftables userspace expression serialization and CLI keyword.
copy_patch "$ROOT/patches/fullcone/libnftnl/001-libnftnl-add-fullcone-expression-support.patch" "$SRC/package/libs/libnftnl/patches"
copy_patch "$ROOT/patches/fullcone/nftables/002-nftables-add-fullcone-expression-support.patch" "$SRC/package/network/utils/nftables/patches"
copy_patch "$ROOT/patches/fullcone/nftables/003-nftables-handle-fullcone-in-json-parser-and-optimizer.patch" "$SRC/package/network/utils/nftables/patches"

# The libnftnl patch changes Makefile.am. Regenerate autotools metadata using
# OpenWrt's available autotools instead of requiring the tarball's exact version.
LIBNFTNL_MK="$SRC/package/libs/libnftnl/Makefile"
if ! grep -q '^PKG_FIXUP:.*autoreconf' "$LIBNFTNL_MK"; then
  awk '
    !inserted && /^include \$\(INCLUDE_DIR\)\/package\.mk/ {
      print "PKG_FIXUP:=autoreconf"
      print ""
      inserted=1
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$LIBNFTNL_MK" > "$LIBNFTNL_MK.tmp" || die "无法在 libnftnl Makefile 中插入 PKG_FIXUP:=autoreconf"
  mv "$LIBNFTNL_MK.tmp" "$LIBNFTNL_MK"
fi
grep -q '^PKG_FIXUP:.*autoreconf' "$LIBNFTNL_MK" || die "libnftnl autoreconf 修复未生效"
echo "  ✓ libnftnl PKG_FIXUP:=autoreconf"

# Native firewall4 support and LuCI controls.
copy_patch "$ROOT/patches/fullcone/firewall4/001-sonic-fullcone.patch" "$SRC/package/network/config/firewall4/patches"
LUCI_DIR="$SRC/feeds/luci/applications/luci-app-firewall"
copy_patch "$ROOT/patches/fullcone/luci-app-firewall/001-add-fullcone-options.patch" "$LUCI_DIR/patches"

# Append Simplified Chinese strings exactly once; replace an older marked block
# if this script is run again.
PO="$LUCI_DIR/po/zh_Hans/firewall.po"
TRANSLATION="$ROOT/patches/fullcone/translations/zh_Hans.po"
[ -f "$PO" ] || die "缺少简体中文 firewall.po：$PO"
[ -s "$TRANSLATION" ] || die "缺少 FullCone 简体中文翻译：$TRANSLATION"
TMP_PO="$(mktemp)"
sed '/^# BEGIN openwrt-sonic-fullcone$/,/^# END openwrt-sonic-fullcone$/d' "$PO" > "$TMP_PO"
cat "$TRANSLATION" >> "$TMP_PO"
mv "$TMP_PO" "$PO"
[ "$(grep -c '^# BEGIN openwrt-sonic-fullcone$' "$PO")" -eq 1 ] || die "FullCone 中文翻译标记重复或缺失"
[ "$(grep -c '^# END openwrt-sonic-fullcone$' "$PO")" -eq 1 ] || die "FullCone 中文翻译结束标记重复或缺失"

echo "  ✓ firewall4 与 LuCI 补丁已就位"
echo "  ✓ 简体中文翻译已写入"
echo "✅ SONiC FullCone NAT 集成完成（仅 fw4/nftables；未启用 fw3/iptables）"
