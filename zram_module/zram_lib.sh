#!/system/bin/sh
# ==============================================================================
# zram_lib.sh —— ZRAM 配置核心库（service.sh / action.sh 共用）
#
# 能力：
#   1) 加载模块内置 zram.ko（与本次内核同源编译，含 lz4kdr 后端 + zram-ir 立即重压缩）
#   2) 一级压缩算法（/sys/block/zram0/comp_algorithm）
#   3) 二级/多级压缩算法与 priority（/sys/block/zram0/recomp_algorithm，
#      由 zram-ir 在单次写入内按 priority 从小到大逐级尝试，达标即停）
#   4) zram-ir 档位（/proc/sys/vm/zram_recomp_immediate，0=关闭，1~3=逐级尝试上限）
#   5) 驱动加载失败自动回退系统自带 zram，保证设备始终有可用 swap
#
# 配置文件：$MODDIR/zram_config.conf
#   algorithm=<一级算法名|auto>
#   recomp=<二级算法列表 "算法:priority ..."，可为空>
#   ir_level=<0~3>
#   size=<字节数>
# ==============================================================================

MODDIR="${MODDIR:-${0%/*}}"
KO="$MODDIR/zram.ko"
CONFIG="$MODDIR/zram_config.conf"
LOG="$MODDIR/zram.log"
PROP="$MODDIR/module.prop"

ZRAM_DEV=/dev/block/zram0
ZRAM_SYS=/sys/block/zram0
IR_SYSCTL=/proc/sys/vm/zram_recomp_immediate

DEFAULT_IR=1
DEFAULT_SIZE=8589934592          # 8GB

# 一级算法候选（auto 时按此顺序挑选，越靠前越优先：快 → 慢）
PRIMARY_ORDER="lz4kdr lz4kd lz4k lz4hc lz4 zstdn zstd lzo-rle lzo 842"
# 二级算法候选（压缩率更高但更慢，用于 zram-ir 兜底逐级尝试）
SECONDARY_ORDER="lz4kd lz4kdr lz4hc zstd zstdn lz4 lzo-rle lzo 842"
# 界面展示用全量候选
CANDIDATE_ALL="lz4kdr lz4kd lz4k lz4hc lz4 zstdn zstd lzo-rle lzo 842"

# 上一次 apply_zram_config 的真实生效结果（供 service.sh / action.sh 展示与回写）
LAST_ALG=""
LAST_RECOMP=""
LAST_IR=""
LAST_SIZE=""
LAST_KO=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }

# 以 root 身份执行一段 shell 片段；Magisk 环境下本身即 root，非 root 时用 su 兜底
SH() {
  if is_root; then
    sh -c "$1"
  else
    su -c "$1"
  fi
}

human_bytes() {
  echo "${1:-0}" | awk '{ if ($1+0 <= 0) print "未知"; else printf "%.1fGB", $1/1024/1024/1024 }'
}

# ---------------------------------------------------------------- 驱动状态探测

wait_zram_dev() {                 # $1=超时秒数(默认 60)
  _w=0
  _max=${1:-60}
  while [ ! -e "$ZRAM_SYS" ] && [ "$_w" -lt "$_max" ]; do
    sleep 1
    _w=$((_w + 1))
  done
  [ -e "$ZRAM_SYS" ]
}

avail_algos() {                   # 当前已加载 zram 支持的全部算法（去掉 [当前] 标记）
  cat "$ZRAM_SYS/comp_algorithm" 2>/dev/null | tr ' ' '\n' | tr -d '[]' | grep -v '^$'
}

algo_available() { [ -n "$1" ] && avail_algos | grep -qx "$1"; }

active_algo() { cat "$ZRAM_SYS/comp_algorithm" 2>/dev/null | grep -o '\[[^]]*\]' | tr -d '[]'; }

multi_comp_support() { [ -e "$ZRAM_SYS/recomp_algorithm" ]; }

ir_support() { [ -e "$IR_SYSCTL" ]; }

# 模块 ko 是否已编入 lz4kdr 后端（仅作展示用）
lz4kdr_available() { algo_available lz4kdr; }

# 候选算法列表（模块已知算法 + 当前驱动实际支持算法，去重保序）
candidate_algos_unique() {
  { for _a in $CANDIDATE_ALL; do echo "$_a"; done; avail_algos; } | awk 'NF && !seen[$0]++'
}

pick_primary() {
  for _a in $PRIMARY_ORDER; do
    if algo_available "$_a"; then echo "$_a"; return 0; fi
  done
  avail_algos | head -n1
}

