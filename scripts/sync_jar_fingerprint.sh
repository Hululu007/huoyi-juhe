#!/usr/bin/env bash
# 同步 / 校验内置 jar 指纹（铁律：每次合 jar 完必跑本脚本）。
#
# 背景：火蚁TV +40/+41 曾因 zakatvJarMd5 声明过期（声明 2a8679b0…、
# 盘上 jar 实际 67bdfc39…）致 244 个内置 jar 站全未注册；修仙版 17 轮
# 核对时声明 f3679304… 与盘上 jar 一致，无此问题。本脚本把“合 jar 必
# 同步指纹”钉死在流程里，替代人工记忆。
#
# 用法（从仓库根目录执行）：
#   bash scripts/sync_jar_fingerprint.sh          # 同步：算出新 MD5 写回声明
#   bash scripts/sync_jar_fingerprint.sh --check  # 只校验：不一致就报错退出 1
#
# 覆盖：assets/jars/zakatv.jar -> zakatvJarMd5、
#       assets/jars/youtube.jar -> youtubeJarMd5，
#       声明文件：lib/services/zakatv_builtin.dart。
# 同步后务必跑 flutter test test/jar_builtin_test.dart（含指纹一致性测试）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECL_FILE="$ROOT/lib/services/zakatv_builtin.dart"
MODE="${1:-sync}"
if [[ "$MODE" != "sync" && "$MODE" != "--check" ]]; then
  echo "用法：$0 [--check]" >&2
  exit 2
fi

fail=0
sync_one() {
  local jar_path="$1" const_name="$2"
  local jar_file="$ROOT/$jar_path"
  if [[ ! -f "$jar_file" ]]; then
    echo "缺 jar：$jar_path" >&2
    fail=1
    return
  fi
  local actual
  actual="$(md5sum "$jar_file" | awk '{print $1}')"
  local declared
  declared="$(grep -oP "(?<=const String $const_name = ')[0-9a-f]{32}(?=')" "$DECL_FILE" || true)"
  if [[ "$actual" == "$declared" ]]; then
    echo "一致 $const_name=$actual ($jar_path)"
    return
  fi
  if [[ "$MODE" == "--check" ]]; then
    echo "不一致 $const_name：声明 $declared，盘上 $jar_path 实测 $actual" >&2
    fail=1
    return
  fi
  python3 - "$DECL_FILE" "$const_name" "$actual" <<'PY'
import re, sys
path, name, value = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding='utf-8').read()
new, n = re.subn(
    r"(const String " + re.escape(name) + r" = ')[0-9a-f]{32}(')",
    r"\g<1>" + value + r"\g<2>",
    src,
    count=1,
)
assert n == 1, f"未找到声明 {name}"
open(path, 'w', encoding='utf-8').write(new)
PY
  echo "已同步 $const_name：$declared -> $actual"
}

sync_one "assets/jars/zakatv.jar" "zakatvJarMd5"
sync_one "assets/jars/youtube.jar" "youtubeJarMd5"

if [[ "$fail" -ne 0 ]]; then
  echo "指纹校验失败：合 jar 后未同步声明，先跑不带 --check 的同步再提交。" >&2
  exit 1
fi
echo "指纹 OK。"
