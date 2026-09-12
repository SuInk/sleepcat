#!/bin/bash
# 跑单元测试。纯 Command Line Tools 环境没有 XCTest，用 Swift Testing；
# 但 CLT 的构建系统不会自动挂 TestingMacros 宏插件，这里手动指给编译器。
set -euo pipefail
cd "$(dirname "$0")"

PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
ARGS=()
[[ -f "$PLUGIN" ]] && ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")

swift test "${ARGS[@]+"${ARGS[@]}"}" "$@"
