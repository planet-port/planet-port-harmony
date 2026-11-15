#!/bin/bash
# qr-mirror-check.sh — qrtransfer 七文件 .ets ↔ tests/mirror/*.mjs 同构镜像校验
#
# 务实做法（brief 允许）：不做全文 AST diff，做两层比对——
#   1) 骨架行比对：两侧同走一遍归一化（去注释/去 import/去类型注解/去
#      export·private·readonly/new 泛型），逐行顺序比对。逻辑行必须一一对应。
#   2) 导出名集合比对：export class/function/const 名单一致。
# 任一不一致 → 非零退出。改任一侧后必须先跑通本脚本。
#
# 用法：scripts/qr-mirror-check.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/entry/src/main/ets/qrtransfer"
MIR="$SRC/tests/mirror"

NODE_SCRIPT="$(mktemp /tmp/qr-mirror-XXXXXX.mjs)"
trap 'rm -f "$NODE_SCRIPT"' EXIT
cat > "$NODE_SCRIPT" <<'EOF'
import fs from 'node:fs';

const [etsPath, mjsPath] = process.argv.slice(2, 4);

// 引号感知地剥掉 // 行注释
function stripComment(line) {
  let inStr = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (c === "'" || c === '"') { inStr = c; continue; }
    if (c === '/' && line[i + 1] === '/') return line.slice(0, i);
  }
  return line;
}

// 类型注解剥离：标识符或 )/]/$ 后的 ":" 起，吃掉类型表达式至深度 0 的 , = ; { ) >
function stripTypes(line) {
  let out = '';
  let prev = '';
  let i = 0;
  while (i < line.length) {
    const c = line[i];
    if (c === "'" || c === '"') {
      const q = c;
      out += c; i++;
      while (i < line.length && line[i] !== q) {
        if (line[i] === '\\') { out += line[i] + (line[i + 1] ?? ''); i += 2; continue; }
        out += line[i]; i++;
      }
      if (i < line.length) { out += line[i]; i++; }
      prev = q;
      continue;
    }
    if (c === ':' && /[A-Za-z0-9_$)\]]/.test(prev)) {
      let depth = 0;
      let j = i + 1;
      while (j < line.length) {
        const k = line[j];
        if (k === '<' || k === '[') depth++;
        else if (k === '>' || k === ']') { if (depth === 0) break; depth--; }
        else if (depth === 0 && (k === ',' || k === ';' || k === '{' || k === ')')) break;
        else if (depth === 0 && k === '=') break;
        j++;
      }
      i = j;
      // 类型消费会吞掉 '=' / '{' 前的空格（`c: number = i`、`) {`），补一个；
      // 断在 , ) ; 前则不需要（`data ) ` 应还原为 `data)`）
      if ((line[j] === '=' || line[j] === '{') && out.length > 0 && !/\s$/.test(out)) {
        out += ' ';
      }
      continue;
    }
    if (!/\s/.test(c)) prev = c;
    out += c;
    i++;
  }
  return out;
}

function skeleton(text) {
  const lines = [];
  for (const raw of text.split('\n')) {
    let line = stripComment(raw).trim();
    if (line === '') continue;
    if (/^import\s/.test(line)) continue;
    if (/^(export\s+)?type\s/.test(line)) continue; // TS 类型别名无运行时形态
    line = line.replace(/\b(export|private|readonly|declare)\b/g, '');
    line = line.replace(/new\s+([A-Za-z_$][\w$]*)<[^<>]*>/g, 'new $1');
    line = stripTypes(line);
    line = line.replace(/\s+/g, ' ').trim();
    if (line !== '') lines.push(line);
  }
  return lines;
}

function exportNames(text) {
  const names = [];
  for (const m of text.matchAll(/\bexport\s+(class|function|const)\s+([A-Za-z_$][\w$]*)/g)) {
    names.push(m[2]);
  }
  return names.sort();
}

const ets = fs.readFileSync(etsPath, 'utf8');
const mjs = fs.readFileSync(mjsPath, 'utf8');

let bad = 0;
const a = skeleton(ets);
const b = skeleton(mjs);
const n = Math.max(a.length, b.length);
for (let i = 0; i < n; i++) {
  if (a[i] !== b[i]) {
    console.log(`  行 ${i + 1} 不一致:`);
    console.log(`    ets: ${a[i] === undefined ? '<无>' : a[i]}`);
    console.log(`    mjs: ${b[i] === undefined ? '<无>' : b[i]}`);
    bad++;
    if (bad >= 8) { console.log('  （更多差异省略）'); break; }
  }
}
const ea = JSON.stringify(exportNames(ets));
const eb = JSON.stringify(exportNames(mjs));
if (ea !== eb) {
  console.log(`  导出名不一致: ets=${ea} mjs=${eb}`);
  bad++;
}
if (bad > 0) process.exit(1);
EOF

PAIRS=(base45 crc32 deflate qrframe chunkplanner payloadcontainer qrtransfer)

fail=0
for name in "${PAIRS[@]}"; do
  case "$name" in
    base45) ets="$SRC/Base45.ets" ;;
    crc32) ets="$SRC/CRC32.ets" ;;
    deflate) ets="$SRC/Deflate.ets" ;;
    qrframe) ets="$SRC/QRFrame.ets" ;;
    chunkplanner) ets="$SRC/ChunkPlanner.ets" ;;
    payloadcontainer) ets="$SRC/PayloadContainer.ets" ;;
    qrtransfer) ets="$SRC/QRTransfer.ets" ;;
    *) ets="" ;;
  esac
  mjs="$MIR/$name.mjs"

  if [ ! -f "$ets" ] || [ ! -f "$mjs" ]; then
    echo "✗ $name: 缺文件 ($ets / $mjs)"
    fail=1
    continue
  fi

  if node "$NODE_SCRIPT" "$ets" "$mjs"; then
    echo "✓ $name"
  else
    echo "✗ $name"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "镜像不一致：改一处必须同步另一处。"
  exit 1
fi
echo "镜像一致（7 对）。"