pick_secondary() {                # $1=一级算法（避免与其重复）
  for _a in $SECONDARY_ORDER; do
    [ "$_a" = "$1" ] && continue
    if algo_available "$_a"; then echo "$_a"; return 0; fi
  done
  return 1
}

# 卸载当前 zram 并加载模块内置 ko；失败自动回退系统自带驱动
# LAST_KO: builtin-module / fallback-system / missing / failed
load_zram_module() {
  # 注意：不能先等 zram0 出现再加载——zram 为 module(=m) 时开机时设备节点尚不存在，
  # 先等待只会白等超时。此处顺序为：卸旧实例 → insmod 模块 ko → 等设备 → 回退系统驱动
  if [ -e "$ZRAM_SYS" ]; then
    SH "swapoff $ZRAM_DEV 2>/dev/null"
    SH "rmmod zram 2>/dev/null"
    sleep 2
  fi

  LAST_KO=""
  if [ -s "$KO" ]; then
    if SH "insmod '$KO'"; then
      LAST_KO="builtin-module"
      log "insmod $KO 成功"
    else
      LAST_KO="failed"
      log "insmod $KO 失败（vermagic / 签名 / 符号不匹配？）"
    fi
  else
    LAST_KO="missing"
    log "模块目录内缺少 zram.ko，使用系统自带 zram"
  fi

  if wait_zram_dev 10; then
    return 0
  fi

  log "模块 zram.ko 加载后 zram0 仍未出现，回退系统自带 zram"
  SH "modprobe zram 2>/dev/null" \
    || SH "insmod /vendor/lib/modules/zram.ko 2>/dev/null" \
    || SH "insmod /vendor_dlkm/lib/modules/zram.ko 2>/dev/null" \
    || true
  if wait_zram_dev 30; then
    LAST_KO="fallback-system"
    log "已回退系统自带 zram 驱动"
    return 0
  fi
  log "系统 zram 驱动同样不可用，放弃配置"
  return 1
}

# ---------------------------------------------------------------- 应用配置

# apply_zram_config <一级算法|auto> <二级列表 "alg:prio ..."|空> <IR档位 0~3> <大小字节>
apply_zram_config() {
  _alg="$1"
  _recomp="$2"
  _ir="$3"
  _size="$4"

  case "$_size" in ''|*[!0-9]*) _size="$DEFAULT_SIZE" ;; esac
  case "$_ir" in ''|*[!0-9]*) _ir="$DEFAULT_IR" ;; esac
  [ "$_ir" -gt 3 ] && _ir=3

  log "=== 应用 ZRAM 配置: 一级=[$_alg] 二级=[$_recomp] IR=[$_ir] 大小=[$_size] ==="

  # 1. 卸载旧驱动，加载模块内置 zram.ko（含 lz4kdr 与 zram-ir）
  load_zram_module || return 1

  # 2. 确定一级算法（不可用时自动降级）
  _primary="$_alg"
  if [ "$_primary" = "auto" ] || [ -z "$_primary" ]; then
    _primary="$(pick_primary)"
  fi
  if ! algo_available "$_primary"; then
    _fallback="$(pick_primary)"
    log "一级算法 $_primary 当前驱动不支持，自动改用 $_fallback"
    _primary="$_fallback"
  fi
  [ -n "$_primary" ] || { log "没有任何可用压缩算法，放弃"; return 1; }

  # 3. 复位到未初始化状态（改写 comp_algorithm / recomp_algorithm 的前提）
  SH "swapoff $ZRAM_DEV 2>/dev/null"
  SH "echo 1 > $ZRAM_SYS/reset"
  if ! SH "echo '$_primary' > $ZRAM_SYS/comp_algorithm"; then
    log "一级算法写入失败: $_primary"
  fi

  # 4. 二级/多级算法（zram-ir 逐级尝试的后续级次；无 IR 时作为后台重压缩目标）
  _applied_recomp=""
  if [ -z "$_recomp" ]; then
    log "未配置二级算法（单级压缩）"
  elif ! multi_comp_support; then
    log "当前驱动不支持多压缩流(recomp_algorithm)，跳过二级算法"
  else
    for _item in $_recomp; do
      _a="${_item%%:*}"
      _p="${_item##*:}"
      case "$_p" in ''|*[!0-9]*) _p=1 ;; esac
      [ "$_p" -ge 1 ] && [ "$_p" -le 3 ] || { log "priority 越界(1~3)，跳过: $_item"; continue; }
      [ "$_a" = "$_primary" ] && { log "二级算法与一级相同，跳过: $_a"; continue; }
      case " $_applied_recomp " in
        *" $_a:"*) log "二级算法重复，跳过: $_a"; continue ;;
      esac
      if ! algo_available "$_a"; then
        log "二级算法当前驱动不支持，跳过: $_a"
        continue
      fi
      if SH "echo 'algo=$_a priority=$_p' > $ZRAM_SYS/recomp_algorithm"; then
        _applied_recomp="$_applied_recomp $_a:$_p"
      else
        log "二级算法写入失败: $_a priority=$_p"
      fi
    done
    _applied_recomp="$(echo "$_applied_recomp" | sed 's/^ *//')"
  fi

  # 5. zram-ir 档位（0=关闭；N=单次写入内最多向下尝试 N 级更高压缩率算法）
  _ir_applied="-"
  if ir_support; then
    if SH "echo '$_ir' > $IR_SYSCTL"; then
      _ir_applied="$_ir"
    else
      log "zram-ir 档位写入失败: $_ir"
    fi
  else
    log "当前驱动未集成 zram-ir（缺少 $IR_SYSCTL）"
  fi

  # 6. 生效大小并激活 swap
  if ! SH "echo '$_size' > $ZRAM_SYS/disksize"; then
    log "disksize 写入失败: $_size"
    return 1
  fi
  SH "mkswap $ZRAM_DEV >/dev/null 2>&1"
  SH "swapon -p 32767 $ZRAM_DEV >/dev/null 2>&1"

  # 7. 校验并记录真实生效值
  LAST_ALG="$(active_algo)"
  LAST_RECOMP="$_applied_recomp"
  LAST_IR="$(cat "$IR_SYSCTL" 2>/dev/null)"
  [ -n "$LAST_IR" ] || LAST_IR="-"
  LAST_SIZE="$(cat "$ZRAM_SYS/disksize" 2>/dev/null)"
  _swapon_ok="$(grep -c zram0 /proc/swaps 2>/dev/null)"

  log "结果: 一级=$LAST_ALG 二级=[$LAST_RECOMP] IR=$LAST_IR 大小=$LAST_SIZE ko=$LAST_KO swapon条目=${_swapon_ok:-0}"
  [ "$LAST_SIZE" = "$_size" ] || log "警告: 目标大小($_size)未完全生效"
  [ "${_swapon_ok:-0}" -ge 1 ] || log "警告: swap 未成功激活"

  return 0
}

