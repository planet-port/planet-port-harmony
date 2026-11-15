// ConfirmBubble.ets — 锚定触发行上方的确认气泡（iOS ConfirmBubble.swift 111 行全直译）
//
// iOS 注释直译：系统呈现已三次漂移（confirmationDialog 锚点跑偏 → action sheet
// 底部大条 → iOS 27.2 强制 popover 居中压在锚定行上），不再依赖系统弹窗的定位
// 权：气泡底边由锚点 frame 直接计算，贴触发行顶边、尾尖指向行内，全版本行为
// 一致。点气泡外任意处关闭。
//
// 锚定协议（iOS GlobalAnchorReader 对应物）：锚点行经 onAreaChange 持续上报自身
// 全局 frame（Area.globalPosition.y = 组件左上角在当前窗口坐标系的位置，即
// geo.frame(in: .global).minY 等价物）；宿主层根节点同步上报自身全局 y
// （iOS geo.frame(in: .global).minY），锚点换算到宿主层局部坐标后作盒高。
// 布局裁决（iOS :28-41 直译）：顶部对齐——盒子（高度=容器顶到锚点行卡片可视
// 顶边）必须从 y=0 起排，气泡底对齐盒底后才贴锚点行顶边；居中会让气泡底边落
// 到 (屏高+锚点)/2 处。不用 alignmentGuide 换底边的写法（实测不能穿透修饰链）。
// 视觉参数逐字（brief 定值）：盒高 max(60, anchorTop) bottom 对齐；宽 260 /
// padding 16 / 圆角 20 / backgroundBlurStyle Regular / 阴影 0.18 r14 y5；
// 尾尖 18×9 下探 9 Path 自绘；确认红字 semibold + quaternary Capsule；
// 转场 opacity + scale 0.95 anchor bottom（宿主挂 .transition）+ 呼吸间距 10。
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';

/** Form 行卡片可视顶边相对行内容（Text）顶边的垂直内边距（iOS :19 直译）：
 *  锚点量到的是文字顶边，上提这个量后气泡底边才贴卡片可视顶边。 */
const ROW_CARD_INSET: number = 14;
/** 气泡底边与卡片顶边之间的呼吸间距（iOS :21） */
const BUBBLE_GAP: number = 10;
/** 盒高下限（iOS .frame(height: max(60, anchorTop))） */
const MIN_BOX_HEIGHT: number = 60;
/** 气泡宽（iOS .frame(width: 260)） */
const BUBBLE_WIDTH: number = 260;
/** 气泡内边距/圆角/条目间距（iOS .padding(16) / cornerRadius 20 / spacing 14/4） */
const BUBBLE_PADDING: number = 16;
const BUBBLE_RADIUS: number = 20;
const BUBBLE_SPACING: number = 14;
const TITLE_GROUP_SPACING: number = 4;
/** 阴影（iOS shadow black 0.18 r14 y5 → alpha 0.18*255≈0x2E） */
const SHADOW_COLOR: number = 0x2E000000;
/** 尾尖（iOS ArrowDown frame 18×9，offset y 9 下探） */
const TAIL_WIDTH: number = 18;
const TAIL_HEIGHT: number = 9;
const TAIL_DROP: number = 9;
/** 确认按钮纵向内边距（iOS .padding(.vertical, 9)） */
const CONFIRM_PAD_V: number = 9;

@ComponentV2
export struct ConfirmBubble {
  /** 锚点行全局 y（触发行 onAreaChange 持续上报，GlobalAnchorReader 对应物） */
  @Param anchorY: number = 0;
  /** 宿主层根节点全局 y（iOS geo.frame(in: .global).minY 对应物；满幅宿主恒 0） */
  @Param layerTopY: number = 0;
  @Param titleKey: string = '';
  /** '' = 无副文案（iOS messageKey optional 直译） */
  @Param messageKey: string = '';
  @Param confirmKey: string = '';
  @Param onConfirm: () => void = () => {};
  @Param onDismiss: () => void = () => {};

  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;

