#!/system/bin/sh
# ==============================================================================
# action.sh —— ZRAM 配置管理器（zram-ir + lz4kdr 版）
#
# 操作方式：
#   音量上 / 音量下：移动光标
#   电源键        ：切换当前项取值 / 执行当前项（"应用并保存"）
#
# 可配置项：
#   ① 一级压缩算法：auto 或指定算法（写入 comp_algorithm）
#   ② 二级压缩算法：off 或指定算法（写入 recomp_algorithm，priority=1）
#   ③ ZRAM 大小    ：8 / 12 / 16 / 24 GB
#   ④ zram-ir 档位 ：0~3（0=关闭；N=单次写入内最多向下尝试 N 级压缩率更高的算法）
#   ⑤ 应用并保存  ：写入配置、重建 swap、回写 zram_config.conf 与 module.prop
# ==============================================================================

MODDIR=${0%/*}
. "$MODDIR/zram_lib.sh"

sizes="8589934592 12884901888 17179869184 25769803776"     # 8G / 12G / 16G / 24G

# ---------------------------------------------------------------- 基础工具

device_info() {
  echo "🔧 设备: $(getprop ro.product.model 2>/dev/null || echo 未知)"
  echo "🔄 Android: $(getprop ro.build.version.release 2>/dev/null || echo 未知)"
  echo "⚙️  内核: $(uname -r 2>/dev/null || echo 未知)"
}

physical_ram() { awk '/MemTotal/{print $2*1024}' /proc/meminfo 2>/dev/null; }

wait_key() {
  getevent -qt 1 >/dev/null 2>&1
  while true; do
    event=$(getevent -lqc 1 2>/dev/null | {
      while read -r line; do
        case "$line" in
          *KEY_VOLUMEDOWN*DOWN*) echo "down" && break ;;
          *KEY_VOLUMEUP*DOWN*)   echo "up"   && break ;;
          *KEY_POWER*DOWN*)
            input keyevent KEY_POWER
            echo "power" && break ;;
        esac
      done
    })
    [ -n "$event" ] && echo "$event" && return
    usleep 50000
  done
}

countdown() {
  _secs=$1
  while [ "$_secs" -gt 0 ]; do
    echo -ne "⏳ ${_secs}秒后返回...\033[0K\r"
    sleep 1
    _secs=$((_secs - 1))
  done
  echo -e "\033[0K\r"
}

cycle_value() {                    # $1=当前值 $2=候选列表 -> 下一个取值
  _cur="$1"
  _list="$2"
  _tot=0
  for _it in $_list; do _tot=$((_tot + 1)); done
  [ "$_tot" -eq 0 ] && { echo "$_cur"; return; }
  _idx=0
  _found=-1
  for _it in $_list; do
    if [ "$_it" = "$_cur" ]; then _found=$_idx; break; fi
    _idx=$((_idx + 1))
  done
  [ "$_found" -lt 0 ] && _found=-1
  _next=$(( (_found + 1) % _tot ))
  _idx=0
  for _it in $_list; do
    if [ "$_idx" -eq "$_next" ]; then echo "$_it"; return; fi
    _idx=$((_idx + 1))
  done
  echo "$_cur"
}

primary_list()   { echo "auto $(candidate_algos_unique | tr '\n' ' ')"; }
secondary_list() { echo "off $(candidate_algos_unique | tr '\n' ' ')"; }

# ---------------------------------------------------------------- 初始状态

read_config
cur_primary="$CFG_ALGORITHM"
[ -z "$cur_primary" ] && cur_primary="auto"
cur_secondary="off"
[ -n "$CFG_RECOMP" ] && cur_secondary="$(echo "$CFG_RECOMP" | awk '{print $1}' | cut -d: -f1)"
cur_size="$CFG_SIZE"
cur_ir="$CFG_IR"

# 首次使用（尚无 zram_config.conf）时，把菜单初始值对齐设备当前真实状态：
# 只打开一次管理器不会因为默认值而把 zram 大小/二级算法改掉
if [ ! -f "$CONFIG" ]; then
  _cur_ds="$(cat "$ZRAM_SYS/disksize" 2>/dev/null)"
  case "$_cur_ds" in
    ''|*[!0-9]*|0) ;;
    *) cur_size="$_cur_ds" ;;
  esac
  _cur_sec="$(cat "$ZRAM_SYS/recomp_algorithm" 2>/dev/null | grep -o '\[[^]]*\]' | head -n1 | tr -d '[]')"
  [ -n "$_cur_sec" ] && cur_secondary="$_cur_sec"
fi

# 模块 zram.ko 尚未生效时（无 zram-ir 且无 lz4kdr），先把模块驱动加载起来，
# 这样菜单里能直接看到 lz4kdr 等本模块独有的算法；加载后立即按已有配置重建 swap。
preload_module() {
  [ -s "$KO" ] || return 0
  if ir_support || lz4kdr_available; then
    return 0
  fi
  clear
  echo "🧩 正在加载模块 zram.ko（lz4kdr 后端 + zram-ir 立即重压缩）…"
  echo "----------------------------------"
  if ! load_zram_module; then
    echo "❌ 模块驱动加载失败，将保留系统自带 zram（不支持 lz4kdr / zram-ir）"
    sleep 3
    return 0
  fi
  _a="$cur_primary"
  [ -z "$_a" ] && _a="auto"
  _r="$CFG_RECOMP"
  if [ -z "$_r" ] && multi_comp_support; then
    _sec="$(pick_secondary "$_a")"
    [ -n "$_sec" ] && _r="$_sec:1"
  fi
  apply_zram_config "$_a" "$_r" "$cur_ir" "$cur_size" \
    && echo "✅ 已按当前配置重建 ZRAM：$(apply_summary)" \
    || echo "⚠️ 配置应用异常，请检查 $LOG"
  sleep 2
}

# ---------------------------------------------------------------- 界面渲染

render() {
  clear
  echo "ZRAM 配置管理器 v1.4 😋"
  echo "----------------------------------"
  device_info
  echo "----------------------------------"
  echo "📊 物理内存: $(human_bytes "$(physical_ram)")"
  echo "🧩 当前生效: 一级=$(active_algo | sed 's/^$/-/')  大小=$(human_bytes "$(cat "$ZRAM_SYS/disksize" 2>/dev/null)")"
  echo "🧱 二级=$(cat "$ZRAM_SYS/recomp_algorithm" 2>/dev/null | head -n1 | sed 's/^$/-/' )  IR档位=$(cat "$IR_SYSCTL" 2>/dev/null || echo '不可用')"
  echo "🧬 驱动: $([ -s "$KO" ] && echo '模块ko存在' || echo '模块ko缺失') / $(multi_comp_support && echo '多压缩流' || echo '单级')$(ir_support && echo ' + zram-ir' || echo ' (无zram-ir)')"
  echo "----------------------------------"

  [ "$focus" -eq 0 ] && p0="➡️ " || p0="   "
  [ "$focus" -eq 1 ] && p1="➡️ " || p1="   "
  [ "$focus" -eq 2 ] && p2="➡️ " || p2="   "
  [ "$focus" -eq 3 ] && p3="➡️ " || p3="   "
  [ "$focus" -eq 4 ] && p4="➡️ " || p4="   "

  echo "${p0}① 一级算法   : $cur_primary"
  echo "${p1}② 二级算法   : $cur_secondary      (priority=1，供 zram-ir 逐级尝试)"
  echo "${p2}③ ZRAM 大小  : $(human_bytes "$cur_size")"
  if ir_support; then
    echo "${p3}④ IR 立即重压缩: $cur_ir           (0=关闭, 1~3=逐级尝试上限)"
  else
    echo "${p3}④ IR 立即重压缩: 不可用 (当前驱动无 zram-ir)"
  fi
  echo "${p4}⑤ 应用并保存"
  echo "----------------------------------"
  echo "🔽 音量下 / 🔼 音量上：移动光标"
  echo "🔌 电源键：切换当前项取值（第⑤项为执行）"
  echo "ℹ️  一级=首压缩流，二级=压缩率更高但更慢的兜底流"
  echo "ℹ️  带 ? 标记的算法需先由本模块 zram.ko 提供，应用时会自动加载"
  echo ""
}

# ---------------------------------------------------------------- 应用动作

do_apply() {
  _recomp=""
  [ "$cur_secondary" != "off" ] && _recomp="$cur_secondary:1"

  clear
  echo "🛠️  正在应用配置…"
  echo "----------------------------------"
  echo "一级算法: $cur_primary"
  echo "二级算法: $cur_secondary"
  echo "目标大小: $(human_bytes "$cur_size") ($cur_size 字节)"
  echo "IR 档位 : $cur_ir"
  echo "----------------------------------"

  if apply_zram_config "$cur_primary" "$_recomp" "$cur_ir" "$cur_size"; then
    echo "✅ ZRAM 配置已生效"
    echo "实际一级算法: ${LAST_ALG:--}"
    echo "实际二级算法: ${LAST_RECOMP:-(未设置)}"
    echo "实际大小    : $(human_bytes "$LAST_SIZE") ($LAST_SIZE 字节)"
    echo "IR 档位     : $LAST_IR"
    case "$LAST_KO" in
      builtin-module)  echo "驱动来源    : 模块内置 zram.ko（支持 lz4kdr + zram-ir）" ;;
      fallback-system) echo "驱动来源    : ⚠️ 已回退系统自带 zram（模块 ko 加载失败）" ;;
      missing)         echo "驱动来源    : ⚠️ 模块 ko 缺失，使用系统自带 zram" ;;
      failed)          echo "驱动来源    : ⚠️ 模块 ko 加载失败，使用系统自带 zram" ;;
    esac

    if write_config "$LAST_ALG" "$LAST_RECOMP" "$LAST_IR" "$LAST_SIZE"; then
      echo "✅ 已回写配置: $CONFIG"
      update_description "description=当前已生效 [$(apply_summary)]"
    else
      echo "❌ 配置回写失败，请检查模块目录权限"
    fi
  else
    echo "❌ 应用失败（可能原因：算法不可用 / 驱动加载失败），详见 $LOG"
  fi
  echo "----------------------------------"
  countdown 5
  exit 0
}

# ---------------------------------------------------------------- 主循环

preload_module

focus=0
while true; do
  render
  case $(wait_key) in
    "up")    focus=$(( (focus + 4) % 5 )) ;;          # 上移（5 项循环）
    "down")  focus=$(( (focus + 1) % 5 )) ;;          # 下移
    "power")
      case "$focus" in
        0) cur_primary=$(cycle_value "$cur_primary" "$(primary_list)") ;;
        1) cur_secondary=$(cycle_value "$cur_secondary" "$(secondary_list)") ;;
        2) cur_size=$(cycle_value "$cur_size" "$sizes") ;;
        3) [ "$ir_support" ] && cur_ir=$(cycle_value "$cur_ir" "0 1 2 3") ;;
        4) do_apply ;;
      esac
      ;;
  esac
done
