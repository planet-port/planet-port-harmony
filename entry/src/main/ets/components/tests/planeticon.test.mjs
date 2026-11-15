// planeticon.test.mjs — djb2 哈希算法自测（node --test）
//
// 被测对象：mirror/planeticon.mjs（PlanetIcon.ets MIRROR 切片的逐行镜像）。
// 权威语义：BigInt 参考实现对「UInt64 环绕 ×33 + 字节，seed 5381，结果
// % 1_000_003」的直译（iOS PlanetIcon.djb2）。两组实现全部样本一致才通过。
// 附带证明「逐步取模」与「精确环绕后取模」不等价——这正是 hi/lo 分解存在
// 的理由（2^64 mod 1_000_003 ≠ 0）。
import test from 'node:test';
import assert from 'node:assert/strict';

import { planetIconHash } from './mirror/planeticon.mjs';

const MOD = 1000003n;
const WRAP = (1n << 64n) - 1n; // UInt64 上界掩码

// BigInt 参考实现：逐字节 (h * 33 + b) & UInt64 上界
function djb2Ref(text) {
  const bytes = Buffer.from(text, 'utf8');
  let h = 5381n;
  for (const b of bytes) {
    h = (h * 33n + BigInt(b)) & WRAP;
  }
  return Number(h % MOD);
}

// 反例实现：中间态逐步取模（错误形态，用于证明不等价）
function djb2StepwiseMod(text) {
  const bytes = Buffer.from(text, 'utf8');
  let h = 5381n;
  for (const b of bytes) {
    h = (h * 33n + BigInt(b)) % MOD;
  }
  return Number(h);
}

const SAMPLES = [
  '', // 空串 = seed：5381 % 1000003 = 5381
  'a',
  'abc',
  'official', // 官方行星 id 域
  'Official Planet', // 展示名带空格
  'ziver', // 典型 ZT 用户名形态
  '官方行星', // 中文（UTF-8 三字节×4）
  '我的网络-01', // 中文 + 连字符 + 数字
  '🌍🚀', // emoji（UTF-8 四字节，代理对）
  'anim_al-key', // 资源 key 形态（连字符/下划线）
  'x'.repeat(1000), // 长串：hi 段进位与 2^64 环绕路径
  'The quick brown fox jumps over the lazy dog 0123456789 —— 混排 mixed 文本',
];

test('BigInt 参考实现对照：全部样本一致', () => {
  for (const s of SAMPLES) {
    assert.equal(planetIconHash(s), djb2Ref(s), `样本 ${JSON.stringify(s.slice(0, 24))}`);
  }
});

test('空串落 seed：5381', () => {
  assert.equal(planetIconHash(''), 5381);
});

test('结果域 [0, 1000003)', () => {
  for (const s of SAMPLES) {
    const h = planetIconHash(s);
    assert.ok(h >= 0 && h < 1000003, `越界 ${h}`);
    assert.ok(Number.isInteger(h));
  }
});

test('确定性：同输入同输出', () => {
  for (const s of SAMPLES) {
    assert.equal(planetIconHash(s), planetIconHash(s));
  }
});

test('不同输入不同落点（抽样防错值域坍缩）', () => {
  const seen = new Set(SAMPLES.map(planetIconHash));
  assert.ok(seen.size >= SAMPLES.length - 2, `落点过于集中：${seen.size}`);
});

test('长串触发 2^64 环绕路径（hi 段非零）', () => {
  // 33^8 ≈ 1.4e12 > 2^32：8 字节以上 hi 段必然进位；1000 字节样本必走环绕
  const s = 'wrap'.repeat(250); // 1000 字节
  assert.equal(planetIconHash(s), djb2Ref(s));
  // 证明该样本的参考实现中间态确实超过 2^32（hi 段参与运算）
  const bytes = Buffer.from(s, 'utf8');
  let h = 5381n;
  for (const b of bytes) h = h * 33n + BigInt(b); // 不做环绕
  assert.ok(h > WRAP, '样本未触达 UInt64 上界，环绕路径未被验证');
});

test('逐步取模与精确环绕不等价（hi/lo 分解存在的理由）', () => {
  // 长串样本上，错误实现（逐步取模）与权威实现必然分叉；
  // 若两者一致则环绕逻辑的测试形同虚设。
  const diverging = SAMPLES.filter((s) => planetIconHash(s) !== djb2StepwiseMod(s));
  assert.ok(diverging.length > 0, '未找到逐步取模的分叉样本');
  // 分叉样本上精确实现仍与参考实现一致
  for (const s of diverging) {
    assert.equal(planetIconHash(s), djb2Ref(s));
  }
});

test('字节级差异敏感（UTF-8 边界值）', () => {
  // 'é' 的两种 UTF-8 形态之外，验证相邻码点落点不同
  assert.notEqual(planetIconHash('网'), planetIconHash('絡'));
  assert.notEqual(planetIconHash('a'), planetIconHash('b'));
});
