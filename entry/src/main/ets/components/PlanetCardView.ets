// PlanetCardView.ets — 首页行星身份卡（iOS PlanetCardView.swift 直译）
//
// 72 磁贴（tint 实底圆角 20 + 白色动物图，PlanetIconView）+ 右上角骑缝状态
// 角标（使用中/连接中/上次使用，36 项 #34）+ 右下角灰色齿轮（暗示整卡可点
// 进设置）+ 名称 20 semibold + ID 行（等宽 secondary，CopyableValue 点击复制，
// moon>0 时以间隔号「·」跟随「卫星 x N」）。无 chevron，按压缩放 ≈0.97 为
// 唯一可点暗示（spring response 0.3 / damping 0.8）。
// 角标三态判定锚定活跃行星而非选中页（滑页不扰动角标），由父级（HomeView）
// 求值传入 showBadge/badgeInUse/badgeConnecting——纯展示组件，点击经 onTap
// 回调交还编排（iOS Button action + Android onOpenPlanetSettings 同构）。
import { curves } from '@kit.ArkUI';
import { PlanetProfile } from '../store/Models';
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { PlanetIcon, PlanetIconView } from './PlanetIcon';
import { CopyableValue } from './CopyableValue';
import { themeSignal } from '../store/ThemeManager';

/** 名称字号（iOS .system(size: 20, weight: .semibold)）= 身份区档 */
const FS_NAME: number = 20;
/** ID 行字号（iOS .system(size: 16, design: .monospaced)） */
const FS_ID: number = 16;
/** moonCount 行字号（iOS .footnote 13；token 表未设档，就近直取） */
const FS_FOOTNOTE: number = 13;
/** 磁贴边长与角标/齿轮字号（iOS 72 / 10 / 14 直取） */
const ICON_TILE: number = 72;
const FS_BADGE: number = 10;
const FS_GEAR: number = 14;
/** 骑缝角标越界量：顶 -6（iOS offset y）、右 +10（iOS offset x） */
const BADGE_OVERHANG_TOP: number = 6;
const BADGE_OVERHANG_RIGHT: number = 10;
/** 按压缩放档（iOS PressScaleButtonStyle 0.97） */
const PRESS_SCALE: number = 0.97;
/** 系统灰（iOS Color(uiColor: .systemGray) 浅色档 #8E8E93；深色提亮） */
const GEAR_GRAY_LIGHT: number = 0xFF8E8E93;
const GEAR_GRAY_DARK: number = 0xFFAEAEB2;

@ComponentV2
export struct PlanetCardView {
  /** 行星档案（官方行星展示名走本地化） */
  @Param planet: PlanetProfile = PlanetProfile.OFFICIAL;
  /** 节点 ID（身份文件派生 + 快照回填；无数据显示 '-' 占位，不可复制） */
  @Param nodeId: string = '-';
  /** 卫星数（moon>0 时 ID 行追加「卫星 x N」） */
  @Param moonCount: number = 0;
  /** 角标显隐门槛：活跃行星且曾设置过活跃（iOS isActive && hasActivatedPlanet） */
  @Param showBadge: boolean = false;
  /** 角标态：VPN 在跑 = 使用中；未跑但有启用网络 = 连接中；否则上次使用 */
  @Param badgeInUse: boolean = false;
  @Param badgeConnecting: boolean = false;
  /** 主题派生行星色盘（0xAARRGGBB 8 元素，ThemeManager.planetTintsHex 出口；
   *  空盘 = 未种子化，PlanetIcon.tintHex 兜底灰磁贴，首帧后 applyTheme 回填） */
  @Param tints: number[] = [];
  /** 整卡点击（父级编排：selectPlanet + 进行星设置） */
  @Param onTap: () => void = () => {};
  /** 对勾成功色（CopyableValue 反馈；主题派生值由父级传入） */
  @Param successColor: number = 0xFF009830;

  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 按压态（缩放 ≈0.97 为唯一可点暗示） */
  @Local pressed: boolean = false;

  /** 行星展示名：官方行星走本地化名（iOS PlanetProfile.displayName 直译） */
  private displayName(): string {
    return this.planet.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name')
      : this.planet.name;
  }

