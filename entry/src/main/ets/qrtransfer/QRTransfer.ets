// 与 tests/mirror/qrtransfer.mjs 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对）。
// 直译源：iOS Modules/QRTransfer/Sources/QRTransfer.swift:5-82

import { Base45 } from './Base45';
import { CRC32 } from './CRC32';
import { Deflate } from './Deflate';
import { ChunkPlanner } from './ChunkPlanner';
import { QRFrame, QRTransferError, QRTransferErrorCode } from './QRFrame';

/// Swift split(separator:maxSplits:omittingEmptySubsequences:false) 语义：
/// 最多切 maxSplits 刀，第 6 段吞掉全部剩余（payload 里即使再出现 '|' 也不丢）。
function splitLimit(text: string, sep: string, maxSplits: number): string[] {
  const parts: string[] = [];
  let rest = text;
  while (true) {
    if (parts.length === maxSplits) {
      parts.push(rest);
      break;
    }
    const at = rest.indexOf(sep);
    if (at < 0) {
      parts.push(rest);
      break;
    }
    parts.push(rest.slice(0, at));
    rest = rest.slice(at + sep.length);
  }
  return parts;
}

/// 严格十进制（Swift Int(String) 对垃圾串返回 nil；这里比 Swift 更严：不接受 +/- 号）
function parseDigits(s: string): number | null {
  if (s.length === 0) return null;
  let v = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 48 || c > 57) return null;
    v = v * 10 + (c - 48);
  }
  return v;
}

/// 严格 8 位 hex（Swift UInt32(_:radix:16)，大小写均可）
function parseHex8(s: string): number | null {
  if (s.length !== 8) return null;
  let v = 0;
  for (let i = 0; i < 8; i++) {
    const c = s.charCodeAt(i);
    let d: number;
    if (c >= 48 && c <= 57) {
      d = c - 48;
    } else if (c >= 97 && c <= 102) {
      d = c - 87;
    } else if (c >= 65 && c <= 70) {
      d = c - 55;
    } else {
      return null;
    }
    v = v * 16 + d;
  }
  return v;
}

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function pad5(n: number): string {
  return String(n).padStart(5, '0');
}

function hex8(n: number): string {
  return n.toString(16).padStart(8, '0');
}

/// 传输编解码入口。数据 → 压缩容器 → Base45 → 均匀分片（末帧补 '0' 对齐）→ 帧字符串数组。
export class QRTransfer {
  static readonly magic: string = 'ZTQR1';
  /// "ZTQR1|" + 2 + "|" + 2 + "|" + 8 + "|" + 5 + "|" = 27
  static readonly headerLen: number = QRTransfer.magic.length + 1 + 2 + 1 + 2 + 1 + 8 + 1 + 5 + 1;

  /// 屏幕可用边长（vp/pt）→ 二维码模块数上限。模块 ≥ 2.5、quiet zone 4 模块、
  /// 硬顶 v25（117 模块）、下限 v9（53 模块）防极小屏。
  static recommendedMaxModules(side: number): number {
    return Math.max(53, Math.min(117, Math.floor(side / 2.5) - 8));
  }

  /// 抛 QRTransferError（code 见 QRTransferErrorCode）；T4/T8/T11 按码分支提示。
  static encode(data: Uint8Array, maxModules: number = 117, maxFrames: number = 32): string[] {
    const container = Deflate.compress(data);
    if (container === null) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    const encoded = Base45.encode(container);
    const capacity = ChunkPlanner.capacity(encoded.length, QRTransfer.headerLen, maxModules);
    if (capacity === null || capacity < 1) throw new QRTransferError(QRTransferErrorCode.TooLarge);
    const frameCount = Math.floor((encoded.length + capacity - 1) / capacity);
    if (frameCount > maxFrames) throw new QRTransferError(QRTransferErrorCode.TooLarge);
    // 均匀分片：等宽 chunk；无法整除时补 '0' 对齐，
    // 全序列每帧字符数严格相等 → 二维码模块数一致
    const chunkSize = Math.floor((encoded.length + frameCount - 1) / frameCount);
    const crc = CRC32.checksum(data);
    const frames: string[] = [];
    let start = 0;
    for (let i = 1; i <= frameCount; i++) {
      const end = Math.min(start + chunkSize, encoded.length);
      let chunk = encoded.slice(start, end);
      if (chunk.length < chunkSize) {
        chunk += '0'.repeat(chunkSize - chunk.length);
      }
      frames.push(QRTransfer.magic + '|' + pad2(frameCount) + '|' + pad2(i) + '|'
        + hex8(crc) + '|' + pad5(encoded.length) + '|' + chunk);
      start = end;
    }
    return frames;
  }

  static parse(text: string): QRFrame | null {
    const parts = splitLimit(text, '|', 5);
    if (parts.length !== 6 || parts[0] !== QRTransfer.magic) return null;
    if (parts[1].length !== 2 || parts[2].length !== 2 || parts[4].length !== 5) return null;
    if (parts[3].length !== 8) return null;
    const total = parseDigits(parts[1]);
    const index = parseDigits(parts[2]);
    const length = parseDigits(parts[4]);
    const crc = parseHex8(parts[3]);
    if (total === null || index === null || length === null || crc === null) return null;
    if (total < 1 || index < 1 || index > total) return null;
    if (length < 1 || length > 99999) return null;
    return new QRFrame(total, index, crc, length, parts[5]);
  }

  /// 帧集合齐全且 CRC 通过才返回数据；任何失败抛 QRTransferError（iOS 语义直译）。
  static decodeStrict(frames: QRFrame[]): Uint8Array {
    if (frames.length === 0) throw new QRTransferError(QRTransferErrorCode.Incomplete);
    const first = frames[0];
    const total = first.total;
    if (frames.length !== total) throw new QRTransferError(QRTransferErrorCode.Incomplete);
    const indices = new Set<number>();
    for (const f of frames) {
      if (f.total !== total) throw new QRTransferError(QRTransferErrorCode.Incomplete);
      indices.add(f.index);
    }
    if (indices.size !== total) throw new QRTransferError(QRTransferErrorCode.Incomplete);
    // 校验和不一致说明帧混自不同文档，属数据损坏而非缺帧
    for (const f of frames) {
      if (f.crc32 !== first.crc32) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    }
    const sorted = frames.slice().sort((a, b) => a.index - b.index);
    let joined = '';
    for (const f of sorted) {
      joined += f.payload;
    }
    // 先按 len 剥掉末帧补位，再进 Base45/解压/CRC 三重校验
    if (joined.length < first.length) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    const trimmed = joined.slice(0, first.length);
    const container = Base45.decode(trimmed);
    if (container === null) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    const data = Deflate.decompress(container);
    if (data === null) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    if (CRC32.checksum(data) !== first.crc32) throw new QRTransferError(QRTransferErrorCode.Corrupt);
    return data;
  }

  /// 计划接口形态：失败返回 null（齐全 + CRC 一致才过）。需要区分
  /// incomplete/corrupt 时用 decodeStrict（金标向量测试走它）。
  static decode(frames: QRFrame[]): Uint8Array | null {
    try {
      return QRTransfer.decodeStrict(frames);
    } catch (e) {
      return null;
    }
  }
}
