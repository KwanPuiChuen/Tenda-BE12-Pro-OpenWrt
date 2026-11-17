#!/usr/bin/env bash
# =============================================================================
# fetch-extra-packages.sh — 引入「Makefile 在仓库根目录」的第三方包
# -----------------------------------------------------------------------------
# ## 为什么需要这个脚本
#
# OpenWrt 的 feed 索引机制（include/scan.mk）是这样扫描包的：
#
#     find -L $(SCAN_DIR) -mindepth 1 -maxdepth $(SCAN_DEPTH) -name Makefile
#                       ^^^^^^^^^^^^^
#                       注意 -mindepth 1 —— feed 根目录本身被排除
#
# 也就是说：**只有当包位于仓库的【子目录】里，feeds 才会索引它。**
# 如果某个仓库的 Makefile 直接躺在根目录（jerrykuku/luci-theme-argon、
# eamonxg/luci-theme-aurora 都是这种结构），那么：
#
#   - `feeds install luci_theme_argon/luci-theme-argon` 静默无输出、不报错
#   - 索引里没有该包 → package/ 下不会出现任何东西
#   - .config 里 `CONFIG_PACKAGE_luci-theme-argon` 符号**根本不存在**
#   - kconfig 不会报错，make defconfig 也不会报错
#   - 编译一路绿灯，固件里就是没有这个主题 ❌
#
# 这个坑非常隐蔽：Run #5 全绿、体积守卫也过，事后翻 .config 才发现
# 三个包一个都没进去。
#
# ## 解决办法
#
# 绕开 feeds 机制，直接把仓库 clone 到 OpenWrt 的 package/ 目录下。
# package/ 的扫描规则是 `SCAN_DIR=package` + `-mindepth 1`，
# 于是 `package/<名字>/Makefile` 正好落在 depth 1，能被正确索引。
#
# package/ 的优先级高于 package/feeds/*，本脚本只用于官方主线**没有**的包。
#
# 用法： ./scripts/fetch-extra-packages.sh [openwrt源码目录]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
LOCK="$ROOT/versions.lock"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

get() { grep -E "^$1=" "$LOCK" | head -1 | cut -d= -f2-; }
die() { echo "${RED}❌ $*${RST}" >&2; exit 1; }
info() { echo "${CYN}$*${RST}"; }
ok()   { echo "  ${GRN}✓${RST} $*"; }

[ -d "$SRC" ] || die "OpenWrt 源码目录不存在: $SRC（先跑 gen-feeds.sh）"

# ---- 读取锁文件 ------------------------------------------------------------
# 每个包四个键： PKG_NAME_<X> / <X>_REPO / <X>_BRANCH / <X>_COMMIT
declare -a NAMES REPOS BRANCHES COMMITS
read_lock() {
  local key="$1" n repo br cm
  n=$(get "PKG_NAME_${key}")
  repo=$(get "${key}_REPO")
  br=$(get "${key}_BRANCH")
  cm=$(get "${key}_COMMIT")
  [ -n "$n" ] || return 1
  [ -n "$repo" ] || die "versions.lock 缺少 ${key}_REPO"
  NAMES+=("$n"); REPOS+=("$repo"); BRANCHES+=("$br"); COMMITS+=("$cm")
}

read_lock THEME_ARGON  || true
read_lock ARGON_CFG    || true
read_lock THEME_AURORA  || true
read_lock MWAN3         || true   # nft 版 mwan3，双 WAN 负载均衡

[ "${#NAMES[@]}" -gt 0 ] || die "versions.lock 里一个 PKG_NAME_* 都没读到"

echo "═══════════════════════════════════════════════════════════"
echo " 额外包（package/ 直挂，绕过 feeds 的 -mindepth 1 限制）"
echo "═══════════════════════════════════════════════════════════"

