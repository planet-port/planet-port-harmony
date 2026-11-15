// 与 ../ChunkPlanner.ets 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对；本文件为 node 可执行形态）。

// QR 版本 1..40 的 byte 模式数据容量（纠错级 M），由 ISO 18004 码字表推导：
// dataCW*8 - 4(模式指示) - (v<10 ? 8 : 16)(计数位) 后向下取整。
// 仅作 fits 缺省后端的容量上界（byte 模式是 QR 最省容量的最坏情形）。
const BYTE_CAPACITY_M = [
  14, 26, 42, 62, 84, 106, 122, 152, 180, 213,
  251, 287, 331, 362, 412, 450, 504, 560, 624, 666,
  711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370,
  1452, 1538, 1628, 1722, 1809, 1911, 1989, 2099, 2213, 2331
];

// UTF-8 字节长度（等价 TextEncoder，但纯逻辑可测，不引 ohos util）。
function utf8Length(text) {
  let n = 0;
  let i = 0;
  while (i < text.length) {
    const u = text.charCodeAt(i);
    if (u >= 0xD800 && u < 0xDC00 && i + 1 < text.length) {
      const lo = text.charCodeAt(i + 1);
      if (lo >= 0xDC00 && lo < 0xE000) {
        n += 4;
        i += 2;
        continue;
      }
    }
    if (u < 0x80) {
      n += 1;
    } else if (u < 0x800) {
      n += 2;
    } else {
      n += 3;
    }
    i += 1;
  }
  return n;
}

// 每帧容量探测：二分查找最大的"分片字符数"，
// 使 真实形态定长头+该长度探测串 生成的二维码模块数 ≤ maxModules。
// 探测串必须携带真实帧头（含 '|'，byte mode）：纯 "0" 会走 numeric mode
// （3.33 bit/字符），导致容量高估近一倍。
export class ChunkPlanner {
  // 与真实帧头等形等长（count == QRTransfer.headerLen == 27）
  // 非 private：QRTransferFrameTests 需断言两者长度一致（帧格式失配防护）
  static probePrefix = 'ZTQR1|99|99|ffffffff|00000|';

  // 容量探测后端（iOS 直译适配点：iOS 固定走 QRRender.fits/CoreImage 实测）。
  // 缺省 = QR spec byte 模式容量上界（纯逻辑、同步、node 金标向量可复现）；
  // T5 QRRender.ets 落地后以 generateBarcode 实测整体覆盖此属性，调用方零改动。
  static fits = (text, maxModules) => {
    const maxVersion = Math.floor((maxModules - 17) / 4);
    if (maxVersion < 1) return false;
    const v = maxVersion > 40 ? 40 : maxVersion;
    return utf8Length(text) <= BYTE_CAPACITY_M[v - 1];
  };

  static capacity(payloadCount, headerLen, maxModules) {
    let lo = 1;
    let hi = Math.max(payloadCount, 1);
    let best = null;
    while (lo <= hi) {
      const mid = Math.floor((lo + hi) / 2);
      // 尾部用小写 'z' 填充：裸数字会被编码器切 numeric segment 再次低估，
      // 非字母数字字符强制 byte mode（8 bit/字符）即最坏情况上界，
      // 真实分片的任何分段优化只会比探测更省模块
      const probe = ChunkPlanner.probePrefix + 'z'.repeat(mid);
      if (ChunkPlanner.fits(probe, maxModules)) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }
}
