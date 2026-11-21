#!/bin/bash
# ============================================================================
# apply_lz4_neon.sh — LZ4 NEON 加速挂钩脚本
#
# 功能: 将内核中所有 LZ4 解压调用点条件编译式地路由到 LZ4 1.10 代码包
#       自带的 ARM64 NEON 汇编解压器 LZ4_arm64_decompress_safe()
#       (实现位于 lib/lz4/lz4armv8/, 由 001-lz4.patch 提供)。
#
# 覆盖路径:
#   crypto/lz4.c         — zram "lz4" 压缩后端的解压 (crypto API)
#   crypto/lz4hc.c       — zram "lz4hc" 压缩后端的解压 (crypto API)
#   fs/f2fs/compress.c   — F2FS 透明压缩文件的读取解压
#   fs/incfs/data_mgmt.c — Incremental FS (Play 商店增量分发; 不存在则自动跳过)
#
# 前置条件:
#   1) 已应用包含 lz4armv8 NEON 实现的 LZ4 1.10.0 补丁
#      (否则 NEON 分支编译/链接失败, 建议由 lz4_enable 之类的开关门控本脚本);
#   2) CONFIG_KERNEL_MODE_NEON=y (否则自动回退原 C 实现, 无加速收益)。
#
# 特性: 幂等可重入 / 正则匹配不依赖行号 / 任一失败即以非零退出 (fail-fast)
#
# 用法: bash apply_lz4_neon.sh [内核源码根目录]   (默认为当前目录)
#
# 修正记录:
#   v2: 移除 f2fs 段 #else 回退分支中多余的 ", false" 参数
#       (上游笔误: 4 参的 LZ4_decompress_safe 被传入 5 参, 在
#        !CONFIG_KERNEL_MODE_NEON 的配置下会编译失败)
# ============================================================================

set -euo pipefail

KERNEL_DIR="${1:-.}"
cd "$KERNEL_DIR"

# ---- 环境检查 ---------------------------------------------------------------
if [ ! -f crypto/lz4.c ]; then
    echo "错误: 当前目录不像内核源码根目录 (缺少 crypto/lz4.c)" >&2
    exit 1
fi

if ! grep -rq "LZ4_arm64_decompress_safe" lib/ include/ 2>/dev/null; then
    echo "错误: 内核树中不存在 LZ4_arm64_decompress_safe 符号。" >&2
    echo "       请先应用包含 lz4armv8 NEON 实现的 LZ4 1.10.0 补丁。" >&2
    exit 1
fi

echo "==> 应用 LZ4 NEON 加速挂钩 ($(pwd))"

PATCHED=0
SKIPPED=0
FAILED=0

already_patched() {
    grep -q "LZ4_arm64_decompress_safe" "$1" 2>/dev/null
}

# ---- 通用修补例程: $1=目标文件  $2=perl 表达式 --------------------------------
apply_patch() {
    local f="$1"
    local expr="$2"

    if [ ! -f "$f" ]; then
        echo "  [跳过] $f (文件不存在)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if already_patched "$f"; then
        echo "  [跳过] $f (已修补, 幂等跳过)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if ! perl -i -0777 -pe "$expr" "$f"; then
        echo "  [失败] $f (perl 执行错误)" >&2
        FAILED=$((FAILED + 1))
        return 0
    fi

    if already_patched "$f"; then
        echo "  [成功] $f"
        PATCHED=$((PATCHED + 1))
    else
        echo "  [失败] $f (正则未命中, 请核对该文件中 LZ4 调用的实际格式)" >&2
        FAILED=$((FAILED + 1))
    fi
    return 0
}

# ---- 1. crypto/lz4.c — zram lz4 后端 ----------------------------------------
apply_patch crypto/lz4.c \
's{(\t)int out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);}{${1}#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}int out_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n${1}#else\n${1}int out_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n${1}#endif};'

# ---- 2. crypto/lz4hc.c — zram lz4hc 后端 ------------------------------------
apply_patch crypto/lz4hc.c \
's{(\t)int out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);}{${1}#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}int out_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n${1}#else\n${1}int out_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n${1}#endif};'

# ---- 3. fs/f2fs/compress.c — F2FS 压缩读取 ----------------------------------
# 注意: #else 回退分支保持原版 4 参调用 (不带 ", false") —— 本版本修正点
apply_patch fs/f2fs/compress.c \
's{(\t)ret = LZ4_decompress_safe\(dic->cbuf->cdata, dic->rbuf,\s*\n\s*dic->clen, dic->rlen\);}{${1}#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}ret = LZ4_arm64_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n${1}\t\t\t\t\tdic->clen, dic->rlen, false);\n${1}#else\n${1}ret = LZ4_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n${1}\t\t\t\t\tdic->clen, dic->rlen);\n${1}#endif};'

# ---- 4. fs/incfs/data_mgmt.c — Incremental FS -------------------------------
apply_patch fs/incfs/data_mgmt.c \
's{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}{${1}#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len,\n${1}\tdst.len, false);\n${1}#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len,\n${1}\tdst.len);\n${1}#endif};'

# ---- 汇总 -------------------------------------------------------------------
echo ""
echo "==> LZ4 NEON 补丁完成: ${PATCHED} 成功, ${SKIPPED} 跳过, ${FAILED} 失败"

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
