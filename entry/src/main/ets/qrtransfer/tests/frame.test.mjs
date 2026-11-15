// iOS Tests/QRTransferFrameTests.swift 全用例直译 + iOS 金标帧向量
// （Android GoldenVectorTest.kt 抄录：iOS 产帧必须可解、且本端编码逐帧一致）。
// QRRender.fits 在 node 侧以 harnessFits 仿真（ISO 18004 byte 模式容量上界，
// 与库内缺省探测互为独立实现）。

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { ChunkPlanner } from './mirror/chunkplanner.mjs';
import { QRTransfer } from './mirror/qrtransfer.mjs';
import { QRFrame, QRTransferErrorCode } from './mirror/qrframe.mjs';
import {
  sampleData, noisyData, harnessFits, IOS_GOLDEN_FRAMES,
} from './golden.mjs';

function chunkOf(frame) {
  // Base45 字母表不含 '|'，split 后第 6 段即数据段
  return frame.split('|')[5];
}

// ---- iOS QRTransferFrameTests ----

// 探测串前缀必须携带真实帧头（等形等长），帧格式变更时两者失配会让容量密度保证静默失效
test('testProbePrefixMatchesHeaderLen', () => {
  assert.equal(ChunkPlanner.probePrefix.length, QRTransfer.headerLen);
});

test('testSingleFrameRoundTrip', () => {
  const data = sampleData(300);
  const frames = QRTransfer.encode(data, 117);
  assert.equal(frames.length, 1);
  assert.ok(harnessFits(frames[0], 117));
  const parsed = frames.map((f) => QRTransfer.parse(f)).filter((x) => x !== null);
  assert.deepEqual(QRTransfer.decodeStrict(parsed), data);
});

test('testMultiFrameUniformPaddedAndRestored', () => {
  const data = sampleData(2000);
  // 53 模块（v9）小容量强制多帧
  const frames = QRTransfer.encode(data, 53);
  assert.ok(frames.length > 1);
  // 每帧数据段字符数严格相等（无法整除时末帧补 '0' 对齐）
  const chunkLens = new Set(frames.map((f) => chunkOf(f).length));
  assert.equal(chunkLens.size, 1);
  // 每一帧真实形态都不得超过容量上限（探测失真回归防护）
  for (const frame of frames) {
    assert.ok(harnessFits(frame, 53), `帧超出 53 模块：长度 ${frame.length} 字符`);
  }
  // 剥补位后完整还原
  const parsed = frames.map((f) => QRTransfer.parse(f)).filter((x) => x !== null);
  assert.deepEqual(QRTransfer.decodeStrict(parsed), data);
});

test('testTooLargeThrows', () => {
  assert.throws(() => QRTransfer.encode(noisyData(200_000), 53),
    (e) => e.code === QRTransferErrorCode.TooLarge);
});

test('testParseRejectsBadInput', () => {
  assert.equal(QRTransfer.parse('hello world'), null);
  assert.equal(QRTransfer.parse('ZTQR1|02|03|deadbeef|00123|xx'), null); // index > total
  assert.equal(QRTransfer.parse('ZTQR1|2|01|deadbeef|00123|xx'), null); // 位数不足
  assert.equal(QRTransfer.parse('ZTQR1|02|01|deadbeef|0123|xx'), null); // len 位数不足
});

test('testDecodeDetectsMissingAndCorrupt', () => {
  const data = sampleData(500);
  const frames = QRTransfer.encode(data, 53);
  const parsed = frames.map((f) => QRTransfer.parse(f)).filter((x) => x !== null);
  // 缺帧 → incomplete
  assert.throws(() => QRTransfer.decodeStrict(parsed.slice(0, -1)),
    (e) => e.code === QRTransferErrorCode.Incomplete);
  // 篡改校验和 → corrupt（CRC 兜底拦截）
  const tampered = new QRFrame(parsed[0].total, parsed[0].index, 0, parsed[0].length, parsed[0].payload);
  assert.throws(() => QRTransfer.decodeStrict([...parsed.slice(1), tampered]),
    (e) => e.code === QRTransferErrorCode.Corrupt);
});

// ---- iOS 跨端金标（Android GoldenVectorTest.kt 直译） ----

test('iosFramesDecodeOnHarmony', () => {
  const parsed = IOS_GOLDEN_FRAMES.map((f) => QRTransfer.parse(f)).filter((x) => x !== null);
  assert.equal(parsed.length, IOS_GOLDEN_FRAMES.length);
  assert.deepEqual(QRTransfer.decodeStrict(parsed), sampleData(300));
  // 计划接口形态（失败返回 null）同验：完整帧集合必须通过
  assert.deepEqual(QRTransfer.decode(parsed), sampleData(300));
});

test('harmonyEncodeMatchesIosGoldenFrameByFrame', () => {
  const harmony = QRTransfer.encode(sampleData(300), 117);
  assert.deepEqual(harmony, IOS_GOLDEN_FRAMES);
});
