// 与 ../QRFrame.ets 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对；本文件为 node 可执行形态）。

// 单帧结构。text 即二维码内容：ZTQR1|total|index|crc32|len|chunk
// total/index 为两位十进制（1..99，index 从 1 起），crc32 为原始数据的 CRC、
// len 为 Base45 全长（真实字符数，每帧重复携带），均用于接收端自描述恢复。
export class QRFrame {
  total = 0;
  index = 0;
  crc32 = 0;
  length = 0;
  // Base45 分片字符串（末帧含补 '0' 对齐）
  payload = '';

  constructor(total, index, crc32, length, payload) {
    this.total = total;
    this.index = index;
    this.crc32 = crc32;
    this.length = length;
    this.payload = payload;
  }
}

// iOS 用 enum 承载三态错误；ArkTS/JS 镜像侧以「静态常量类」承载，
// 消费语法与 enum 完全一致（QRTransferErrorCode.TooLarge）。
export class QRTransferErrorCode {
  static TooLarge = 0;
  static Incomplete = 1;
  static Corrupt = 2;
}

export class QRTransferError extends Error {
  code = QRTransferErrorCode.Corrupt;

  constructor(code) {
    super(QRTransferError.label(code));
    this.code = code;
  }

  static label(code) {
    if (code === QRTransferErrorCode.TooLarge) return 'too large';
    if (code === QRTransferErrorCode.Incomplete) return 'incomplete';
    return 'corrupt';
  }
}
