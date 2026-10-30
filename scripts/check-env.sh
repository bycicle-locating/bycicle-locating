#!/usr/bin/env bash
# 检查本机是否具备构建三层所需工具链。
# 用法: bash scripts/check-env.sh
# 退出码: 0 = 三层工具链齐全, 1 = 有缺失（仅提示, 不阻塞文档工作）

set -uo pipefail

missing=0

# check <名称> <命令> [版本参数]
check() {
    local name="$1" cmd="$2" verarg="${3:---version}"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver="$("$cmd" $verarg 2>&1 | head -n 1)"
        # Windows 上 python 可能是 Microsoft Store 占位符，命令存在但无法执行
        if [[ $? -ne 0 || -z "$ver" ]]; then
            printf '  [异常] %-10s 命令存在但无法执行（可能是占位符）: %s\n' "$name" "$cmd"
            missing=$((missing + 1))
        else
            printf '  [就绪] %-10s %s\n' "$name" "$ver"
        fi
    else
        printf '  [缺失] %-10s 未找到 %s\n' "$name" "$cmd"
        missing=$((missing + 1))
    fi
}

echo "== 基础 =="
check git git
check node node
check npm npm

echo
echo "== backend (Go 1.22+) =="
check go go version

echo
echo "== app (Flutter 3.22+ / Dart 3.4+) =="
check flutter flutter
check dart dart

echo
echo "== firmware (ESP-IDF v5.x) =="
check idf.py idf.py
if [[ -n "${IDF_PATH:-}" ]]; then
    echo "  [就绪] IDF_PATH  $IDF_PATH"
else
    echo "  [提示] IDF_PATH 未设置，需先 source \$IDF_PATH/export.sh"
fi
check cmake cmake
check ninja ninja

echo
echo "== 可选 =="
check docker docker
check mosquitto_pub mosquitto_pub

echo
if [[ $missing -eq 0 ]]; then
    echo "结论: 工具链齐全。"
    exit 0
else
    echo "结论: 有 $missing 项缺失/异常。缺失项对应的层无法构建，其余工作不受影响。"
    exit 1
fi
