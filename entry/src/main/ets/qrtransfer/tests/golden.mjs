// 金标向量与测试公共工具（node --test 数据模块，非用例文件）。
// 金标来源：
// - 帧串/压缩容器 hex：iOS 仓库 QRTransfer 模块经 swiftc 在 macOS 编译运行生成
//   （Android 仓库 GoldenVectorTest.kt 原样抄录，锁三端互通）。
// - iOS Tests/QRTransferCodecTests.swift + QRTransferFrameTests.swift 全部用例直译。
// harnessFits：测试侧独立的 QRRender.fits 仿真（iOS 测试里 QRRender 与 ChunkPlanner
// 也是两个模块）——按 ISO 18004 码字表现算 byte 模式(M)容量，与库内缺省探测
// 互为独立实现，可交叉捕捉探测失真。

export function sampleData(size) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 31 + 7) % 256);
}

export function roundTripData(size) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 7 + 13) % 256);
}

// xorshift 伪随机字节，近不可压缩。sampleData 以 256 字节为周期，
// deflate 可压到几百字节，无法触发 tooLarge。
export function noisyData(size) {
  let state = 0x9E3779B97F4A7C15n;
  const out = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    state ^= (state << 13n) & 0xFFFFFFFFFFFFFFFFn;
    state ^= state >> 7n;
    state ^= (state << 17n) & 0xFFFFFFFFFFFFFFFFn;
    out[i] = Number(state & 0xFFn);
  }
  return out;
}

const encoder = new TextEncoder();

export function utf8(text) {
  return encoder.encode(text);
}

export function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function bytesToHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** iOS QRTransfer.encode(sampleData(300), maxModules: 117) 的原始帧输出 */
export const IOS_GOLDEN_FRAMES = [
  'ZTQR1|01|01|226c6629|00419|FP50006PC.PEJEDBZEZKO6E7-EJSCBA4E:-2*T1%2KFPU5QFR$BK-TN%I$2KPKL1Q4FW5$CEG8KSZ9C1RYY3S9O8LJP.22*RS5WW8M+3F9CT:ZSN7BXZJJD3$-T4CVV2PTOL*6P$PDTZ8LPGV05+38-:I$VRNUMLPV16L+PPUEH+$U*2SOL4KV2OB6RZRV164-83Y0L T+5O 7R%$P33CD%UPVMUOCL3W%.NL/F*CBWXIQXRX1TGBI+68LDS1O6RINV 79YRG%38*P8FTU1CQ6FH0U3LIBMSBQA1YB5R4%HSCCR*8TGL5KY1Y%MMX4K.3XI5$BPX6QF-F:7LEFF NTQ:P.$7IKTA3T*YL12V3Q81Z5.*C-IKTS1A0FMZ6+6FF*VC-D5IB2IF2-OE-V72O21S/.907CSNO00'
];

/** iOS Deflate.compress(sampleData(300)) 的容器 hex（4 字节小端长度 + raw deflate） */
export const IOS_GOLDEN_CONTAINER_HEX =
  '2c0100006357734d695e74f0c17f39db98ea593b6f7c17330d299eb4f1c27b3e5d9fecae95279eb3a9ba24372d3c70ff9fac4d74d5cc1dd7bf899a04174ddc70fe1daf8e7756e78ae3cf58559c931a17ecbff757c63aaa72c6f66b5f458c830a27ac3ff79647db2bb363f9b1a72cca4e890df3f7ddfd236d1559317ddbd52fc2468105fdebcebee1d6f2cc685f76f409b3926342fdbcbd777e4b5946944fdb7ae5b39061407edfda33afb9343dd2db961e79cca4e8105f3777cfed5f9216e16553b75cfe2468e09fd7bbe6f42b4e0df7b4d625871f312ad8c7d5ced97deba7847958e994cd973e0ae8fbe5f6ac3ef59243dd2db565f1a1870cf276b135b377ddfc216e165a3279d3c50ffc7abe39ddab4ebe6027c1ff00';

// ---- harnessFits：独立容量模型（ISO 18004 码字表 → byte 模式 M 容量） ----

// 每版本 ECC M 的纠错码字/块数（ISO 18004 表，nayuki qrcodegen 同源）
const ECC_M = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
  26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
const BLOCKS_M = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
  17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];

function rawCodewords(ver) {
  const size = ver * 4 + 17;
  let r = size * size - 64 * 3 - 31 - (size - 16) * 2;
  if (ver >= 2) {
    const numAlign = Math.floor(ver / 7) + 2;
    r -= (numAlign - 1) * (numAlign - 1) * 25;
    r -= (numAlign - 2) * 20 * 2;
    if (ver >= 7) r -= 36;
  }
  return Math.floor(r / 8);
}

function byteCapacityM(ver) {
  const dataCw = rawCodewords(ver) - ECC_M[ver - 1] * BLOCKS_M[ver - 1];
  const countBits = ver < 10 ? 8 : 16;
  return Math.floor((dataCw * 8 - 4 - countBits) / 8);
}

// text 能否生成模块数 ≤ maxModules 的二维码（byte 模式最坏情形上界）。
export function harnessFits(text, maxModules) {
  const maxVersion = Math.floor((maxModules - 17) / 4);
  if (maxVersion < 1) return false;
  const v = Math.min(maxVersion, 40);
  return encoder.encode(text).length <= byteCapacityM(v);
}
