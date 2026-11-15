// DesignTokens.ets — A5 视觉地基：栅格/字号/圆角/语义色/暗色分支（纯静态常量）
//
// 直译源：
// - 数值 = iOS DESIGN.md 的代码实况版（计划 Global Constraints 已裁决：标题
//   22pt bold、Logo 40/圆角 9、卡片主标题 15pt semibold；8pt 网格/边距 20/
//   卡片内边距 14/卡距 12/区块距 28；圆角 10/14/20；阴影全 App 仅 FAB 与弹窗卡）。
// - 色值 = Android ui/theme/PlanetTheme.kt 头部常量（iOS systemGroupedBackground
//   等语义色等价：页底/卡片底/发丝线/三档文字/警告/危险，浅深两分支全量照抄）。
//
// dark 判定契约（A5-T6 起迁移到 AppStorageV2 域，全项目禁用 @StorageProp——
// V1 装饰器与 @ComponentV2 互斥）：
//   文件尾 `colorModeSignal`（@ObservedV2 ColorModeSignal，AppStorageV2 键
//   'colorMode'）的 `@Trace dark: boolean`；EntryAbility onCreate/
//   onConfigurationUpdate 单向写入。DesignTokens.dark() 即读出口；在
//   @ComponentV2 build 内经任意调用深度读到该 @Trace 即被追踪，深浅色切换
//   自动重渲染（修复 V1 AppStorage 键无 V2 消费方的失联缺口，T5 报告
//   Concern-2 的范式裁决落地）。
//
// 主题色（accent）响应式出口见 store/ThemeManager.ets 文件尾 ThemeSignal：
//   组件内范式：`import { themeSignal } from '../store/ThemeManager'` 后
//   build 内直接读 themeSignal.accent（@Trace 追踪，换主色即时重组，
//   对齐 Android PlanetTheme 的 collectAsState）。
import { AppStorageV2 } from '@kit.ArkUI';

/** colorMode 深浅色信号（AppStorageV2 键 'colorMode'；写方 EntryAbility） */
@ObservedV2
export class ColorModeSignal {
  @Trace dark: boolean = false;
}

/** 进程单例：模块导入即 connect（AppStorageV2 纯内存域，不依赖 UI 上下文） */
export const colorModeSignal: ColorModeSignal =
  AppStorageV2.connect(ColorModeSignal, 'colorMode', () => new ColorModeSignal())!;

export class DesignTokens {
  // ---- 栅格（8pt 网格体系，vp） ----
  static readonly GRID8: number = 8;
  /** 页面水平边距（iOS 边距 20） */
  static readonly MARGIN_PAGE: number = 20;
  /** 卡片内边距（iOS 卡片内边距 14） */
  static readonly PAD_CARD: number = 14;
  /** 卡片纵向间距（iOS 卡距 12） */
  static readonly GAP_CARD: number = 12;
  /** 区块纵向间距（iOS 区块距 28） */
  static readonly SPACE_SECTION: number = 28;
  /** 发丝线宽（iOS 0.5pt separator；消费：borderWidth/height） */
  static readonly HAIRLINE_WIDTH: number = 0.5;

  // ---- 圆角（小 10 / 卡 14 / 大表单 20） ----
  static readonly RADIUS_SM: number = 10;
  static readonly RADIUS_CARD: number = 14;
  static readonly RADIUS_LG: number = 20;

  // ---- 字号（iOS TEXT STYLE 代码实况档位，pt→fp 直取） ----
  /** 大标题 22 bold（HomeView 标题等，代码实况） */
  static readonly FS_TITLE: number = 22;
  /** 身份区 20 semibold（行星身份卡） */
  static readonly FS_IDENTITY: number = 20;
  /** 卡片主标题 15 semibold（行星卡/网络卡行标题） */
  static readonly FS_ROW_TITLE: number = 15;
  /** caption 12（ID/IP 等宽专用档） */
  static readonly FS_CAPTION: number = 12;
  /** caption2 11（徽标 Capsule 内文字） */
  static readonly FS_CAPTION2: number = 11;
  /** 等宽字体（ID/IP/hex 用；ArkUI 系统等价族） */
  static readonly FONT_MONO: string = 'monospace';

  // ---- 阴影（全 App 仅两处，iOS DESIGN.md 代码实况） ----
  /** FAB：black 0.25 r10 y5 */
  static readonly SHADOW_FAB: ShadowOptions = {
    radius: 10,
    color: 0x40000000,
    offsetX: 0,
    offsetY: 5,
  };
  /** 弹窗卡：black 0.15 r12 y4 */
  static readonly SHADOW_SHEET: ShadowOptions = {
    radius: 12,
    color: 0x26000000,
    offsetX: 0,
    offsetY: 4,
  };

  // ---- dark 判定（唯一读出口；colorModeSignal 契约见文件头） ----
  static dark(): boolean {
    return colorModeSignal.dark;
  }

  // ---- 语义色（0xAARRGGBB number，ArkUI Color 直用） ----

  /** 页面底：浅 0xFFF2F2F7 / 深 0xFF1C1C1E（iOS systemGroupedBackground） */
  static pageBg(dark: boolean): number {
    return dark ? 0xFF1C1C1E : 0xFFF2F2F7;
  }

  /** 卡片底：浅 0xFFFFFFFF / 深 0xFF2C2C2E（iOS secondarySystemGroupedBackground） */
  static cardBg(dark: boolean): number {
    return dark ? 0xFF2C2C2E : 0xFFFFFFFF;
  }

  /** 发丝线：浅 3C3C43 @29% / 深 545458 @60%（iOS .separator 直译） */
  static hairline(dark: boolean): number {
    return dark ? 0x99545458 : 0x4A3C3C43;
  }

  /** 主文字：浅纯黑 / 深纯白（iOS .label） */
  static textPrimary(dark: boolean): number {
    return dark ? 0xFFFFFFFF : 0xFF000000;
  }

  /** 次要文字：浅 3C3C43 @60% / 深 EBEBF5 @60%（iOS .secondaryLabel） */
  static textSecondary(dark: boolean): number {
    return dark ? 0x99EBEBF5 : 0x993C3C43;
  }

  /** 三级文字：浅 3C3C43 @30% / 深 EBEBF5 @30%（iOS .tertiaryLabel，等宽 ID/IP 专用） */
  static textTertiary(dark: boolean): number {
    return dark ? 0x4DEBEBF5 : 0x4D3C3C43;
  }

  /** 警告橙（状态机 warning 档；iOS 系统橙深浅变体） */
  static warn(dark: boolean): number {
    return dark ? 0xFFFF9F0A : 0xFFFF9500;
  }

  /** 危险红（状态机 error 档；iOS 系统红深浅变体） */
  static danger(dark: boolean): number {
    return dark ? 0xFFFF453A : 0xFFFF3B30;
  }
}
