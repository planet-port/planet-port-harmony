// QRRender.ets — ScanKit generateBarcode 渲染封装 + 模块数实测反推
//
// 直译源：iOS Modules/QRTransfer/Sources/QRRender.swift（CoreImage 出图 + fits
// 实测）与 QRShareSession 的渲染职责；鸿蒙侧后端换成 @kit.ScanKit。
//
// ============================ ECC 裁决落地（T4 控制器裁决 1） ============================
// 本地 SDK d.ts（@hms.core.scan.generateBarcode.d.ts）已核实：
//   - CreateOptions.level?: ErrorCorrectionLevel（LEVEL_L=0 / M=1 / Q=2 / H=3），
//     且文档明确「The default value is LEVEL_H」（30% 纠错）；
//   - 若依赖缺省，ChunkPlanner.fits 缺省的 ISO 18004 byte 模式 ECC M 容量表会
//     高估真实容量 → 帧过大 → 渲染失败（控制器预警的假绿路径）。
// SDK 暴露了纠错级别 → 按裁决分支 1：渲染一律显式传 LEVEL_M（纠错率 15%，
// 即 ISO 18004 ECC M），使 ChunkPlanner 缺省容量表与真实后端严格同档，无需
// 注入 H 容量表欠估覆盖。
// 「ScanKit 实际 ECC 真机待验证」：host/模拟器无 generateBarcode 服务，无法
// 伪造实测。moduleCount 的像素反推 + 与公式 17+4v 互验是真机首跑的验收点
// （见 moduleCount 注释）；反推模型不成立时回退 ECC M 理论推导，行为退化为
// 与 ChunkPlanner 缺省一致（方向安全：显式 LEVEL_M 下理论即最坏情形上界）。
// ========================================================================================
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { L10n } from '../components/L10n';
import { themeSignal } from '../store/ThemeManager';

// ---- 渲染参数（render 与 moduleCount 必须一致，反推模型依赖同一 margin） ----
/// quiet zone（px）。ScanKit margin 单位是 px（1..10，缺省 1px≈无 quiet zone）；
/// iOS CoreImage / Android zxing 默认 quiet zone ≈ 4 模块，取 8px 在最大版本
/// （v25，4096px）时恰为 ~4 模块宽，小版本下更宽——只增不减扫描安全性。
const MARGIN_PX: number = 8;
/// moduleCount 探测出图边长（px，[200,4096] 域内）：1000px 下相邻版本差 ≥4px，
/// 反推分辨率足够。
const PROBE_SIZE_PX: number = 1000;
const MIN_SIZE_PX: number = 200;
const MAX_SIZE_PX: number = 4096;

/// QR 版本 1..40 byte 模式 ECC M 数据容量（ISO 18004 码字表推导）。
/// 与 ChunkPlanner.ets 的私有表同源复制（运行时兜底用，不 export 不污染 T3
/// 镜像纪律）；改表必须与 ChunkPlanner.ets 两处同步。
const BYTE_CAPACITY_M: number[] = [
  14, 26, 42, 62, 84, 106, 122, 152, 180, 213,
  251, 287, 331, 362, 412, 450, 504, 560, 624, 666,
  711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370,
  1452, 1538, 1628, 1722, 1809, 1911, 1989, 2099, 2213, 2331
];

