// IconPickerSheet.ets — 行星图标设置弹层（iOS IconPickerSheet.swift 直译）
//
// 分段「图形 / 底色」：图形页 4 列动物网格（48×48 圆角 12 磁贴内 26 动物图 +
// 本地化名 + 选中标记）；底色页当前预览（72 圆角 20 内 36）+ 随机按钮 + 预设
// 色板 24 色（高 44 圆角 12，选中右上白对勾）。点选只改本地态，点「完成」经
// onSelect(animal, colorHex) 统一生效（iOS「完成」统一提交语义）。
// 无「恢复自动」——图标一经选择永久使用，自动算法仅作未设置时的兜底（iOS 同注）。
// 白色 PDF 动物需深色底才可见：磁贴用当前选中底色（iOS 同注）。
//
// 消费方：PlanetSettings（T11）——本组件与 PrefsView 同文件范式先建（plan 直译
// 源对照），A5 全量编译以 PrefsView 临时 probe import 验证（无引用方组件 ArkTS
// 编译器不产出目标，会假绿；T1/T10 先例同款收口）。
import { l10nSignal, L10n, IconCatalog } from './L10n';
import { PlanetIcon } from './PlanetIcon';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { themeSignal } from '../store/ThemeManager';

/** 表单字号（iOS .body 17 / .caption 12 / .caption2 11 / .subheadline 15） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_CAPTION2: number = 11;
const FS_SUBHEADLINE: number = 15;
/** 分段控件（iOS .pickerStyle(.segmented)：轨高 28 + 内衬 2 + 段圆角 7/轨 9） */
const SEG_TRACK_H: number = 28;
const SEG_PAD: number = 2;
const SEG_RADIUS: number = 7;
const SEG_TRACK_RADIUS: number = 9;
/** 图形磁贴（iOS 48×48 圆角 12 内 26）与底色预览（iOS 72 圆角 20 内 36） */
const TILE_SIZE: number = 48;
const TILE_RADIUS: number = 12;
const TILE_CONTENT: number = 26;
const PREVIEW_SIZE: number = 72;
const PREVIEW_RADIUS: number = 20;
const PREVIEW_CONTENT: number = 36;
/** 色板磁贴（iOS height 44 圆角 12） */
const SWATCH_HEIGHT: number = 44;
const SWATCH_RADIUS: number = 12;
/** 选中标记（iOS Image font .caption ≈12，frame height 14） */
const CHECK_SIZE: number = 12;
const CHECK_FRAME: number = 14;
/** 无自定义底色兜底（Color(hex:) nil → .gray 直译） */
const FALLBACK_TINT: number = 0xFF808080;

/** 分段项（对象字面量显式类型硬约束） */
interface IconTabSeg {
  key: string;
  labelKey: string;
}

@ComponentV2
export struct IconPickerSheet {
  /** 当前动物 key（宿主传有效解析结果，如 PlanetIcon.animalKey 直译） */
  @Param animal: string = '';
  /** 当前底色 hex（null = 未自定义） */
  @Param color: string | null = null;
  /** 完成回调（iOS onSelect(animal, color) 直译） */
  @Param onSelect: (animal: string, colorHex: string) => void =
    (_a: string, _c: string): void => { };
  /** 收起回调（iOS dismiss；宿主收起 sheet） */
  @Param onClose: () => void = (): void => { };

  /** 分段态（iOS Tab.graphic/color 直译，string 判别） */
  @Local tab: string = 'graphic';
  /** 草稿态（完成才回传；iOS @State selectedAnimal/selectedColor 直译） */
  @Local selectedAnimal: string = '';
  @Local selectedColor: string = '';
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;

  /** 两段分段定义（iOS Picker 两 Text(tag:) 直译，序即源序） */
  private readonly tabs: IconTabSeg[] = [
    { key: 'graphic', labelKey: 'icon.graphic' },
    { key: 'color', labelKey: 'icon.color' },
  ];

  aboutToAppear(): void {
    this.selectedAnimal = this.animal;
    this.selectedColor = this.color ?? PlanetIcon.randomColorHex();
  }

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** hex → 渲染域 0xAARRGGBB（非法回落 .gray，iOS Color(hex:) ?? .gray 直译） */
  private tileTint(hex: string): number {
    return PlanetIcon.colorFromHex(hex) ?? FALLBACK_TINT;
  }

  /** 主题 accent 的低透明度底（iOS Color.accentColor.opacity(0.1) 直译）：
   *  themeSignal.accent 是 '#AARRGGBB'，剥 ARGB 后加法重组保正数形态 */
  private accentAlphaBg(alphaHex: number): number {
    return alphaHex + parseInt(themeSignal.accent.slice(2), 16);
  }

  /** 动物白图 Image（资源缺失时空串不渲染，PlanetIconView 同语义） */
  @Builder
  animalImg(key: string, size: number) {
    if (PlanetIcon.src(key, getContext()) !== '') {
      Image(PlanetIcon.src(key, getContext()))
        .width(size)
        .height(size)
        .objectFit(ImageFit.Contain)
    }
  }

