// planetimporter.test.mjs — planet 二进制布局 / ZTP 载荷解析自测（node --test）
//
// 被测对象：mirror/planetimporter.mjs（PlanetImporter.ets MIRROR 切片的逐行
// 镜像）。权威语义：Core/node/World.hpp serialize（planet 非 forSign 分支）
// + Identity.hpp serialize(false) 的字节布局直译——
//   [0]=0x01 + [1..8]worldId(BE) + [9..16]ts(BE) + [17..80]pubkey(64B) +
//   [81..176]sig(96B) + [177]numRoots(u8) + 每 root 5B 地址+1B 类型+64B 公钥
//   +1B 私钥长度。
// 用例分四组：①字节布局黄金值（含 >2^53 worldId 的 hex 承载精度）②截断/
// 非法拒收 ③Earth 常量种子 hex ④ZTP 容器字段映射与缺省语义。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  PLANET_TYPE_BYTE, beBytesHex, beBytesNumber, hex16FromNumber,
  worldIdOf, rootAddressOf, inspectBytes, parsePlanetPayload,
} from './mirror/planetimporter.mjs';
import { PayloadContainer, PayloadField } from '../../qrtransfer/tests/mirror/payloadcontainer.mjs';

/** 合成 planet 二进制（World.hpp serialize 直译；pubkey/sig 以零字节占位——
 *  布局解析只消费偏移与长度，不验签） */
function planetBytes(worldId, ts, addr5, roots = 1) {
  const b = [PLANET_TYPE_BYTE];
  for (let i = 7; i >= 0; i--) b.push(Number((BigInt(worldId) >> BigInt(i * 8)) & 0xffn));
  for (let i = 7; i >= 0; i--) b.push(Math.floor(ts / 256 ** i) % 256);
  for (let i = 0; i < 64; i++) b.push(0); // updatesMustBeSignedBy 公钥
  for (let i = 0; i < 96; i++) b.push(0); // signature
  b.push(roots);
  for (let r = 0; r < roots; r++) {
    for (const byte of addr5) b.push(byte);
    b.push(0); // identity 类型位
    for (let i = 0; i < 64; i++) b.push(0); // 公钥
    b.push(0); // 私钥长度（无私钥）
  }
  return Uint8Array.from(b);
}

const BIG_WORLD_ID = 'deadbeef12345678'; // 16045690981402826360 > 2^53
const TS = 1700000000;
const ADDR = Uint8Array.from([0x99, 0x2e, 0x0e, 0x63, 0x3b]);

test('黄金值：worldId / timestamp / root 地址偏移直读', () => {
  const p = planetBytes(BigInt('0x' + BIG_WORLD_ID), TS, ADDR);
  assert.equal(p.length, 249); // 178 + 1 root × (5+1+64+1)
  assert.equal(worldIdOf(p), BIG_WORLD_ID);
  assert.equal(rootAddressOf(p), '992e0e633b');
  const info = inspectBytes(p);
  assert.equal(info.worldIdHex, BIG_WORLD_ID);
  assert.equal(info.timestamp, TS);
  assert.equal(info.fileSize, 249);
});

test('>2^53 worldId 精度：hex 逐字节读不受双精度整数上界约束', () => {
  // 若走 number 合成再 % 16 取位，16045690981402826360 ≫ 2^53 会丢低位
  assert.ok(BigInt('0x' + BIG_WORLD_ID) > BigInt(2) ** 53n);
  const p = planetBytes(BigInt('0x' + BIG_WORLD_ID), TS, ADDR);
  assert.equal(beBytesHex(p, 1, 8), BIG_WORLD_ID);
});

test('多 root：地址取首 root（178..182），后续 root 不影响', () => {
  const p = planetBytes(1n, TS, ADDR, 2);
  assert.equal(rootAddressOf(p), '992e0e633b');
});

