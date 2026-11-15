// 与 tests/mirror/qrframe.mjs 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对）。
// 直译源：iOS Modules/QRTransfer/Sources/QRFrame.swift:3-19
// 本目录七文件为纯逻辑层：禁 ArkTS/UI 特性（无装饰器、无 import ohos/@kit），
// 以保证 node 侧 .mjs 镜像可逐行同构。

/// 单帧结构。text 即二维码内容：ZTQR1|total|index|crc32|len|chunk
/// total/index 为两位十进制（1..99，index 从 1 起），crc32 为原始数据的 CRC、
/// len 为 Base45 全长（真实字符数，每帧重复携带），均用于接收端自描述恢复。
export class QRFrame {
  total: number = 0;
  index: number = 0;
  crc32: number = 0;
  length: number = 0;
  /// Base45 分片字符串（末帧含补 '0' 对齐）
  payload: string = '';

  constructor(total: number, index: number, crc32: number, length: number, payload: string) {
    this.total = total;
    this.index = index;
    this.crc32 = crc32;
    this.length = length;
    this.payload = payload;
  }
}

/// iOS 用 enum 承载三态错误；ArkTS/JS 镜像侧以「静态常量类」承载，
/// 消费语法与 enum 完全一致（QRTransferErrorCode.TooLarge）。
export class QRTransferErrorCode {
  static readonly TooLarge: number = 0;
  static readonly Incomplete: number = 1;
  static readonly Corrupt: number = 2;
}

export class QRTransferError extends Error {
  code: number = QRTransferErrorCode.Corrupt;

  constructor(code: number) {
    super(QRTransferError.label(code));
    this.code = code;
  }

  private static label(code: number): string {
    if (code === QRTransferErrorCode.TooLarge) return 'too large';
    if (code === QRTransferErrorCode.Incomplete) return 'incomplete';
    return 'corrupt';
  }
}
