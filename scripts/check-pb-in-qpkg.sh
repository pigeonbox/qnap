#!/usr/bin/env bash
# 门禁：QPKG 随包必须带 **pb CLI**（官方命令行客户端），且它**真的能跑**。
#
# # 为什么要有这道门禁
#
# `build-native.sh` 里 pb 是**源码编译**的（检出 server 同号 tag ⇒ 避开与
# server Release 流水线的竞态）⇒ 它的失败点是**静默降级**（编不出来就
# 不带 pb，应用照常可用）⇒ 没有门禁的话「qnap 用户到底能不能用 pb」
# 只能靠人工装包后才发现。
#
# 本门禁断言：
#   V1 打包目录里有 pb 的**双架构**二进制（x86_64/arm_64 的 bin/pb-linux-*）；
#   V2 这些二进制**可执行**（`--help` 能出用法文本 ⇒ 不是 0 字节/坏文件/
#      架构不符的错二进制——NAS 上架构错了会直接 exec format error）；
#   V3 安装完整性自检清单里**不含** pb 时要能看出来（QPKG 的 SHA256SUMS
#      由打包期产出、安装后逐个校验 ⇒ pb 也得在清单里，否则安装后不校验）。
#
# 负对照：删掉打包目录里的 pb ⇒ V1 必须红。
#
# 用法: bash scripts/check-pb-in-qpkg.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

QPKG_DIR="$ROOT/qpkg"

# ── V1 打包目录含 pb 双架构二进制 ──
v1_ok=1
# ⚠️ 文件名按 **GOARCH**（pb-linux-amd64 / pb-linux-arm64），
#    而 qarch 是 QPKG 的**目录名**（x86_64 / arm_64）⇒ 两者不能混用。
# 目录名（QPKG）与文件名（GOARCH）口径不同 ⇒ 成对列出，不用 set -- 分词。
for pair in "x86_64:amd64" "arm_64:arm64"; do
  qarch="${pair%%:*}"; goarch="${pair##*:}"
  f="$QPKG_DIR/${qarch}/bin/pb-linux-${goarch}"
  if [ ! -f "$f" ]; then
    bad "V1 打包目录缺 ${qarch}/bin/pb-linux-${qarch}" "路径 $f"
    v1_ok=0
    continue
  fi
  ok "V1 存在 ${qarch}/bin/pb-linux-${qarch}（$(du -h "$f" | cut -f1)）"
done

# ── V2 pb 可执行（架构/完整性）──
if [ "$v1_ok" = "1" ]; then
  for pair in "x86_64:amd64" "arm_64:arm64"; do
    qarch="${pair%%:*}"; goarch="${pair##*:}"
    f="$QPKG_DIR/${qarch}/bin/pb-linux-${goarch}"
    [ -f "$f" ] || continue
    # 交叉架构的二进制在本机**跑不了** ⇒ 只对「本机架构 + 本机 OS」做执行验证，
    # 其余用 `file` 静态判架构。
    #
    # ⚠️ 必须连 **OS 一起比**：本机可能是 arm64 的 **macOS** ⇒ 与 arm64 的
    #   **Linux** 二进制架构相同但 OS 不同 ⇒ 直接跑会「cannot execute binary file」
    #   ⇒ 门禁会红在与被测物无关的地方（实测：M 系列 Mac 上跑 arm64 Linux 产物）。
    host_arch="$(uname -m)"
    host_os="$(uname -s)"
    can_exec=0
    [ "$host_os" = "Linux" ] && can_exec=1
    host_match=0
    if [ "$can_exec" = "1" ]; then
      case "$goarch" in
        amd64) [ "$host_arch" = "x86_64" ] && host_match=1 ;;
        arm64) case "$host_arch" in aarch64|arm64) host_match=1 ;; esac ;;
      esac
    fi
    if [ "$host_match" = "1" ]; then
      # ⚠️ 不能用「退出码 == 0」判断可执行：pb 的用法错误退出码是 **2**
      #   （`pb --help` 属未知子命令 ⇒ 退出非 0）⇒ 用退出码判会**误判为不可执行**。
      #   ⇒ 判据：**能跑起来且输出里含用法/帮助文本**。
      out="$("$f" --help 2>&1)" || true
      if printf '%s' "$out" | grep -qE "用法|usage|子命令"; then
        ok "V2 ${qarch} 的 pb 可执行（输出了用法文本）"
      else
        bad "V2 ${qarch} 的 pb 执行异常（既没成功也没出用法文本）" "$(printf '%s' "$out" | head -c 200)"
      fi
    else
      kind="$(file -b "$f" 2>/dev/null || echo unknown)"
      case "$kind" in
        *"ELF"*"x86-64"*) ok "V2 ${qarch} 的 pb 架构正确（非本机，静态判定：${kind}）" ;;
        *"ELF"*"ARM aarch64"*|*"ELF"*"ARM64"*) ok "V2 ${qarch} 的 pb 架构正确（非本机，静态判定：${kind}）" ;;
        *) bad "V2 ${qarch} 的 pb 不是预期的 ELF 可执行文件" "$kind" ;;
      esac
    fi
  done
fi

# ── V3 安装完整性自检清单含 pb ──
#
# QPKG 的 SHA256SUMS 由打包期产出、安装后逐个校验（QDK 解包断流事故的固化）
# ⇒ pb 也必须在清单里，否则装出来不校验（半拉子安装查不出来）。
sums_checked=0
# 目录名（QPKG）与文件名（GOARCH）口径不同 ⇒ 成对列出，不用 set -- 分词。
for pair in "x86_64:amd64" "arm_64:arm64"; do
  qarch="${pair%%:*}"; goarch="${pair##*:}"
  sums="$QPKG_DIR/${qarch}/bin/SHA256SUMS"
  if [ ! -f "$sums" ]; then
    echo "  (跳过 V3：尚无 ${qarch}/bin/SHA256SUMS —— 打包期产物)"
    continue
  fi
  sums_checked=$((sums_checked + 1))
  if grep -q "pb-linux-${goarch}" "$sums"; then
    ok "V3 ${qarch}/bin/SHA256SUMS 含 pb"
  else
    bad "V3 ${qarch}/bin/SHA256SUMS 未含 pb" "安装后不会校验 pb 的完整性"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ pb 随包门禁通过（$PASS 项）"
  exit 0
fi
if [ "${PB_REQUIRED:-0}" != "1" ]; then
  # CI 阶段（bump PR）：server 同号 tag 还不存在 ⇒ pb 编不出来是**预期**的
  # ⇒ 只告警，不阻断（否则 bump PR 合不进去 ⇒ 列车死锁）。
  echo "⚠ pb 随包门禁未通过（$PASS 通过 / $FAIL 失败）——CI 阶段不阻断"
  echo "  （server 同号 tag 未就绪时 pb 会缺失；发布流水线以 PB_REQUIRED=1 硬断言）"
  exit 0
fi
echo "✗ pb 随包门禁失败（$PASS 通过 / $FAIL 失败）"
exit 1