# 结果摘要（单行，供 module.prop 描述使用）
apply_summary() {
  _s="大小($(human_bytes "$LAST_SIZE")) 一级(${LAST_ALG:--})"
  [ -n "$LAST_RECOMP" ] && _s="$_s 二级($LAST_RECOMP)"
  _s="$_s IR($LAST_IR)"
  [ "$LAST_KO" = "builtin-module" ] || _s="$_s [${LAST_KO}]"
  echo "$_s"
}

# ---------------------------------------------------------------- 配置读写

read_config() {
  CFG_ALGORITHM=""
  CFG_RECOMP=""
  CFG_IR="$DEFAULT_IR"
  CFG_SIZE="$DEFAULT_SIZE"

  if [ -f "$CONFIG" ]; then
    . "$CONFIG" 2>/dev/null
    [ -n "$algorithm" ] && CFG_ALGORITHM="$algorithm"
    [ -n "$recomp" ] && CFG_RECOMP="$recomp"
    case "$ir_level" in ''|*[!0-9]*) ;; *) CFG_IR="$ir_level" ;; esac
    case "$size" in ''|*[!0-9]*) ;; *) CFG_SIZE="$size" ;; esac
  fi
  # 容错：一级算法只取第一个词；二级算法逐项清洗
  CFG_ALGORITHM="$(echo "$CFG_ALGORITHM" | awk '{print $1}')"
  CFG_RECOMP="$(echo "$CFG_RECOMP" | tr ',' ' ')"
  [ "$CFG_IR" -gt 3 ] && CFG_IR=3
}

# write_config <一级> <二级列表> <IR档位> <大小字节>
write_config() {
  # 值统一加单引号：该文件后续被 `.` 读取，未加引号时 "alg:prio alg:prio" 里的
  # 第二个词会被 shell 当成命令名而报错
  _body="algorithm='$1'
recomp='$2'
ir_level='$3'
size='$4'"
  if is_root; then
    printf '%s\n' "$_body" > "$CONFIG"
  else
    printf '%s\n' "$_body" | su -c "cat > '$CONFIG'"
  fi
}

# 更新模块描述，展示当前生效配置
update_description() {
  [ -f "$PROP" ] || return 0
  _desc="description=$1"
  if is_root; then
    sed -i "s|^description=.*|$_desc|" "$PROP" 2>/dev/null
  else
    su -c "sed -i 's|^description=.*|$_desc|' '$PROP'" 2>/dev/null
  fi
}
