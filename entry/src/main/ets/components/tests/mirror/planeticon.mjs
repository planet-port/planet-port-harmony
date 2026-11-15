// PlanetIcon.ets djb2 段的 node 镜像（T3 模式）：
// 与 ../PlanetIcon.ets 的 MIRROR-BEGIN..MIRROR-END 切片逐行同构（utf8Bytes
// 函数体为平台适配行，两侧各自实现并标记 MIRROR-SKIP 跳过骨架比对），
// 改一处必须同步另一处（../mirror-check.sh 校验）。
// 直译源：iOS PlanetIcon.djb2（UInt64 环绕 ×33 + 字节，seed 5381，% 1_000_003）。
// 本文件零 import：node --test 直跑；BigInt 参考实现对照见 ../planeticon.test.mjs。

// djb2 输出模数（iOS % 1_000_003）
const DJB2_MOD = 1000003;

// (h * 33 + b) mod 2^64：hi/lo 各自乘 33（< 2^37，双精度内精确）逐步进位。
// iOS UInt64 &*&+ 直译——中间态不可取模：先 mod 2^64 再取模与直接取模在
// 2^64 mod 1_000_003 ≠ 0 时不等价（会改变哈希落点），必须精确环绕。
function wrapMul33Add(v, b) {
  let lo = v.lo * 33 + b;
  const carry = Math.floor(lo / 4294967296);
  lo -= carry * 4294967296;
  let hi = v.hi * 33 + carry;
  const carry2 = Math.floor(hi / 4294967296);
  hi -= carry2 * 4294967296;
  const out = { hi: hi, lo: lo };
  return out;
}

// djb2 哈希（iOS PlanetIcon.djb2 直译）：UTF-8 字节序列、seed 5381、64 位
// 环绕 ×33 + 字节，结果 % 1_000_003。同一输入永远同一结果。
// 最终取模同样分解：64 位合成值可超 2^53（双精度整数精确上界），直接
// (lo + hi*2^32) % m 会精度损失——按 (hi mod m)·(2^32 mod m) + lo 再取模，
// 中间态 < 2^41，双精度内精确（BigInt 参考实现对照见 ../planeticon.test.mjs）。
export function planetIconHash(text) {
  const bytes = utf8Bytes(text);
  let v = { hi: 0, lo: 5381 };
  for (let i = 0; i < bytes.length; i++) {
    v = wrapMul33Add(v, bytes[i]);
  }
  return ((v.hi % DJB2_MOD) * (4294967296 % DJB2_MOD) + v.lo) % DJB2_MOD;
}

// UTF-8 字节来源平台适配：HarmonyOS 用 util.TextEncoder，node 镜像侧用
// Buffer.from——函数体行两侧各自实现，标记 MIRROR-SKIP 跳过骨架比对。
function utf8Bytes(text) {
  return Buffer.from(text, 'utf8'); // MIRROR-SKIP
}