/// UTF-8 字节长度（与 ChunkPlanner.ets 同源纯逻辑复制）。
function utf8Length(text: string): number {
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

// ================= UI 直读 helpers（裁决 2：sheet 瞬态视图，非响应式） =================
// @ComponentV2 + 文案/颜色直函数调用，不引入 @StorageProp('l10n.rev'/'theme.rev')
// 之类的 rev 订阅。accent 走 themeSignal.accent（AppStorageV2 @ObservedV2 实例
// 的 @Trace 字段直读，ThemeManager.ets 文件头钦定的 V2 组件内范式）——build 内
// 直读自带精确依赖跟踪，主题色变更即时重组且无需 rev 订阅。

/// 主题 accent（#AARRGGBB string）→ ArkUI number。缺省 #FFD44037 =
/// ThemeManager.DEFAULT_MAIN_HEX（与 ThemeSignal.accent 缺省值互指，评审 M-4）。
export function qrAccent(): number {
  const hex = themeSignal.accent;
  if (hex.length < 8) {
    return 0xFFD44037;
  }
  const v = parseInt(hex.slice(1), 16);
  return Number.isNaN(v) ? 0xFFD44037 : v;
}

/// accent 降透明（alpha 0..255）：ShardGrid received 态 accent @35% 用 0x59。
export function qrAccentAlpha(alpha: number): number {
  return (qrAccent() & 0x00FFFFFF) | ((alpha & 0xFF) << 24);
}

/// iOS String(format:) 直译：L10n 键含 '%d' 按序替换（qrtransfer.generating %d/%d 等）。
export function qrFmt(key: string, args: number[]): string {
  let rest = L10n.get(key);
  let out = '';
  for (const a of args) {
    const at = rest.indexOf('%d');
    if (at < 0) {
      break;
    }
    out += rest.slice(0, at) + String(a);
    rest = rest.slice(at + 2);
  }
  return out + rest;
}

/** 帧字符串 → 二维码位图。ScanKit 无「仅探测」API，探测也走本方法（见 moduleCount）。
 *  content 走 ArrayBuffer 重载：文本重载 QR 建议仅 512 字符，而帧可达 997 字符；
 *  ArrayBuffer 重载容量建议为 LEVEL_M ≤ 2048 字节（d.ts 逐档给值），帧长恒在其内。 */
export class QRRender {
  /** 渲染 px 的合法域收敛（SDK 参数域 [200, 4096]）。 */
  static clampPx(sizePx: number): number {
    return Math.max(MIN_SIZE_PX, Math.min(MAX_SIZE_PX, Math.round(sizePx)));
  }

  /** 出图。显式 LEVEL_M（ECC 裁决依据见文件头）；margin 全链路同值（MARGIN_PX）。 */
  static async render(text: string, sizePx: number): Promise<image.PixelMap> {
    const px = QRRender.clampPx(sizePx);
    const enc = util.TextEncoder.create('utf-8');
    const bytes = enc.encodeInto(text);
    const buf = new ArrayBuffer(bytes.length);
    new Uint8Array(buf).set(bytes);
    const opts: generateBarcode.CreateOptions = {
      scanType: scanCore.ScanType.QR_CODE,
      width: px,
      height: px,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_M,
      margin: MARGIN_PX,
    };
    return generateBarcode.createBarcode(buf, opts);
  }

  /** 理论模块数：byte 模式 ECC M 容量表查版本 → 17+4v（与 Step 1 互验公式同源）。 */
  static theoryModules(text: string): number {
    const n = utf8Length(text);
    let v = 1;
    while (v < 40 && BYTE_CAPACITY_M[v - 1] < n) {
      v += 1;
    }
    return 17 + 4 * v;
  }

  /** 像素尺寸 → 模块数反推：出图边长 d 满足 d = s*modules + 2*margin（s 为整像素
   *  缩放），在 17+4v 域内求唯一解；多解时取与理论值最近者消歧。无解返回 0
   *  （ScanKit 出图不满足该模型时，如恒等请求尺寸）。 */
  static deriveModuleCount(measuredPx: number, theoryHint: number): number {
    let best: number = 0;
    let bestGap: number = -1;
    for (let v = 1; v <= 40; v++) {
      const modules = 17 + 4 * v;
      const s = Math.floor((measuredPx - 2 * MARGIN_PX) / modules);
      if (s < 1) {
        continue;
      }
      if (s * modules + 2 * MARGIN_PX === measuredPx) {
        const gap = Math.abs(modules - theoryHint);
        if (bestGap < 0 || gap < bestGap) {
          best = modules;
          bestGap = gap;
        }
      }
    }
    return best;
  }

  /** 缓存条数上限（M-1）：超限整表清空再写入。会话内帧数有限且帧文本唯一，
   *  跨会话旧帧无复用价值，整表清空比 LRU 追踪简单，最坏代价只多一轮探测。 */
  private static readonly COUNT_CACHE_LIMIT: number = 64;
  private static countCache: Map<string, number> = new Map();

  /** 模块数实测：以生成代替探测（真机验收点）——生成 1000px 探测图 → 量出图
   *  边长 → 像素反推模块数；与 theoryModules（17+4v 公式）互验：反推命中即证
   *  ScanKit 实际按请求出图且 ECC M 理论成立；反推不命中（模型外行为）回退
   *  理论推导。结果按 text 缓存（同一帧探测只出一次图，分片探测二分零开销；
   *  缓存上限见 COUNT_CACHE_LIMIT）。 */
  static async moduleCount(text: string): Promise<number> {
    const cached = QRRender.countCache.get(text);
    if (cached !== undefined) {
      return cached;
    }
    const theory = QRRender.theoryModules(text);
    let result = theory;
    let pm: image.PixelMap | null = null;
    try {
      pm = await QRRender.render(text, PROBE_SIZE_PX);
      const info = await pm.getImageInfo();
      const d = Math.max(info.size.width, info.size.height);
      const derived = QRRender.deriveModuleCount(d, theory);
      if (derived > 0) {
        result = derived;
      }
    } catch (e) {
      // 出图失败（无 ScanKit 服务的 host/模拟器）：回退理论推导，方向安全
    }
    if (pm !== null) {
      void pm.release().catch(() => {}); // 探测图只用于量边长，量完即释放（M-3）
    }
    if (QRRender.countCache.size >= QRRender.COUNT_CACHE_LIMIT) {
      QRRender.countCache.clear(); // 超限整表清空（M-1，策略见 COUNT_CACHE_LIMIT）
    }
    QRRender.countCache.set(text, result);
    return result;
  }
}
