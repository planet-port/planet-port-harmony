// 与 tests/mirror/payloadcontainer.mjs 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对）。
// 直译源：iOS Modules/QRTransfer/Sources/PayloadContainer.swift:7-51

/// ZTP 条目（iOS 元组 (key: UInt8, value: Data) 的 ArkTS 承载形态）。
export class PayloadField {
  key: number = 0;
  value: Uint8Array = new Uint8Array(0);

  constructor(key: number, value: Uint8Array) {
    this.key = key;
    this.value = value;
  }
}

/// ZTP KV 容器（载荷层 wire format）。容器 = magic "ZTP" + 无序条目流，
/// 条目 = key(1B) + len(4B 小端) + value，数据尾即容器尾。
/// 纯字节层编解码，对 key 含义零假设——key 语义是应用层约定，
/// 未知 key 由解析方自行忽略，保证 wire format 永不随业务演进变化。
export class PayloadContainer {
  static readonly magic: string = 'ZTP';
  /// 0 保留为非法哨兵
  static readonly invalidKey: number = 0;

  /// 字段列表 → 容器。key 为 0 的字段直接丢弃；同 key 多条目时 decode
  /// 取后值，编码方应避免产生重复。空列表产出仅含 magic 的合法空容器。
  static encode(fields: PayloadField[]): Uint8Array {
    let total = PayloadContainer.magic.length;
    for (const f of fields) {
      if (f.key !== PayloadContainer.invalidKey) {
        total += 5 + f.value.length;
      }
    }
    const out = new Uint8Array(total);
    let p = 0;
    for (let i = 0; i < PayloadContainer.magic.length; i++) {
      out[p] = PayloadContainer.magic.charCodeAt(i);
      p += 1;
    }
    for (const f of fields) {
      if (f.key === PayloadContainer.invalidKey) continue;
      out[p] = f.key;
      p += 1;
      const len = f.value.length;
      out[p] = len & 0xFF;
      out[p + 1] = (len >>> 8) & 0xFF;
      out[p + 2] = (len >>> 16) & 0xFF;
      out[p + 3] = (len >>> 24) & 0xFF;
      p += 4;
      for (let i = 0; i < len; i++) {
        out[p] = f.value[i];
        p += 1;
      }
    }
    return out;
  }

  /// 容器 → 字典。magic 不符、key 为 0、len 越界（截断/损坏/符号位为 1）→ null；
  /// 重复 key 取后出现的值（Map 赋值天然覆盖）。
  static decode(data: Uint8Array): Map<number, Uint8Array> | null {
    if (data.length < PayloadContainer.magic.length) return null;
    for (let i = 0; i < PayloadContainer.magic.length; i++) {
      if (data[i] !== PayloadContainer.magic.charCodeAt(i)) return null;
    }
    const fields = new Map<number, Uint8Array>();
    let i = PayloadContainer.magic.length;
    while (i < data.length) {
      const key = data[i];
      if (key === PayloadContainer.invalidKey) return null;
      if (data.length - (i + 1) < 4) return null;
      const len = data[i + 1] + data[i + 2] * 256 + data[i + 3] * 65536 + data[i + 4] * 16777216;
      const valueStart = i + 5;
      // len 是四字节无符号和（float64），恒非负，len < 0 为不可达防御位（对齐
      // Android 用例；Kotlin Int 读法下符号位为 1 时为负，两端同为拒收）——
      // 真实越界拒收由 len > data.length 分支兜住（len 超过 2^31 的极端值亦然）
      if (len < 0 || len > data.length - valueStart) return null;
      fields.set(key, data.slice(valueStart, valueStart + len));
      i = valueStart + len;
    }
    return fields;
  }

  /// 计划接口别名（iOS/Android 原名 decode）。
  static parse(data: Uint8Array): Map<number, Uint8Array> | null {
    return PayloadContainer.decode(data);
  }
}
