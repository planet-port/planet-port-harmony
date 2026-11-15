// iOS Tests/QRTransferCodecTests.swift 全用例直译 + PayloadContainer 用例
// （Android PayloadContainerTest.kt 同源直译，brief 点名要求）+
// iOS 金标压缩容器向量（Android GoldenVectorTest.kt 抄录）。
// 被测对象：tests/mirror/*.mjs（与 ../qrtransfer/*.ets 逐行同构）。

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Base45 } from './mirror/base45.mjs';
import { CRC32 } from './mirror/crc32.mjs';
import { Deflate } from './mirror/deflate.mjs';
import { PayloadContainer, PayloadField } from './mirror/payloadcontainer.mjs';
import { QRTransfer } from './mirror/qrtransfer.mjs';
import { QRTransferErrorCode } from './mirror/qrframe.mjs';
import { sampleData, roundTripData, utf8, hexToBytes, IOS_GOLDEN_CONTAINER_HEX } from './golden.mjs';

// ---- iOS QRTransferCodecTests ----

test('testBase45KnownVectors', () => {
  assert.equal(Base45.encode(utf8('AB')), 'BB8');
  assert.equal(Base45.encode(utf8('He')), '%69');
});

test('testBase45RoundTrip', () => {
  // 覆盖奇偶长度与较长数据
  for (const size of [1, 2, 3, 31, 32, 100, 1024]) {
    const data = roundTripData(size);
    assert.deepEqual(Base45.decode(Base45.encode(data)), data);
  }
});

test('testBase45RejectsBadInput', () => {
  assert.equal(Base45.decode('abc|'), null); // '|' 不在字母表
  assert.equal(Base45.decode('A'), null); // 落单 1 字符不合法
  assert.equal(Base45.decode('::::'), null); // 解出值 > 0xFFFF
});

test('testCRC32KnownVectors', () => {
  assert.equal(CRC32.checksum(new Uint8Array(0)), 0);
  assert.equal(CRC32.checksum(utf8('123456789')), 0xCBF43926);
});

test('testDeflateRoundTripAndContainer', () => {
  const data = utf8('planet'.repeat(200));
  const container = Deflate.compress(data);
  assert.ok(container !== null);
  // 容器头 4 字节 = 原始长度小端
  assert.equal(container[0] | (container[1] << 8) | (container[2] << 16) | (container[3] << 24),
    data.length);
  assert.deepEqual(Deflate.decompress(container), data);
  assert.equal(Deflate.decompress(new Uint8Array([0, 0, 0, 0])), null);
});

// ---- brief 点名边界：空载荷（iOS 无显式用例；compress(nil) → nil 同语义） ----

test('emptyPayloadIsRejectedLikeIosCompressNil', () => {
  assert.equal(Deflate.compress(new Uint8Array(0)), null);
  assert.throws(() => QRTransfer.encode(new Uint8Array(0)),
    (e) => e.code === QRTransferErrorCode.Corrupt);
});

// ---- PayloadContainer（Android PayloadContainerTest.kt 直译） ----

test('roundTripMultipleFields', () => {
  const planet = Uint8Array.from({ length: 64 }, (_, i) => (i * 13 + 5) % 256);
  const fields = [
    new PayloadField(1, planet),
    new PayloadField(2, utf8('测试 Planet')),
    new PayloadField(4, new Uint8Array([0x0A, 0x0B])),
  ];
  const decoded = PayloadContainer.decode(PayloadContainer.encode(fields));
  assert.ok(decoded !== null);
  assert.equal(decoded.size, 3);
  assert.deepEqual(decoded.get(1), planet);
  assert.deepEqual(decoded.get(2), utf8('测试 Planet'));
  assert.deepEqual(decoded.get(4), new Uint8Array([0x0A, 0x0B]));
});

