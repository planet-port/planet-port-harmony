// 与 tests/mirror/deflate.mjs 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对）。
// 直译源：iOS Modules/QRTransfer/Sources/Deflate.swift:6-44
// 压缩后端：iOS COMPRESSION_ZLIB = 无 zlib 头的 raw deflate；pako deflateRaw/inflateRaw
// 同为 raw deflate（已对 iOS 金标容器 hex 逐字节比对一致，见 tests/golden.mjs）。

import { deflateRaw, inflateRaw } from 'pako';

/// 压缩容器：4 字节小端原始长度 + raw deflate 流。
/// 自带长度使得解压侧可以直接分配目标缓冲，不依赖外部传尺寸。
export class Deflate {
  static compress(data: Uint8Array): Uint8Array | null {
    if (data.length === 0) return null;
    const body: Uint8Array = deflateRaw(data);
    const len = data.length;
    const out = new Uint8Array(4 + body.length);
    out[0] = len & 0xFF;
    out[1] = (len >>> 8) & 0xFF;
    out[2] = (len >>> 16) & 0xFF;
    out[3] = (len >>> 24) & 0xFF;
    out.set(body, 4);
    return out;
  }

  static decompress(container: Uint8Array): Uint8Array | null {
    if (container.length <= 4) return null;
    const len = container[0] + container[1] * 256 + container[2] * 65536 + container[3] * 16777216;
    if (len <= 0 || len >= 16 * 1024 * 1024) return null;
    let body: Uint8Array;
    try {
      body = inflateRaw(container.subarray(4));
    } catch (e) {
      return null;
    }
    if (body.length !== len) return null;
    return body;
  }
}
