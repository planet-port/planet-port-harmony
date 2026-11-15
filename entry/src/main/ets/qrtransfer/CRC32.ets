// 与 tests/mirror/crc32.mjs 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对）。
// 直译源：iOS Modules/QRTransfer/Sources/CRC32.swift:4-22

/// 标准 CRC-32（IEEE 802.3，反射多项式 0xEDB88320）。查表由代码生成，不硬编码 256 项。
export class CRC32 {
  private static table: number[] | null = null;

  private static ensureTable(): number[] {
    if (CRC32.table === null) {
      const built: number[] = new Array(256);
      for (let i = 0; i < 256; i++) {
        let c: number = i;
        for (let k = 0; k < 8; k++) {
          if ((c & 1) === 1) {
            c = (0xEDB88320 ^ (c >>> 1)) >>> 0;
          } else {
            c = c >>> 1;
          }
        }
        built[i] = c >>> 0;
      }
      CRC32.table = built;
    }
    return CRC32.table;
  }

  static checksum(data: Uint8Array): number {
    const table = CRC32.ensureTable();
    let crc: number = 0xFFFFFFFF;
    for (let i = 0; i < data.length; i++) {
      crc = (table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8)) >>> 0;
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}