test('unknownKeyPreservedAndSkippable', () => {
  // 组件对 key 含义零假设：未知 key(5) 照样解出，由应用层自行忽略
  const container = PayloadContainer.encode([
    new PayloadField(1, new Uint8Array([1])),
    new PayloadField(5, new Uint8Array([9])),
  ]);
  const decoded = PayloadContainer.decode(container);
  assert.ok(decoded !== null);
  assert.equal(decoded.size, 2);
  assert.deepEqual(decoded.get(5), new Uint8Array([9]));
});

test('duplicateKeyLastWins', () => {
  const container = PayloadContainer.encode([
    new PayloadField(2, utf8('first')),
    new PayloadField(2, utf8('last')),
  ]);
  const decoded = PayloadContainer.decode(container);
  assert.ok(decoded !== null);
  assert.deepEqual(decoded.get(2), utf8('last'));
});

test('keyZeroRejected', () => {
  // 编码侧：key 0 条目直接丢弃
  const encoded = PayloadContainer.encode([
    new PayloadField(0, new Uint8Array([1])),
    new PayloadField(1, new Uint8Array([2])),
  ]);
  const decoded = PayloadContainer.decode(encoded);
  assert.ok(decoded !== null);
  assert.equal(decoded.size, 1);
  // 解码侧：显式 key 0 → 整容器非法
  const bytes = new Uint8Array([0x5A, 0x54, 0x50, 0, 0, 0, 0, 0]);
  assert.equal(PayloadContainer.decode(bytes), null);
});

test('emptyFieldsYieldsMagicOnlyContainer', () => {
  const decoded = PayloadContainer.decode(PayloadContainer.encode([]));
  assert.ok(decoded !== null);
  assert.equal(decoded.size, 0);
});

test('badMagicReturnsNull', () => {
  assert.equal(PayloadContainer.decode(new Uint8Array(0)), null);
  assert.equal(PayloadContainer.decode(utf8('ZT')), null);
  assert.equal(PayloadContainer.decode(utf8('XTP')), null);
  assert.equal(PayloadContainer.decode(new Uint8Array([0x01, 0x02, 0x03, 0x04])), null);
});

test('truncatedContainerReturnsNull', () => {
  const entry1 = Uint8Array.from({ length: 32 }, (_, i) => i);
  const container = PayloadContainer.encode([
    new PayloadField(1, entry1),
    new PayloadField(2, utf8('name')),
  ]);
  // 设计特性：无总长字段，数据尾即容器尾——截断恰落在条目边界(3、3+37)
  // 时前缀条目本身是合法容器；其余任何截断点(条目中途)必须返回 null
  const boundaryPrefix = new Set([3, 3 + 5 + entry1.length]);
  for (let len = 0; len <= container.length; len++) {
    const decoded = PayloadContainer.decode(container.slice(0, len));
    if (boundaryPrefix.has(len) || len === container.length) {
      assert.ok(decoded !== null, `len=${len}`);
    } else {
      assert.equal(decoded, null, `len=${len}`);
    }
  }
});

test('lenOutOfRangeReturnsNull', () => {
  // 条目头 5 字节齐全但 len 声称超过剩余数据
  const bytes = new Uint8Array([0x5A, 0x54, 0x50, 1, 0x10, 0, 0, 0, 0, 0, 0, 0]);
  assert.equal(PayloadContainer.decode(bytes), null);
  // len 符号位为 1(按 32 位读数为负)同样视同越界
  const negative = new Uint8Array([0x5A, 0x54, 0x50, 1, 0, 0, 0, 0x80, 0, 0, 0, 0]);
  assert.equal(PayloadContainer.decode(negative), null);
});

// ---- iOS 跨端金标：压缩容器（Android GoldenVectorTest.iosCompressedContainerDecompressOnAndroid） ----

test('iosCompressedContainerDecompressesToSampleData300', () => {
  const container = hexToBytes(IOS_GOLDEN_CONTAINER_HEX);
  assert.deepEqual(Deflate.decompress(container), sampleData(300));
});

