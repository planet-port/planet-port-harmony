// 与 ../Base45.ets 逻辑同构镜像，改一处必须同步另一处
// （scripts/qr-mirror-check.sh 做关键契约行骨架比对；本文件为 node 可执行形态）。

// Base45（RFC 9285 字母表）。字母表恰好是 QR alphanumeric 全集且不含 "|"，
// 分片协议可以安全用 "|" 分隔。编解码两端都是本模块，自洽即可。
export class Base45 {
  static alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
  static index = null;

  static ensureIndex() {
    if (Base45.index === null) {
      const m = new Map();
      for (let i = 0; i < Base45.alphabet.length; i++) {
        m.set(Base45.alphabet.charAt(i), i);
      }
      Base45.index = m;
    }
    return Base45.index;
  }

  static encode(data) {
    let out = '';
    const n = data.length;
    let i = 0;
    while (i < n) {
      if (i + 1 >= n) {
        // 落单字节：两位
        const v = data[i];
        out += Base45.alphabet.charAt(v % 45);
        out += Base45.alphabet.charAt(Math.floor(v / 45));
      } else {
        const v = (data[i] << 8) | data[i + 1];
        out += Base45.alphabet.charAt(v % 45);
        out += Base45.alphabet.charAt(Math.floor(v / 45) % 45);
        out += Base45.alphabet.charAt(Math.floor(Math.floor(v / 45) / 45));
      }
      i += 2;
    }
    return out;
  }

  static decode(s) {
    if (s.length === 0) return null;
    const table = Base45.ensureIndex();
    const out = new Uint8Array(Math.floor(s.length * 2 / 3) + 1);
    let written = 0;
    let i = 0;
    while (i < s.length) {
      const remaining = s.length - i;
      if (remaining >= 3) {
        const c = table.get(s.charAt(i));
        const d = table.get(s.charAt(i + 1));
        const e = table.get(s.charAt(i + 2));
        if (c === undefined || d === undefined || e === undefined) return null;
        const v = c + d * 45 + e * 2025;
        if (v > 0xFFFF) return null;
        out[written] = v >>> 8;
        out[written + 1] = v & 0xFF;
        written += 2;
        i += 3;
      } else if (remaining === 2) {
        const c = table.get(s.charAt(i));
        const d = table.get(s.charAt(i + 1));
        if (c === undefined || d === undefined) return null;
        const v = c + d * 45;
        if (v > 0xFF) return null;
        out[written] = v;
        written += 1;
        i += 2;
      } else {
        return null; // 编码不可能产生落单 1 字符
      }
    }
    return out.slice(0, written);
  }
}
