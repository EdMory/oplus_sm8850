#!/usr/bin/env bash
# ==============================================================================
# pack_zram_module.sh —— 用「本次编译产出的 zram.ko」现场打包 ZRAM Magisk 模块 zram.zip
#
# 为什么需要它：
#   内核自带（或 patch 后的）zram 驱动并没有包含 lz4kdr 后端与 zram-ir 立即重压缩。
#   若直接把仓库里那份「旧内核编译出的 zram.ko」塞进 zram.zip，会因 vermagic /
#   符号 CRC 不匹配导致 insmod 失败，设备开机后失去 swap。因此必须用本次内核
#   同源编译出的 zram.ko 重新打包。
#
# 用法：
#   pack_zram_module.sh <模块脚本目录> <zram.ko> <输出zip路径> [模板zip]
#
# 环境变量：
#   EXPECT_LZ4KDR=true|false    期望 ko 内已编入 lz4kdr 后端（缺失即报错）
#   EXPECT_ZRAM_IR=true|false   期望 ko 内已编入 zram-ir（缺失即报错）
#   EXPECT_RELEASE=<vermagic>   期望的 ko vermagic 所含内核版本（不一致即报错）
#   STRICT=1|0                  1=校验不通过直接失败退出（CI 默认 1）
# ==============================================================================
set -euo pipefail

SRC_DIR="${1:-}"
KO_SRC="${2:-}"
OUT_ZIP="${3:-}"
TPL_ZIP="${4:-}"

EXPECT_LZ4KDR="${EXPECT_LZ4KDR:-false}"
EXPECT_ZRAM_IR="${EXPECT_ZRAM_IR:-false}"
EXPECT_RELEASE="${EXPECT_RELEASE:-}"
STRICT="${STRICT:-1}"

# 输出/模板路径统一转绝对路径：脚本内部会 cd 到临时目录后再打包，
# 若保留相对路径会把 zip 写进临时目录（随 trap 删除）导致产物丢失
abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    '') printf '%s\n' "" ;;
    *) printf '%s\n' "$(pwd)/$1" ;;
  esac
}
[ -n "$OUT_ZIP" ] && OUT_ZIP="$(abs_path "$OUT_ZIP")"
[ -n "$TPL_ZIP" ] && TPL_ZIP="$(abs_path "$TPL_ZIP")"

fail() { echo "[zram-pack] ❌ $*" >&2; exit 1; }
warn() { echo "[zram-pack] ⚠️  $*" >&2; }
info() { echo "[zram-pack] $*"; }

# ---------------------------------------------------------------- 入参校验
[ -n "$SRC_DIR" ] || fail "缺少参数：模块脚本目录"
[ -n "$KO_SRC" ]  || fail "缺少参数：zram.ko 路径"
[ -n "$OUT_ZIP" ] || fail "缺少参数：输出 zip 路径"

[ -d "$SRC_DIR" ] || fail "模块脚本目录不存在：$SRC_DIR"
[ -f "$KO_SRC" ]  || fail "zram.ko 不存在：$KO_SRC（请确认已执行 make ... O=out drivers/block/zram/）"

for f in module.prop service.sh action.sh zram_lib.sh; do
  [ -f "$SRC_DIR/$f" ] || fail "模块脚本缺失：$SRC_DIR/$f"
done

KO_SIZE=$(wc -c < "$KO_SRC" | tr -d ' ')
[ "$KO_SIZE" -gt 65536 ] || fail "zram.ko 体积异常（${KO_SIZE} 字节），疑似构建失败"

command -v strings >/dev/null 2>&1 || warn "未找到 strings，改用 grep -a 兜底检测"

has_str() {                                  # $1=文件 $2=字面量
  if command -v strings >/dev/null 2>&1; then
    strings -a "$1" | grep -qF "$2"
  else
    LC_ALL=C grep -aqF "$2" "$1"
  fi
}

# ---------------------------------------------------------------- ko 能力校验
VERMAGIC="$(strings -a "$KO_SRC" 2>/dev/null | grep -m1 '^vermagic=' || true)"
[ -n "$VERMAGIC" ] || VERMAGIC="$(LC_ALL=C tr -c '[:print:]' '\n' < "$KO_SRC" | grep -m1 '^vermagic=' || true)"
[ -n "$VERMAGIC" ] || warn "未能从 ko 中提取 vermagic 字符串"

HAS_LZ4KDR=false; has_str "$KO_SRC" "lz4kdr_encode" && HAS_LZ4KDR=true || true
HAS_ZRAM_IR=false; has_str "$KO_SRC" "zram_recomp_immediate" && HAS_ZRAM_IR=true || true

info "zram.ko  : $KO_SRC (${KO_SIZE} 字节)"
info "vermagic : ${VERMAGIC:-未知}"
info "lz4kdr   : $HAS_LZ4KDR    zram-ir: $HAS_ZRAM_IR"

if [ -n "$EXPECT_RELEASE" ] && [ -n "$VERMAGIC" ]; then
  case "$VERMAGIC" in
    *"$EXPECT_RELEASE"*) info "✔ vermagic 与本次内核版本一致（$EXPECT_RELEASE）" ;;
    *) fail "vermagic($VERMAGIC) 与本次内核版本($EXPECT_RELEASE) 不一致，烧入后将无法 insmod" ;;
  esac
fi

