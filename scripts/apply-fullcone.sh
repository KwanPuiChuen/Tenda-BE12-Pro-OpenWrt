#!/usr/bin/env bash
# Apply pinned SONiC Full Cone NAT integration to OpenWrt 25.12 / Linux 6.12.
# Upstream: mufeng05/openwrt-sonic-fullcone
# Pinned upstream commit: f87ac2a95b77270af9180a16590cc548617336a1
# nftables/firewall4 only; iptables/fw3 patches are intentionally omitted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
UPSTREAM_COMMIT="f87ac2a95b77270af9180a16590cc548617336a1"
UPSTREAM_REPO="https://github.com/mufeng05/openwrt-sonic-fullcone.git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "::error::$*" >&2; exit 1; }

[ -d "$SRC/target/linux/generic/hack-6.12" ] || die "未找到 OpenWrt Linux 6.12 补丁目录"
[ -d "$SRC/package/libs/libnftnl" ] || die "未找到 package/libs/libnftnl"
[ -d "$SRC/package/network/utils/nftables" ] || die "未找到 nftables 源码目录"
[ -d "$SRC/package/network/config/firewall4" ] || die "未找到 firewall4 源码目录"
[ -d "$SRC/feeds/luci/applications/luci-app-firewall" ] || die "未找到 luci-app-firewall；请先执行 feeds update/install"

echo "▸ 获取固定版本 SONiC FullCone 补丁：$UPSTREAM_COMMIT"
git -C "$TMP" init -q
git -C "$TMP" remote add origin "$UPSTREAM_REPO"
git -C "$TMP" fetch --depth=1 origin "$UPSTREAM_COMMIT" || die "无法获取 FullCone 上游固定 commit"
git -C "$TMP" checkout -q --detach FETCH_HEAD
[ "$(git -C "$TMP" rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || die "FullCone 上游 commit 校验失败"
PATCH_ROOT="$TMP"

copy_patch() {
  local source="$1" destination="$2"
  [ -s "$PATCH_ROOT/$source" ] || die "上游补丁缺失：$source"
  mkdir -p "$destination"
  cp -f "$PATCH_ROOT/$source" "$destination/"
  echo "  ✓ $(basename "$source")"
}

echo "▸ 集成 SONiC FullCone NAT（OpenWrt 25.12 / Linux 6.12）"

# Kernel implementation is built into existing NAT modules; no standalone
# kmod-nft-fullcone package is required.
KERNEL_DIR="$SRC/target/linux/generic/hack-6.12"
copy_patch kernel/984-add-sonic-fullcone-support.patch "$KERNEL_DIR"
copy_patch kernel/986-add-sonic-fullcone-to-nft.patch "$KERNEL_DIR"
copy_patch kernel/987-sonic-fullcone-fix-races-and-drops.patch "$KERNEL_DIR"

copy_patch patches/libnftnl/001-libnftnl-add-fullcone-expression-support.patch "$SRC/package/libs/libnftnl/patches"
copy_patch patches/nftables/002-nftables-add-fullcone-expression-support.patch "$SRC/package/network/utils/nftables/patches"
copy_patch patches/nftables/003-nftables-handle-fullcone-in-json-parser-and-optimizer.patch "$SRC/package/network/utils/nftables/patches"

# The libnftnl patch changes Makefile.am; regenerate autotools metadata with
# the autotools versions supplied by the OpenWrt build environment.
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
  ' "$LIBNFTNL_MK" > "$LIBNFTNL_MK.tmp" || die "无法修改 libnftnl Makefile"
  mv "$LIBNFTNL_MK.tmp" "$LIBNFTNL_MK"
fi
grep -q '^PKG_FIXUP:.*autoreconf' "$LIBNFTNL_MK" || die "libnftnl autoreconf 修复未生效"

copy_patch firewall/firewall4/001-sonic-fullcone.patch "$SRC/package/network/config/firewall4/patches"
LUCI_DIR="$SRC/feeds/luci/applications/luci-app-firewall"
copy_patch patches/luci-app-firewall/001-add-fullcone-options.patch "$LUCI_DIR/patches"

PO="$LUCI_DIR/po/zh_Hans/firewall.po"
[ -f "$PO" ] || die "缺少简体中文 firewall.po"
TMP_PO="$(mktemp)"
sed '/^# BEGIN openwrt-sonic-fullcone$/,/^# END openwrt-sonic-fullcone$/d' "$PO" > "$TMP_PO"
cat "$PATCH_ROOT/translations/zh_Hans.po" >> "$TMP_PO"
mv "$TMP_PO" "$PO"
[ "$(grep -c '^# BEGIN openwrt-sonic-fullcone$' "$PO")" -eq 1 ] || die "FullCone 中文翻译标记校验失败"
[ "$(grep -c '^# END openwrt-sonic-fullcone$' "$PO")" -eq 1 ] || die "FullCone 中文翻译结束标记校验失败"

echo "✅ SONiC FullCone 集成完成（fw4/nftables；内核 6.12）"
