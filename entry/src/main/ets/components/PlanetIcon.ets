// PlanetIcon.ets — 行星动物图标体系（iOS PlanetIcon.swift 全文件直译）
//
// 动物 key 用户设置过则永久生效；否则按名称 djb2 哈希确定性选动物（名称不变
// 则图标不变，同名行星同图标）。底色自定义 hex 优先，否则按 id 哈希取主题
// tints 色盘（已存在行星颜色不变）。官方行星与私有行星同规则，无特判。
//
// ---- 动态资源落地方式（编译期字面量限制的绕行，实证于 SDK d.ts）----
// ArkTS `$r('app.media.xxx')` 只接受编译期字面量（restool 构建期静态登记），
// SDK 亦无 Android getIdentifier 式的名字→id 运行时查询。按名取图可用路径：
//   resourceManager.getMediaBase64ByNameSync(resName)（@ohos.resourceManager.d.ts
//   :2677，@since 10，同步返回图片 base64）→ 拼 'data:image/png;base64,' 前缀后
//   直接作为 Image 的 string 源——Image 组件官方支持 data URI 形态
//   （component/image.d.ts:423-425：'data:image/subtype;base64,Base64EncodedData'）。
// 92 张 PNG（T1 已入 media/；资源名只允许 [a-zA-Z0-9_]，连字符转下划线，与
// IconCatalog 注释同口径）按 key 懒取 + 模块级缓存（字节级资源缓存，与配置
// 数据「跨进程写新鲜度」语义无关，不违背 AppState 侧不加缓存裁决）。
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PlanetProfile } from '../store/Models';
import { IconCatalog } from './L10n';

/** 图标内容边长/磁贴边长（iOS 38 in 72 比例） */
const CONTENT_RATIO: number = 38 / 72;
/** 磁贴圆角（iOS RoundedRectangle(cornerRadius: 20, style: .continuous)） */
export const PLANET_ICON_RADIUS: number = 20;

/** 64 位环绕算术的 hi/lo 32 位分解容器（对象字面量须显式类型硬约束） */
interface UInt64 {
  hi: number;
  lo: number;
}

// >>> MIRROR-BEGIN（镜像切片起点：其后至 MIRROR-END 的逻辑行与 .mjs 全文对应）

/** djb2 输出模数（iOS % 1_000_003） */
const DJB2_MOD: number = 1000003;

/**
 * (h * 33 + b) mod 2^64：hi/lo 各自乘 33（< 2^37，双精度内精确）逐步进位。
 * iOS UInt64 &*&+ 直译——中间态不可取模：先 mod 2^64 再取模与直接取模在
 * 2^64 mod 1_000_003 ≠ 0 时不等价（会改变哈希落点），必须精确环绕。
 */
function wrapMul33Add(v: UInt64, b: number): UInt64 {
  let lo = v.lo * 33 + b;
  const carry = Math.floor(lo / 4294967296);
  lo -= carry * 4294967296;
  let hi = v.hi * 33 + carry;
  const carry2 = Math.floor(hi / 4294967296);
  hi -= carry2 * 4294967296; // mod 2^64 = 丢弃 carry2（溢出位）
  const out: UInt64 = { hi: hi, lo: lo };
  return out;
}

/**
 * djb2 哈希（iOS PlanetIcon.djb2 直译）：UTF-8 字节序列、seed 5381、64 位
 * 环绕 ×33 + 字节，结果 % 1_000_003。同一输入永远同一结果。
 * 最终取模同样分解：64 位合成值可超 2^53（双精度整数精确上界），直接
 * (lo + hi*2^32) % m 会精度损失——按 (hi mod m)·(2^32 mod m) + lo 再取模，
 * 中间态 < 2^41，双精度内精确（BigInt 参考实现对照见 tests/planeticon）。
 */
export function planetIconHash(text: string): number {
  const bytes = utf8Bytes(text);
  let v: UInt64 = { hi: 0, lo: 5381 };
  for (let i = 0; i < bytes.length; i++) {
    v = wrapMul33Add(v, bytes[i]);
  }
  return ((v.hi % DJB2_MOD) * (4294967296 % DJB2_MOD) + v.lo) % DJB2_MOD;
}

