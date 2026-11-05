#!/bin/bash
# Oasis 发布打包：release 构建 + 拷贝二进制到 ./dist
# 用法: bash scripts/build-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 沙箱下 riot 需要写 ~/.riot；用工作区内 HOME 副本
export HOME="$ROOT/.fakehome"

echo "[1/3] release 构建 (oasis)..."
riot build --release -p oasis

mkdir -p dist
BIN_DIR="_build/release/$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')/out/oasis"
if [ ! -d "$BIN_DIR" ]; then
  BIN_DIR="$(find _build/release -type d -name oasis -path '*out*' | head -1)"
fi

echo "[2/3] 拷贝二进制 -> dist/"
cp "$BIN_DIR/oasis" dist/oasis
cp "$BIN_DIR/oasis-mock" dist/oasis-mock 2>/dev/null || true
chmod +x dist/oasis dist/oasis-mock 2>/dev/null || true

echo "[3/3] 验证"
./dist/oasis --example-config | head -3
echo
echo "完成:"
echo "  ./dist/oasis --config oasis.toml          # 启动门户"
echo "  ./dist/oasis --self-test                  # 全链路自检"
echo "  ./dist/oasis ask \"你好\" --stream         # CLI 提问"