  /**
   * L10n 查表 + l10nSignal.rev 触踪（HomeView loc() 恒假分支同款范式）。
   */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.format(key, args);
  }

  build() {
    Column({ space: 8 }) {
      this.iconWithBadge()
      Text(this.displayName())
        .fontSize(FS_NAME)
        .fontWeight(600) // iOS .semibold
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .maxLines(1)
      this.idLine()
    }
    .alignItems(HorizontalAlign.Center)
    .width('100%') // iOS .frame(maxWidth: .infinity) 直译
    // 按压缩放（spring response 0.3 / damping 0.8）；点击导航经 onTap 交还父级
    .scale({
      x: this.pressed ? PRESS_SCALE : 1,
      y: this.pressed ? PRESS_SCALE : 1,
    } as ScaleOptions)
    .animation({ curve: curves.springMotion(0.3, 0.8) })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onTap())
  }

  /** 磁贴 + 骑缝角标 + 右下角齿轮（iOS iconWithBadge 直译）。容器 82×78：
   *  磁贴 72 置 (0,6)，右上角标骑缝越出磁贴顶 6（y:6-6=0）右 10（右缘钉 82），
   *  齿轮贴磁贴右下角外扩 1。 */
  @Builder
  iconWithBadge() {
    Stack() {
      Column() {
        PlanetIconView(PlanetIcon.animalKey(this.planet),
          PlanetIcon.tintHex(this.planet, this.tints), ICON_TILE)
      }
      .position({ x: 0, y: BADGE_OVERHANG_TOP })
      if (this.showBadge) {
        this.statusBadge()
      }
      // 右下角灰色齿轮：贴角放置（iOS overlay bottomTrailing + offset(1,1)），
      // 圆角外扩会把它完全挤出图标外，向内收的微调直译；iOS .medium 字重（M-2）
      Column() {
        SymbolGlyph($r('sys.symbol.gearshape_fill'))
          .fontSize(FS_GEAR)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.cm.dark ? GEAR_GRAY_DARK : GEAR_GRAY_LIGHT])
      }
      .position({ x: ICON_TILE - FS_GEAR + 1, y: BADGE_OVERHANG_TOP + ICON_TILE - FS_GEAR + 1 })
    }
    .width(ICON_TILE + BADGE_OVERHANG_RIGHT)
    .height(ICON_TILE + BADGE_OVERHANG_TOP)
    .alignContent(Alignment.TopStart)
  }

  /** 角标：三态（使用中 tint 实底白字 / 连接中橙底白字 / 上次使用灰底
   *  secondary 字 + 发丝描边），iOS statusBadge 直译。 */
  @Builder
  statusBadge() {
    Text(this.badgeInUse ? this.loc('planetcard.inUse')
      : this.badgeConnecting ? this.loc('planetcard.connecting')
        : this.loc('planetcard.lastUsed'))
      .fontSize(FS_BADGE)
      .fontWeight(600)
      .fontColor(this.badgeInUse || this.badgeConnecting ? 0xFFFFFFFF
        : DesignTokens.textSecondary(this.cm.dark))
      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      .backgroundColor(this.badgeInUse ? themeSignal.accent
        : this.badgeConnecting ? DesignTokens.warn(this.cm.dark)
          : DesignTokens.cardBg(this.cm.dark))
      .borderRadius(100) // Capsule = 完全圆角
      .border({ width: DesignTokens.HAIRLINE_WIDTH, color: DesignTokens.hairline(this.cm.dark) })
      // 骑缝：iOS topTrailing 对齐 + offset(x:10, y:-6) 直译——角标右缘钉容器
      // 右缘（= 磁贴右缘 + 10）、顶缘钉容器顶（= 磁贴顶 - 6）
      .position({ x: ICON_TILE + BADGE_OVERHANG_RIGHT, y: 0 })
      .markAnchor({ x: '100%', y: 0 })
  }

  /** ID 等宽行：CopyableValue（点击复制，无常驻图标）+ 卫星计数尾缀 */
  @Builder
  idLine() {
    Row({ space: 4 }) {
      CopyableValue({
        text: this.nodeId,
        showsIcon: false,
        fontSize: FS_ID,
        mono: true,
        color: DesignTokens.textSecondary(this.cm.dark),
        successColor: this.successColor,
      })
      if (this.moonCount > 0) {
        Text('·')
          .fontSize(FS_FOOTNOTE) // iOS .footnote（M-1）
          .fontColor(DesignTokens.textTertiary(this.cm.dark))
        Text(this.locFmt('planetcard.moonCount %lld', [this.moonCount]))
          .fontSize(FS_FOOTNOTE) // iOS .footnote（M-1）
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}
