// ThemeManager.ets — 全局主题状态（iOS ThemeManager 状态面 + Task 6 色彩数学）
//
// 持久化源：AppPrefs（themeColorCustom 非 null 优先于 themeColor；默认
// 0xD44037）。派生计算经 NAPI ColorMath（Task 9 已接线：accent/success/
// planetTints 全部走真值，兜底值仅剩 success 开关关时的资产占位绿）。
//
// ArkUI 响应式出口（文件尾 ThemeSignal，A5 T6 迁移到 AppStorageV2 域——
// @StorageProp 属 V1 装饰器与 @ComponentV2 互斥，全项目此后禁用）：
//   `themeSignal.accent`（string，#AARRGGBB，light 档）与 `themeSignal.rev`
//   （number，发布自增，供非响应式消费方重算）。UI 组件内消费范式：
//     import { themeSignal } from '../store/ThemeManager';
//     // build 内直接读 themeSignal.accent——@ObservedV2 实例的 @Trace 字段
//     // 在 @ComponentV2 build 中被访问即被追踪，换主色即时重组
//     Text('x').fontColor(themeSignal.accent)
//   （对齐 Android PlanetTheme 的 collectAsState）。
//   入口处（EntryAbility）调一次 ThemeReactive.ensureReactive() 异步种子；
//   dark 档 accent 与全局 colorMode 联动未做（原挂 T5，现仍是 T10 主题段接入点）。
import { AppStorageV2 } from '@kit.ArkUI';
import { StoreRepo } from './StoreRepo';
import { ColorMath } from '../common/CoreRuntime';

export class ThemeManager {
  // 单例经 sharedPromise 承载（原 instance 字段已被 in-flight 缓存取代）

  /** 预设主色板（iOS presets 逐值：默认红 + 7 个国画经典色） */
  static readonly PRESETS: number[] = [
    0xD44037, 0xFFB61E, 0x789262, 0x57C3C2,
    0x4C8DAE, 0x003472, 0x4A4266, 0x9D2933,
  ];

  /** AppPrefs 两主题字段均为 null 时的默认主色（iOS init 缺省分支直译） */
  // 改默认色需与 ThemeSignal.accent 缺省值（文件尾）同步（评审 M-4 互指）
  private static readonly DEFAULT_MAIN_HEX: number = 0xD44037;
  /** SuccessGreen 资产真值（iOS Assets light #009830；dark 态 #27B850 由 A5 资产接入） */
  private static readonly SUCCESS_FALLBACK_HEX: number = 0x009830;

  private main: number;
  private derive: boolean;

  private constructor(main: number, derive: boolean) {
    this.main = main;
    this.derive = derive;
  }

  // in-flight Promise 缓存（评审：async 单例在 readPrefs 挂起间隙可被二次
  // 调用重复构造——A5 启动期 EntryAbility 与首页并发 shared() 可触发）；
  // readPrefs 失败有内存默认兜底实际不 reject，catch 重置仅防御
  private static sharedPromise: Promise<ThemeManager> | null = null;

  static shared(): Promise<ThemeManager> {
    if (ThemeManager.sharedPromise === null) {
      ThemeManager.sharedPromise = (async () => {
        const prefs = await StoreRepo.store.readPrefs();
        const main = prefs.themeColorCustom ?? prefs.themeColor
          ?? ThemeManager.DEFAULT_MAIN_HEX;
        return new ThemeManager(main, prefs.successDerived);
      })();
      ThemeManager.sharedPromise
        .catch(() => { ThemeManager.sharedPromise = null; });
    }
    return ThemeManager.sharedPromise;
  }

  /** 重读 AppPrefs 同步内存态（偏好经其他入口变更后调用；首读与 shared 等价） */
  async refresh(): Promise<void> {
    const prefs = await StoreRepo.store.readPrefs();
    const main = prefs.themeColorCustom ?? prefs.themeColor
      ?? ThemeManager.DEFAULT_MAIN_HEX;
    this.main = main;
    this.derive = prefs.successDerived;
    ThemeReactive.publish(this);
  }

  get mainHex(): number { return this.main; }
  /** 自定义色优先（AppPrefs.themeColorCustom 语义） */
  get effectiveMainHex(): number { return this.main; }
  get deriveStatusColor(): boolean { return this.derive; }