test('截断/非法拒收（worldIdOf ≥9 + 头字节；inspectBytes ≥17）', () => {
  const p = planetBytes(1n, TS, ADDR);
  assert.equal(worldIdOf(p.slice(0, 8)), null); // 缺尾字节
  assert.equal(inspectBytes(p.slice(0, 16)), null);
  assert.ok(inspectBytes(p.slice(0, 17)) !== null); // 恰 17B 可解读
  const wrongType = Uint8Array.from(p);
  wrongType[0] = 0x02; // moon/未知类型
  assert.equal(worldIdOf(wrongType), null);
  assert.equal(inspectBytes(wrongType), null);
  assert.equal(rootAddressOf(wrongType), null);
  assert.equal(worldIdOf(new Uint8Array(0)), null);
});

test('root 地址拒收：长度不足 183 或 numRoots=0', () => {
  const p = planetBytes(1n, TS, ADDR);
  assert.equal(rootAddressOf(p.slice(0, 182)), null); // 首地址段不完整
  const noRoots = Uint8Array.from(p);
  noRoots[177] = 0;
  assert.equal(rootAddressOf(noRoots), null);
});

test('Earth 常量种子：149604618 → 0000000008eac90a（iOS ZT_WORLD_ID_EARTH）', () => {
  assert.equal(hex16FromNumber(149604618), '0000000008eac90a');
  assert.equal(BigInt('0x' + hex16FromNumber(149604618)), 149604618n); // 往返一致
  assert.equal(hex16FromNumber(0), '0000000000000000');
  assert.equal(hex16FromNumber(-1), '0000000000000000'); // 非法输入按 0
});

test('beBytesNumber：大端段按 number 解（timestamp ≪ 2^53）', () => {
  const p = planetBytes(1n, TS, ADDR);
  assert.equal(beBytesNumber(p, 9, 8), TS);
});

test('ZTP 容器：key 1=planet/2=名称/3=图标/4=底色，未知 key 忽略', () => {
  const p = planetBytes(1n, TS, ADDR);
  const container = PayloadContainer.encode([
    new PayloadField(1, p),
    new PayloadField(2, Buffer.from('小行星', 'utf8')),
    new PayloadField(3, Buffer.from('cat', 'utf8')),
    new PayloadField(4, Buffer.from('#FFAA00', 'utf8')),
    new PayloadField(9, Buffer.from('unknown', 'utf8')), // 未知 key
  ]);
  const payload = parsePlanetPayload(container);
  assert.ok(payload !== null);
  assert.deepEqual(Array.from(payload.planet), Array.from(p));
  assert.equal(payload.name, '小行星');
  assert.equal(payload.icon, 'cat');
  assert.equal(payload.iconColor, '#FFAA00');
});

test('ZTP 容器缺省语义：缺 planet 字段 / 非 ZTP 数据 / 缺文本字段 → null/缺省', () => {
  const p = planetBytes(1n, TS, ADDR);
  // 缺 planet（key 1）→ null（iOS PlanetPayload.parse 直译）
  const noPlanet = PayloadContainer.encode([new PayloadField(2, Buffer.from('x'))]);
  assert.equal(parsePlanetPayload(noPlanet), null);
  // 非 ZTP 数据（裸 planet 载荷）→ null（统一「二维码数据无效」提示路径）
  assert.equal(parsePlanetPayload(p), null);
  assert.equal(parsePlanetPayload(new Uint8Array(0)), null);
  // planet 存在但文本字段缺省 → 对应字段 null
  const onlyPlanet = PayloadContainer.encode([new PayloadField(1, p)]);
  const payload = parsePlanetPayload(onlyPlanet);
  assert.ok(payload !== null);
  assert.equal(payload.name, null);
  assert.equal(payload.icon, null);
  assert.equal(payload.iconColor, null);
});

test('重复 key 取后值（PayloadContainer.decode 语义贯通）', () => {
  const p = planetBytes(1n, TS, ADDR);
  const container = PayloadContainer.encode([
    new PayloadField(2, Buffer.from('first')),
    new PayloadField(2, Buffer.from('second')),
    new PayloadField(1, p),
  ]);
  const payload = parsePlanetPayload(container);
  assert.equal(payload.name, 'second');
});