cd "$SRC"
mkdir -p package

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; repo="${REPOS[$i]}"; br="${BRANCHES[$i]}"; cm="${COMMITS[$i]}"
  dest="package/$name"

  echo
  info "▸ $name"
  echo "    源: $repo"
  echo "    锁: ${cm:-<未锁定分支 $br>}"

  # 校验包名 —— 目录名会直接进 OpenWrt 的包扫描
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "包名非法: $name（只允许字母/数字/点/下划线/连字符）"
  fi

  if [ -d "$dest/.git" ]; then
    echo "    已存在，尝试对齐到锁定 commit…"
  else
    rm -rf "$dest"
    git clone --quiet "$repo" "$dest"
  fi

  if [ -n "$cm" ]; then
    if [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo '')" != "$cm" ]; then
      git -C "$dest" fetch --quiet --depth 1 origin "$cm" 2>/dev/null \
        || git -C "$dest" fetch --quiet origin
      git -C "$dest" checkout --quiet -B "$br" "$cm" 2>/dev/null \
        || git -C "$dest" checkout --quiet "$cm"
    fi
  fi

  got="$(git -C "$dest" rev-parse HEAD)"

  # ---- 关键断言：Makefile 必须在包目录里 ----------------------------------
  if [ ! -f "$dest/Makefile" ]; then
    echo "  ${RED}❌ $dest/Makefile 不存在${RST}"
    echo "     该仓库可能不是「根 Makefile」结构，package/ 直挂不适用。"
    echo "     请改用 src-git feed（要求包在子目录里），或换一个源。"
    exit 1
  fi

  # 确认它真的会被 BuildPackage 扫描到
  if ! grep -qE 'call (BuildPackage|Build/DefaultTargets)' "$dest/Makefile"; then
    die "$dest/Makefile 里没有 'call BuildPackage'，OpenWrt 不会识别为包"
  fi

  # 推导这个包实际提供的包名，供 base.config 对照。
  # 三种写法都要覆盖：
  #   1) 显式 PKG_NAME:=xxx        （luci-app-argon-config）
  #   2) define Package/xxx        （子包，如 xxx/conffiles）
  #   3) 都没有 → include luci.mk，包名由**目录名**决定 （argon / aurora）
  pkgnames="$(
    { grep -E '^\s*define Package/' "$dest/Makefile" 2>/dev/null \
        | sed 's/.*Package\///; s/\/[a-z].*$//; s/\s*$//'
      grep -E '^\s*PKG_NAME:=' "$dest/Makefile" 2>/dev/null \
        | head -1 | sed 's/.*PKG_NAME:=//; s/\s*$//'
      grep -qE '^\s*PKG_NAME:=' "$dest/Makefile" 2>/dev/null || echo "$name"
    } | sed 's/^$(PKG_NAME)$//' | grep -v '^$' | sort -u | tr '\n' ' '
  )"

  ok "$name @ ${got:0:12}"
  echo "      Makefile ✓  含 call BuildPackage ✓"
  echo "      提供的包: $pkgnames"
done

# ---- 同名冲突清理：feeds 里若有同名包，会把 package/ 直挂版挤掉 ------------
# ⚠️ include/scan.mk 扫描 package/ 时同 PKG_NAME 只认一份，
#    package/feeds/<feed>/<name> 按字母序先于 package/<name> 命中，
#    于是 kconfig 里的 CONFIG_PACKAGE_<name> 指向 feeds 的官方版，
#    直挂的移植版被静默丢弃 —— 编译全绿、抽查才发现装错版本。
#    （mwan3 的判据就是这种「装错版本」：/usr/sbin/mwan3 在，
#      但 nft 移植版才有的 mwan3-diag / mwan3ct 不在。）
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"
  for f in "$SRC"/package/feeds/*/"$n"; do
    [ -e "$f" ] || continue
    ( cd "$SRC" && ./scripts/feeds uninstall "$n" >/dev/null 2>&1 ) || true
    if [ -e "$f" ]; then rm -rf "$f"; fi
    info "  feeds 里有同名包 $n，已移除（保留 package/$n 直挂版）"
  done
done

# ---- 断言：直挂版必须是唯一来源，且 Makefile 还在 ---------------------------
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"
  if ls "$SRC"/package/feeds/*/"$n" >/dev/null 2>&1; then
    die "feeds 里仍存在同名包 $n —— 会覆盖 package/$n 直挂版"
  fi
  [ -f "$SRC/package/$n/Makefile" ] || die "package/$n/Makefile 不见了"
done
ok "无同名 feeds 包冲突（${#NAMES[@]} 个直挂包均为唯一来源）"

# ---- 生成 package/ 清单，供 gen-config 阶段核对 ----------------------------
{
  echo "# 由 scripts/fetch-extra-packages.sh 自动生成 —— 请勿手工编辑"
  echo "# 格式: <目录名> <包名1> [包名2 ...]"
  for i in "${!NAMES[@]}"; do
    d="$SRC/package/${NAMES[$i]}"
    p="$(
      { grep -E '^\s*define Package/' "$d/Makefile" 2>/dev/null \
          | sed 's/.*Package\///; s/\/[a-z].*$//; s/\s*$//'
        grep -E '^\s*PKG_NAME:=' "$d/Makefile" 2>/dev/null \
          | head -1 | sed 's/.*PKG_NAME:=//; s/\s*$//'
        grep -qE '^\s*PKG_NAME:=' "$d/Makefile" 2>/dev/null || echo "${NAMES[$i]}"
      } | sed 's/^$(PKG_NAME)$//' | grep -v '^$' | sort -u | tr '\n' ' '
    )"
    echo "${NAMES[$i]} $p"
  done
} > package/.extra-packages

echo
echo "${GRN}✅ ${#NAMES[@]} 个额外包已就位${RST}"
echo "   清单: $SRC/package/.extra-packages"
echo
echo "${YEL}提醒${RST}: 这些包不在 feeds 里，${CYN}base.config${RST} 必须显式"
echo "        写对应的 CONFIG_PACKAGE_<包名>=y，否则不会被选中。"
