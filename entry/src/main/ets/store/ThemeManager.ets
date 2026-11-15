// ThemeManager.ets — 全局主题状态（iOS ThemeManager 状态面 + Task 6 色彩数学）
//
// 持久化源：AppPrefs（themeColorCustom 非 null 优先于 themeColor；默认
// 0xD44037）。派生计算经 NAPI ColorMath（Task 9 已接线：accent/success/
// planetTints 全部走真值，兜底值仅剩 success 开关关时的资产占位绿）。
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
  }

  async setDeriveStatusColor(on: boolean): Promise<void> {
    this.derive = on;
    await StoreRepo.store.writePrefs(p => {
      p.successDerived = on;
      return p;
    });
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