  /** 导航行（iOS toolbar cancellationAction/confirmationAction 直译） */
  @Builder
  navBar() {
    Row() {
      Text(this.loc('common.cancel'))
        .fontSize(FS_BODY)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ left: 12, top: 12, bottom: 12, right: 4 })
      Text(this.loc('icon.title'))
        .fontSize(FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.loc('common.done'))
        .fontSize(FS_BODY)
        .fontWeight(600)
        .fontColor(themeSignal.accent)
        .onClick((): void => {
          this.onSelect(this.selectedAnimal, this.selectedColor);
          this.onClose();
        })
        .padding({ right: 12, top: 12, bottom: 12, left: 4 })
    }
    .width('100%')
    .height(48)
  }

  /** 分段轨（iOS .pickerStyle(.segmented) 直译：JoinNetworkSheet DnsConfigSection 同款） */
  @Builder
  segTrack() {
    Row() {
      ForEach(this.tabs, (seg: IconTabSeg) => {
        Text(this.loc(seg.labelKey))
          .fontSize(FS_CAPTION)
          .fontWeight(this.tab === seg.key ? 600 : 400)
          .fontColor(this.tab === seg.key
            ? DesignTokens.textPrimary(this.cm.dark)
            : DesignTokens.textSecondary(this.cm.dark))
          .textAlign(TextAlign.Center)
          .height('100%')
          .layoutWeight(1)
          .borderRadius(SEG_RADIUS)
          .backgroundColor(this.tab === seg.key
            ? DesignTokens.cardBg(this.cm.dark)
            : Color.Transparent)
          .onClick((): void => {
            this.tab = seg.key;
          })
      }, (seg: IconTabSeg) => seg.key)
    }
    .width('100%')
    .height(SEG_TRACK_H)
    .padding(SEG_PAD)
    .borderRadius(SEG_TRACK_RADIUS)
    .backgroundColor(this.cm.dark ? 0x1FEBEBF5 : 0x1F3C3C43)
  }

  /** 图形页磁贴（iOS animalGrid label 直译） */
  @Builder
  animalTile(key: string) {
    Column({ space: 6 }) {
      // 白色动物图需深色底：磁贴用当前选中底色（iOS 同注直译）
      Stack({ alignContent: Alignment.Center }) {
        this.animalImg(key, TILE_CONTENT)
      }
      .width(TILE_SIZE)
      .height(TILE_SIZE)
      .borderRadius(TILE_RADIUS)
      .backgroundColor(this.tileTint(this.selectedColor))
      Text(this.loc('animal.' + key))
        .fontSize(FS_CAPTION2)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .minFontScale(0.7) // iOS minimumScaleFactor(0.7) 直译
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
      // 选中标记：accent 对勾 / 透明占位（iOS Color.clear 直译）
      SymbolGlyph($r('sys.symbol.' + (key === this.selectedAnimal
        ? 'checkmark_circle_fill' : 'circle')))
        .fontSize(CHECK_SIZE)
        .fontColor([key === this.selectedAnimal
          ? themeSignal.accent : 0x00FFFFFF])
        .height(CHECK_FRAME)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .borderRadius(TILE_RADIUS)
    .backgroundColor(key === this.selectedAnimal
      ? this.accentAlphaBg(0x1A000000)
      : DesignTokens.cardBg(this.cm.dark))
    .onClick((): void => {
      this.selectedAnimal = key;
    })
    .accessibilityText(this.loc('animal.' + key))
  }

  /** 底色页（iOS colorGrid 直译） */
  @Builder
  colorPage() {
    Column({ space: 14 }) {
      // 当前预览：白动物图 + 预选底色
      Stack({ alignContent: Alignment.Center }) {
        this.animalImg(this.selectedAnimal, PREVIEW_CONTENT)
      }
      .width(PREVIEW_SIZE)
      .height(PREVIEW_SIZE)
      .borderRadius(PREVIEW_RADIUS)
      .backgroundColor(this.tileTint(this.selectedColor))

      // 随机按钮（iOS Label("icon.randomColor", systemImage: arrow.triangle.2.circlepath)
      // 直译；鸿蒙符号域取 arrow_2_circlepath 同族）
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(FS_SUBHEADLINE)
          .fontColor([themeSignal.accent])
        Text(this.loc('icon.randomColor'))
          .fontSize(FS_SUBHEADLINE)
          .fontWeight(FontWeight.Medium)
          .fontColor(themeSignal.accent)
      }
      .justifyContent(FlexAlign.Center)
      .height(32)
      .padding({ left: 14, right: 14 })
      .borderRadius(16)
      .border({ width: DesignTokens.HAIRLINE_WIDTH, color: DesignTokens.hairline(this.cm.dark) })
      .onClick((): void => {
        this.selectedColor = PlanetIcon.randomColorHex();
      })
      .accessibilityText(this.loc('icon.randomColor'))

      // 预设底色 24 色（IconCatalog.palette，iOS IconPickerSheet.palette 同值表）
      Grid() {
        ForEach(IconCatalog.palette, (hex: string) => {
          GridItem() {
            Stack({ alignContent: Alignment.TopEnd }) {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(SWATCH_RADIUS)
                .backgroundColor(this.tileTint(hex))
              if (hex === this.selectedColor) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(CHECK_SIZE)
                  .fontColor([0xFFFFFFFF])
                  .margin(4)
              }
            }
            .width('100%')
            .height(SWATCH_HEIGHT)
            .onClick((): void => {
              this.selectedColor = hex;
            })
            .accessibilityText(hex)
          }
        }, (hex: string) => hex)
      }
      .width('100%')
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      this.navBar()
      // 分段（iOS .padding(.horizontal, 16).padding(.top, 8) 直译）
      Column() {
        this.segTrack()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      if (this.tab === 'graphic') {
        // 图形页：Grid 自滚动（92 项，避免 Scroll×Grid 嵌套滚动）
        Grid() {
          ForEach(IconCatalog.keys, (key: string) => {
            GridItem() {
              this.animalTile(key)
            }
          }, (key: string) => key)
        }
        .width('100%')
        .layoutWeight(1)
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(12)
        .rowsGap(14) // iOS LazyVGrid spacing 14 直译
        .padding(16)
        .scrollBar(BarState.Off)
      } else {
        Scroll() {
          this.colorPage()
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
  }
}
