#!/bin/bash
# mirror-check.sh — components 纯逻辑段 .ets ↔ tests/mirror/*.mjs 同构镜像校验
#
# 复用 scripts/qr-mirror-check.sh 的两层比对模式（brief 允许的务实做法）：
#   1) 骨架行比对：.ets 侧按 MIRROR-BEGIN..MIRROR-END 标记切片（组件段不进
#      比对），两侧同走一遍归一化（剥块注释/行注释/import/类型注解/export·
#      private·readonly/new 泛型），逐行顺序比对。逻辑行必须一一对应。
#   2) 导出名集合比对：export class/function/const 名单一致。
# 任一不一致 → 非零退出。改任一侧后必须先跑通本脚本。
#
# 用法：entry/src/main/ets/components/tests/mirror-check.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../../.." && pwd)"
SRC="$ROOT/entry/src/main/ets/components"
MIR="$SRC/tests/mirror"

NODE_SCRIPT="$(mktemp /tmp/card-mirror-XXXXXX.mjs)"
SLICE="$(mktemp /tmp/card-mirror-slice-XXXXXX.ets)"
trap 'rm -f "$NODE_SCRIPT" "$SLICE"' EXIT
cat > "$NODE_SCRIPT" <<'EOF'
import fs from 'node:fs';

const [etsPath, mjsPath] = process.argv.slice(2, 4);

// 归一化单行：剥块注释（跨行状态）/ // 行注释，字符串感知
function stripLine(raw, st) {
  let line = '';
  let i = 0;
  while (i < raw.length) {
    const c = raw[i];
    if (st.inBlock) {
      if (c === '*' && raw[i + 1] === '/') { st.inBlock = false; i += 2; continue; }
      i++;
      continue;
    }
    if (st.inStr) {
      line += c;
      if (c === '\\') { line += raw[i + 1] ?? ''; i += 2; continue; }
      if (c === st.inStr) st.inStr = null;
      i++;
      continue;
    }
    if (c === '/' && raw[i + 1] === '*') { st.inBlock = true; i += 2; continue; }
    if (c === '/' && raw[i + 1] === '/') break;
    line += c;
    i++;
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
  const st = { inBlock: false, inStr: null };
  for (const raw of text.split('\n')) {
    // 平台适配行跳过：两侧标记 MIRROR-SKIP 的行各自实现（如 utf8Bytes 函数体）
    if (raw.includes('MIRROR-SKIP')) continue;
    let line = stripLine(raw, st).trim();
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

# PAIRS：镜像名（.ets 源 + 是否切片，见 case）
PAIRS=(networkcardstatus planeticon)

fail=0
for name in "${PAIRS[@]}"; do
  case "$name" in
    networkcardstatus) ets="$SRC/NetworkCardView.ets"; marked=1 ;;
    planeticon) ets="$SRC/PlanetIcon.ets"; marked=1 ;;
    *) ets=""; marked=0 ;;
  esac
  mjs="$MIR/$name.mjs"

  if [ ! -f "$ets" ] || [ ! -f "$mjs" ]; then
    echo "✗ $name: 缺文件 ($ets / $mjs)"
    fail=1
    continue
  fi

  if [ "$marked" -eq 1 ]; then
    awk '/MIRROR-BEGIN/{f=1;next} /MIRROR-END/{f=0} f' "$ets" > "$SLICE"
    cmp_in="$SLICE"
  else
    cmp_in="$ets"
  fi

  if node "$NODE_SCRIPT" "$cmp_in" "$mjs"; then
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
echo "镜像一致（${#PAIRS[@]} 对）。"