if [ "$EXPECT_LZ4KDR" = "true" ] && [ "$HAS_LZ4KDR" != "true" ]; then
  [ "$STRICT" = "1" ] && fail "期望 ko 内含 lz4kdr 后端，但未检测到 lz4kdr_encode 符号（请检查 lz4kdr_enable 与 CONFIG_ZRAM_BACKEND_LZ4KDR）"
  warn "期望含 lz4kdr 但未检测到，继续打包"
fi
if [ "$EXPECT_ZRAM_IR" = "true" ] && [ "$HAS_ZRAM_IR" != "true" ]; then
  [ "$STRICT" = "1" ] && fail "期望 ko 内含 zram-ir，但未检测到 zram_recomp_immediate（请检查 zram_ir_enable 与 CONFIG_ZRAM_MULTI_COMP）"
  warn "期望含 zram-ir 但未检测到，继续打包"
fi
if [ "$EXPECT_LZ4KDR" != "true" ] && [ "$HAS_LZ4KDR" = "true" ]; then
  info "✔ ko 额外包含 lz4kdr 后端"
fi
if [ "$EXPECT_ZRAM_IR" != "true" ] && [ "$HAS_ZRAM_IR" = "true" ]; then
  info "✔ ko 额外包含 zram-ir"
fi

# ---------------------------------------------------------------- 组装模块目录
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -f "$SRC_DIR/module.prop" "$SRC_DIR/service.sh" "$SRC_DIR/action.sh" "$SRC_DIR/zram_lib.sh" "$STAGE/"
# 用户在源码目录放了默认配置则一并打包（不放则模块开机不干预 zram，需手动配置一次）
[ -f "$SRC_DIR/zram_config.conf" ] && cp -f "$SRC_DIR/zram_config.conf" "$STAGE/"

cp -f "$KO_SRC" "$STAGE/zram.ko"

# META-INF（Magisk 安装器）优先从模板 zip 提取，保证与仓库内现有 zram.zip 安装器一致
META_OK=0
if [ -n "$TPL_ZIP" ] && [ -f "$TPL_ZIP" ]; then
  if command -v unzip >/dev/null 2>&1; then
    if unzip -qq -o "$TPL_ZIP" 'META-INF/*' -d "$STAGE" 2>/dev/null; then
      [ -f "$STAGE/META-INF/com/google/android/update-binary" ] && META_OK=1
    fi
  fi
fi

if [ "$META_OK" != "1" ]; then
  # 模板缺失（或仓库内没有旧 zram.zip）时，内置标准 Magisk v20.4+ 安装脚本
  warn "未从模板提取到 META-INF，使用内置的 Magisk 安装脚本"
  mkdir -p "$STAGE/META-INF/com/google/android"
  cat > "$STAGE/META-INF/com/google/android/updater-script" <<'EOF'
#MAGISK
EOF
  cat > "$STAGE/META-INF/com/google/android/update-binary" <<'EOF'
#!/sbin/sh
#################
# Initialization
#################
umask 022
ui_print() { echo "$1"; }
require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v20.4+! "
  ui_print "*******************************"
  exit 1
}
#########################
# Load util_functions.sh
#########################
OUTFD=$2
ZIPFILE=$3
mount /data 2>/dev/null
[ -f /data/adb/magisk/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF
fi

chmod 0755 "$STAGE/service.sh" "$STAGE/action.sh" "$STAGE/zram_lib.sh"
chmod 0644 "$STAGE/module.prop" "$STAGE/zram.ko"
find "$STAGE/META-INF" -type f -name 'update-binary' -exec chmod 0755 {} + 2>/dev/null || true

# ---------------------------------------------------------------- 打包
command -v zip >/dev/null 2>&1 || fail "环境缺少 zip 命令"
mkdir -p "$(dirname "$OUT_ZIP")"
rm -f "$OUT_ZIP"

(
  cd "$STAGE"
  ENTRIES="META-INF module.prop service.sh action.sh zram_lib.sh zram.ko"
  [ -f zram_config.conf ] && ENTRIES="$ENTRIES zram_config.conf"
  zip -q -X -r "$OUT_ZIP" $ENTRIES
)

# ---------------------------------------------------------------- 结果校验
[ -s "$OUT_ZIP" ] || fail "打包失败，输出为空"

if command -v unzip >/dev/null 2>&1; then
  LIST="$(unzip -Z1 "$OUT_ZIP" 2>/dev/null || true)"
  for f in module.prop service.sh action.sh zram_lib.sh zram.ko META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
    case "$LIST" in
      *"$f"*) ;;
      *) fail "打包结果缺少 $f" ;;
    esac
  done
else
  warn "环境缺少 unzip，跳过打包结果校验"
fi

ZIP_SIZE=$(wc -c < "$OUT_ZIP" | tr -d ' ')
KO_SHA="$(sha256sum "$KO_SRC" | awk '{print $1}')"

cat <<EOF
[zram-pack] ===== zram.zip 打包完成 =====
[zram-pack]   输出        : $OUT_ZIP (${ZIP_SIZE} 字节)
[zram-pack]   zram.ko     : ${KO_SIZE} 字节  sha256=${KO_SHA}
[zram-pack]   vermagic    : ${VERMAGIC:-未知}
[zram-pack]   lz4kdr 后端 : $HAS_LZ4KDR
[zram-pack]   zram-ir     : $HAS_ZRAM_IR
[zram-pack]   模块脚本    : module.prop service.sh action.sh zram_lib.sh
EOF

exit 0
