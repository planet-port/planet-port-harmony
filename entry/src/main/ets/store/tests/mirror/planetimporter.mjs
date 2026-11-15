// 与 ../../PlanetImporter.ets 逻辑同构镜像（node 可执行形态）——与 .ets 的
// MIRROR-BEGIN/MIRROR-END 切片逐行对应，改一处必须同步另一处。
// 直译源：iOS PlanetImporter.swift 的纯字节布局函数（worldIdOf/inspect）+
// PlanetPayload.swift（ZTP 容器 key 约定），字节布局权威 Core/node/World.hpp
// serialize（planet 非 forSign 分支）+ Identity.hpp serialize(false)。
//
// u64 精度策略镜像：worldId 以 16 位小写 hex 字符串承载（逐字节读，不经过
// number 合成，>2^53 天然精确）；timestamp ≪ 2^53 按 number 解。

import { PayloadContainer } from '../../../qrtransfer/tests/mirror/payloadcontainer.mjs';

export const PLANET_TYPE_BYTE = 0x01;

export const KEY_PLANET = 1;
export const KEY_NAME = 2;
export const KEY_ICON = 3;
export const KEY_ICON_COLOR = 4;

const HEX_DIGITS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

// >>> MIRROR（与 PlanetImporter.ets MIRROR 切片逐行对应）

export function beBytesHex(data, offset, count) {
  let s = '';
  for (let i = 0; i < count; i++) {
    const b = data[offset + i];
    s += HEX_DIGITS[Math.floor(b / 16)] + HEX_DIGITS[b % 16];
  }
  return s;
}

export function hex16FromNumber(v) {
  let n = v < 0 || !Number.isFinite(v) ? 0 : Math.floor(v);
  let s = '';
  for (let i = 0; i < 16; i++) {
    s = HEX_DIGITS[n % 16] + s;
    n = Math.floor(n / 16);
  }
  return s;
}

export function worldIdOf(data) {
  if (data.length < 9 || data[0] !== PLANET_TYPE_BYTE) {
    return null;
  }
  return beBytesHex(data, 1, 8);
}

export function rootAddressOf(data) {
  if (data.length < 183 || data[0] !== PLANET_TYPE_BYTE || data[177] < 1) {
    return null;
  }
  return beBytesHex(data, 178, 5);
}

export function beBytesNumber(data, offset, count) {
  let v = 0;
  for (let i = 0; i < count; i++) {
    v = v * 256 + data[offset + i];
  }
  return v;
}

export function inspectBytes(data) {
  if (data.length < 17 || data[0] !== PLANET_TYPE_BYTE) {
    return null;
  }
  return {
    worldIdHex: beBytesHex(data, 1, 8),
    timestamp: beBytesNumber(data, 9, 8),
    fileSize: data.length,
  };
}

export function parsePlanetPayload(data) {
  const fields = PayloadContainer.parse(data);
  if (fields === null) {
    return null;
  }
  const planet = fields.get(KEY_PLANET);
  if (planet === undefined) {
    return null;
  }
  return {
    planet: planet,
    name: utf8OrNull(fields.get(KEY_NAME)),
    icon: utf8OrNull(fields.get(KEY_ICON)),
    iconColor: utf8OrNull(fields.get(KEY_ICON_COLOR)),
  };
}

function utf8OrNull(bytes) {
  return bytes === undefined ? null : Buffer.from(bytes).toString('utf8');
}

// <<< MIRROR