  /** 盒高：锚点换算到本层局部坐标再上提 inset+gap（iOS :26-27 直译） */
  private boxHeight(): number {
    const anchorTop = this.anchorY - this.layerTopY - ROW_CARD_INSET - BUBBLE_GAP;
    return Math.max(MIN_BOX_HEIGHT, anchorTop);
  }

  /** iOS .quaternary 分层填充近似（分层填充无 ArkUI 系统色，取 label 色低透明） */
  private quaternary(): number {
    return this.cm.dark ? 0x24EBEBF5 : 0x243C3C43;
  }

  /** 尾尖填充：iOS .fill(.regularMaterial)（材质几何裁切 ArkUI 不支持，取
   *  材质观感近似色；18×9 的微小面积下与毛玻璃视觉无感差——偏差已挂报告） */
  private tailFill(): number {
    return this.cm.dark ? 0xD92C2C2E : 0xD9F2F2F7;
  }

  /** iOS ArrowDown path 直译：底边中点 → 左上 → 右上 → 闭合 */
  private tailPoints(): number[][] {
    const pts: number[][] = [[TAIL_WIDTH / 2, TAIL_HEIGHT], [0, 0], [TAIL_WIDTH, 0]];
    return pts;
  }

  /** L10n 查表 + l10nSignal.rev 触踪（HomeView.loc 恒假分支惯用形） */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 全屏点击 catcher：气泡外任意点关闭（iOS Color.clear + onTapGesture 直译）
      Column()
        .width('100%')
        .height('100%')
        .onClick((): void => this.onDismiss())

      // 顶部对齐盒子：高度 = 容器顶到触发行卡片可视顶边，气泡底对齐盒底
      // （iOS ZStack(alignment: .top) + .frame(height: max(60, anchorTop),
      // alignment: .bottom) 直译）
      Column() {
        this.bubbleWithTail()
      }
      .width('100%')
      .height(this.boxHeight())
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
  }

  /** 气泡 + 尾尖（iOS bubble 直译；尾尖 overlay bottom + offset y 9 对应物：
   *  Stack bottom 对齐 + 下探位移，溢出不裁切） */
  @Builder
  bubbleWithTail() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: BUBBLE_SPACING }) {
        Column({ space: TITLE_GROUP_SPACING }) {
          Text(this.loc(this.titleKey))
            .fontSize(17) // iOS .headline
            .fontWeight(600)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
            .textAlign(TextAlign.Center)
            .width('100%')
          if (this.messageKey !== '') {
            Text(this.loc(this.messageKey))
              .fontSize(13) // iOS .footnote
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .textAlign(TextAlign.Center)
              .width('100%')
          }
        }
        .width('100%')

        // 确认：红字 semibold + quaternary Capsule（iOS :60-68 直译）
        Text(this.loc(this.confirmKey))
          .fontSize(15) // iOS .subheadline
          .fontWeight(600) // .weight(.semibold)
          .fontColor(DesignTokens.danger(this.cm.dark)) // .foregroundStyle(.red)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: CONFIRM_PAD_V, bottom: CONFIRM_PAD_V })
          .backgroundColor(this.quaternary()) // Capsule().fill(.quaternary)
          .borderRadius(100) // Capsule = 完全圆角（计划 Global Constraints ②）
          .onClick((): void => this.onConfirm())
      }
      .padding(BUBBLE_PADDING)
      .width(BUBBLE_WIDTH)
      .backgroundBlurStyle(BlurStyle.Regular) // .fill(.regularMaterial)
      .borderRadius(BUBBLE_RADIUS)
      .shadow({
        radius: 14,
        color: SHADOW_COLOR,
        offsetX: 0,
        offsetY: 5,
      })

      // 尾尖：从气泡底边向下探入触发行内，指向该行（iOS :77-83 直译）
      Polygon({ width: TAIL_WIDTH, height: TAIL_HEIGHT })
        .points(this.tailPoints())
        .fill(this.tailFill())
        .offset({ y: TAIL_DROP })
    }
  }
}