// UTF-8 字节来源平台适配：HarmonyOS 用 util.TextEncoder，node 镜像侧用
// Buffer.from——函数体行两侧各自实现，标记 MIRROR-SKIP 跳过骨架比对。
function utf8Bytes(text: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(text); // MIRROR-SKIP
}
// <<< MIRROR-END

export class PlanetIcon {
  /** 按名取过的 data URI 缓存（key = 媒体资源名） */
  private static uriCache: Map<string, string> = new Map();

  /**
   * 有效动物 key：catalog 内的自定义值永久生效；null/旧值无效（历史 SF Symbol
   * 名等）按名称哈希回退。
   */
  static animalKey(planet: PlanetProfile): string {
    if (planet.icon !== null && IconCatalog.keys.indexOf(planet.icon) >= 0) {
      return planet.icon;
    }
    return IconCatalog.keys[planetIconHash(planet.name) % IconCatalog.keys.length];
  }

  /** 媒体资源名：连字符转下划线（restool 资源名域限制） */
  static resourceKey(key: string): string {
    return 'animal_' + key.replace(/-/g, '_');
  }

  /**
   * 图标 Image 源：按名同步取 media 资源 base64 → data URI（懒取 + 缓存）。
   * 上下文未就绪（ctx 拿不到 / resourceManager 瞬时异常）返回空串且不缓存
   * ——后续帧重取，瞬时缺口不固化为永久缺失（M-3）；仅资源域确定性缺失
   * （9001003 名字非法 / 9001004 按名无匹配，SDK @ohos.resourceManager.d.ts
   * getMediaBase64ByNameSync @throws）才缓存 '' 不再重复 IO。部分系统形态
   * base64 已带 data: 前缀，统一按需补前缀。
   */
  static src(key: string, ctx: common.Context | undefined): string {
    const name = PlanetIcon.resourceKey(key);
    const cached = PlanetIcon.uriCache.get(name);
    if (cached !== undefined) {
      return cached; // 含已确认缺失的 ''（不再重复 IO）
    }
    if (ctx === undefined) {
      return ''; // 渲染上下文未就绪：本帧降级，不污染缓存、后续帧重取
    }
    try {
      let b64 = ctx.resourceManager.getMediaBase64ByNameSync(name);
      if (!b64.startsWith('data:')) {
        b64 = 'data:image/png;base64,' + b64;
      }
      PlanetIcon.uriCache.set(name, b64);
      return b64;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 9001003 || err.code === 9001004) {
        PlanetIcon.uriCache.set(name, ''); // 确定性缺失：缓存 ''（不重复 IO）
      }
      return ''; // 其余异常（上下文/资源管理器瞬时未就绪）：不缓存，后续帧重取
    }
  }

  /**
   * 底色（渲染域 0xAARRGGBB）：自定义 hex 优先（解析失败视为未设置），否则
   * 按 id 哈希回退 tints 色盘（iOS tint(for:) 直译；tints 由调用方从
   * ThemeManager.planetTintsHex 派生传入——主题色变更后色盘变化经父组件
   * 触踪重渲染。存储域 iconColor 是 "#RRGGBB" string，经 colorFromHex 转入）。
   */
  static tintHex(planet: PlanetProfile, tints: number[]): number {
    const custom = planet.iconColor === null ? null : PlanetIcon.colorFromHex(planet.iconColor);
    if (custom !== null) {
      return custom;
    }
    if (tints.length === 0) {
      return 0xFF808080; // 色盘未种子化兜底（首帧窗口，随 applyTheme 重组修正）
    }
    return tints[planetIconHash(planet.id) % tints.length];
  }

  /**
   * 算法回退底色（按 id 哈希取当前色盘，与 tintHex 同链路），供需要直接取
   * 「无自定义色」值的场合（iOS fallbackColorHex 直译）。
   */
  static fallbackColorHex(planet: PlanetProfile, tints: number[]): number {
    return PlanetIcon.tintHex(planet, tints);
  }

  /**
   * "#RRGGBB"（可带 # 前缀、大小写混排）→ 0xFFRRGGBB（ArkUI number 色直用）；
   * 非法输入返回 null（iOS Color(hex:) 可失败初始化直译）。
   */
  static colorFromHex(hex: string): number | null {
    const s = hex.startsWith('#') ? hex.slice(1) : hex;
    if (s.length !== 6) {
      return null;
    }
    let v = 0;
    for (let i = 0; i < s.length; i++) {
      const d = PlanetIcon.hexDigit(s.charAt(i));
      if (d < 0) {
        return null;
      }
      v = v * 16 + d;
    }
    return 0xFF000000 + v; // 加法保正数形态（| 运算在 JS 下走 32 位有符号会变负）
  }

  /** 随机底色 hex：随机色相 + 中低亮度域（饱和度 0.45–0.85、亮度 0.32–0.55），
   *  白色图形对比度有保证（iOS randomColorHex 直译）。 */
  static randomColorHex(): string {
    const hue = PlanetIcon.randomIn(0, 360);
    const sat = PlanetIcon.randomIn(0.45, 0.85);
    const light = PlanetIcon.randomIn(0.32, 0.55);
    return PlanetIcon.hslToHex(hue, sat, light);
  }

  /** HSL → "#rrggbb"（小写）。h∈[0,360) s,l∈[0,1]（iOS hex(hue:) 直译）。 */
  static hslToHex(hue: number, saturation: number, lightness: number): string {
    const c = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const hp = hue / 60;
    const x = c * (1 - Math.abs(hp % 2 - 1));
    let r1 = 0;
    let g1 = 0;
    let b1 = 0;
    if (hp < 1) {
      r1 = c; g1 = x;
    } else if (hp < 2) {
      r1 = x; g1 = c;
    } else if (hp < 3) {
      g1 = c; b1 = x;
    } else if (hp < 4) {
      g1 = x; b1 = c;
    } else if (hp < 5) {
      r1 = x; b1 = c;
    } else {
      r1 = c; b1 = x;
    }
    const m = lightness - c / 2;
    const r = PlanetIcon.channel(r1 + m);
    const g = PlanetIcon.channel(g1 + m);
    const b = PlanetIcon.channel(b1 + m);
    return '#' + PlanetIcon.hex2(r) + PlanetIcon.hex2(g) + PlanetIcon.hex2(b);
  }

  // ---- 私有工具 ----

  /** [min, max) 均匀随机（Math.random 半开区间；iOS 闭区间右端点差异在浮点
   *  精度下不可分辨，直接采用半开实现） */
  private static randomIn(min: number, max: number): number {
    return Math.random() * (max - min) + min;
  }

  /** 通道值钳制 [0,255] 取整（iOS channel(_:) 直译） */
  private static channel(v: number): number {
    const rounded = Math.round(v * 255);
    return Math.min(Math.max(rounded, 0), 255);
  }

  private static hexDigit(ch: string): number {
    const c = ch.charCodeAt(0);
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // A-F
    return -1;
  }

  private static hex2(v: number): string {
    const hi = Math.floor(v / 16);
    const lo = v % 16;
    return PlanetIcon.DIGITS[hi] + PlanetIcon.DIGITS[lo];
  }

  private static readonly DIGITS: string[] =
    ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
}

/**
 * 行星图标磁贴（iOS PlanetCardView iconWithBadge 的图形段直译）：tint 实底
 * 圆角 20 + 内容按 38/72 比例居中的白色动物图。size = 磁贴边长（iOS 72）。
 * tint 为渲染域 0xAARRGGBB（PlanetIcon.tintHex 出口）。资源缺失（src 返回
 * 空串）时整块降级为纯 tint 圆角磁贴，不渲染空 Image。
 */
@Builder
export function PlanetIconView(key: string, tint: number, size: number) {
  Column() {
    if (PlanetIcon.src(key, getContext()) !== '') {
      Image(PlanetIcon.src(key, getContext()))
        .width(size * CONTENT_RATIO)
        .height(size * CONTENT_RATIO)
        .objectFit(ImageFit.Contain) // iOS .resizable().scaledToFit() 直译
    }
  }
  .width(size)
  .height(size)
  .justifyContent(FlexAlign.Center)
  .alignItems(HorizontalAlign.Center)
  .backgroundColor(tint)
  .borderRadius(PLANET_ICON_RADIUS)
  .clip(true)
}
