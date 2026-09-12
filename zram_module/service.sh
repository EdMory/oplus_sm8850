#!/system/bin/sh
# ==============================================================================
# service.sh —— 开机自动应用 ZRAM 配置（Magisk late_start service）
#
# 流程：
#   1) 读取模块目录下 zram_config.conf（不存在则不干预，保持原模块的"未配置即不动"语义）
#   2) 卸载系统 zram 并加载模块内置 zram.ko（含 lz4kdr 后端 + zram-ir 立即重压缩）
#   3) 写入 一级算法 / 二级算法(priority) / zram-ir 档位 / 大小，并激活 swap
#   4) 任一步骤失败自动降级回系统自带 zram，保证设备始终有 swap 可用
#
# 全部实现见 zram_lib.sh（与 action.sh 共用同一套逻辑）
# ==============================================================================

MODDIR=${0%/*}
. "$MODDIR/zram_lib.sh"

log "----- service.sh 启动：内核 $(uname -r 2>/dev/null) -----"

if [ ! -s "$KO" ]; then
  log "缺少 zram.ko，跳过（仅做提示）"
  update_description "description=已就绪(缺少zram.ko)：请重新刷入支持 lz4kdr/zram-ir 的内核包"
  exit 0
fi

if [ ! -f "$CONFIG" ]; then
  log "未找到 zram_config.conf（尚未配置），不做任何改动"
  update_description "description=已就绪(未配置)：请点模块操作选择 算法/大小/多级压缩"
  exit 0
fi

read_config
log "读取配置: algorithm=[$CFG_ALGORITHM] recomp=[$CFG_RECOMP] ir_level=[$CFG_IR] size=[$CFG_SIZE]"

if [ -z "$CFG_ALGORITHM" ]; then
  log "配置中一级算法为空，按当前驱动自动选择"
  CFG_ALGORITHM="auto"
fi

# 未显式配置二级算法时，自动带上一级兜底算法（zram-ir 逐级尝试才有意义）
if [ -z "$CFG_RECOMP" ] && multi_comp_support; then
  _sec="$(pick_secondary "$CFG_ALGORITHM")"
  [ -n "$_sec" ] && CFG_RECOMP="$_sec:1" && log "未配置二级算法，自动使用 $_sec:1"
fi

if apply_zram_config "$CFG_ALGORITHM" "$CFG_RECOMP" "$CFG_IR" "$CFG_SIZE"; then
  update_description "description=当前已生效 [$(apply_summary)]"
  log "配置应用成功：$(apply_summary)"
else
  update_description "description=应用失败：详见模块目录 zram.log，已尝试回退系统 zram"
  log "配置应用失败"
fi

exit 0