  async setMainColor(hex: number, custom: boolean): Promise<void> {
    this.main = hex;
    await StoreRepo.store.writePrefs(p => {
      if (custom) {
        p.themeColorCustom = hex;
      } else {
        p.themeColor = hex;
        p.themeColorCustom = null;
      }
      return p;
    });
    ThemeReactive.publish(this);
  }

  async setDeriveStatusColor(on: boolean): Promise<void> {
    this.derive = on;
    await StoreRepo.store.writePrefs(p => {
      p.successDerived = on;
      return p;
    });
    // 评审 I-1：derive 开关改变 success 派生色——不发信号则 theme.rev 对
    // derive 变更失真，订阅方重算不触发。accent 值不变、仅 rev+1
    ThemeReactive.publish(this);
  }

  // ---- 派生色（NAPI ColorMath；Task 9 已接线——本类是 ColorMath 的唯一消费点） ----

  accentLightHex(): number {
    return ColorMath.accentLight(this.main);
  }

  accentDarkHex(): number {
    return ColorMath.accentDark(this.main);
  }

  /** 成功/在线状态色：默认固定资产绿；开关开时随主色 +120° 三角派生 */
  successLightHex(): number {
    return this.derive ? ColorMath.successLight(this.main)
      : ThemeManager.SUCCESS_FALLBACK_HEX;
  }

  successDarkHex(): number {
    return this.derive ? ColorMath.successDark(this.main)
      : ThemeManager.SUCCESS_FALLBACK_HEX;
  }

  /** 行星装饰盘（8 元素：±120° 三色 × 500/200 档 + 两深色） */
  planetTintsHex(): number[] {
    return ColorMath.planetTints(this.main);
  }
}

// ---- ArkUI 响应式出口（A5 T6 迁移到 AppStorageV2；既有类体未改动） ----
// accent/success 变更入口（refresh/setMainColor/setDeriveStatusColor）尾追
// publish → themeSignal 的 @Trace 字段变更 → @ComponentV2 消费方即时重组。

/** 主题信号（AppStorageV2 键 'theme'）：accent 变更全 UI 重组 + rev 自增 */
@ObservedV2
export class ThemeSignal {
  /** light 档主色（#AARRGGBB；dark 档随 colorMode 联动未做，见文件头） */
  @Trace accent: string = '#FFD44037';
  /** 发布自增（非响应式消费方订阅重算用） */
  @Trace rev: number = 0;
}

/**
 * 进程单例：模块导入即 connect（AppStorageV2 纯内存域，不依赖 UI 上下文）。
 * accent 缺省值 = ThemeManager.DEFAULT_MAIN_HEX 的 '#FFD44037' string 形态
 * （评审 M-4 互指：改默认色两处同步——ThemeSignal.accent 与 DEFAULT_MAIN_HEX）。
 */
export const themeSignal: ThemeSignal =
  AppStorageV2.connect(ThemeSignal, 'theme', () => new ThemeSignal())!;

export class ThemeReactive {
  /** ensureReactive 幂等闸（种子一次；后续变更走 publish） */
  private static seeded: boolean = false;

  /**
   * 入口种子（幂等）：经 shared() 异步读 prefs 补写当前真值（首帧先用
   * ThemeSignal 缺省值渲染，落盘主题加载完成即重组）。EntryAbility 调一次即可。
   */
  static ensureReactive(): void {
    if (ThemeReactive.seeded) {
      return;
    }
    ThemeReactive.seeded = true;
    ThemeManager.shared()
      .then((tm: ThemeManager) => ThemeReactive.publish(tm))
      .catch(() => {
        // shared 实际不 reject（内存默认兜底）；此处仅防御，保持缺省 accent
      });
  }

  /** 变更入口尾追：写 accent + rev 自增（refresh/setMainColor/setDerive） */
  static publish(tm: ThemeManager): void {
    themeSignal.accent = ThemeReactive.toArgb(tm.accentLightHex());
    themeSignal.rev += 1;
  }

  /** 0xRRGGBB（ColorMath 返回 24bit）→ '#AARRGGBB' string */
  private static toArgb(hex: number): string {
    return '#FF' + (hex & 0xFFFFFF).toString(16).toUpperCase().padStart(6, '0');
  }
}
