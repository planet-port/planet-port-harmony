// AppAlert.ets — 自绘 alert 宿主（iOS HomeView.dialogCard 视觉参数直译）
//
// 直译源：iOS HomeView.swift:600-621（dialogCard：maxWidth 300 / 内容 padding 20 /
// 条目间距 14 / 圆角 16 / .regularMaterial / 阴影 black 0.15 r12 y4 / 转场
// scale 0.95 + opacity）+ iOS 系统 alert 排版惯例（标题 headline 居中、正文
// footnote 居中、按钮区通栏贴卡片底边且上方以分隔线隔开——footer 全出血排版）。
// 模态语义：遮罩 black 0.35 拦截点击，点卡片外不关闭——系统 alert 即如此，
// 关闭只经按钮（与 ConfirmBubble 的「点外即关」刻意相反，iOS 两类弹窗语义相反）。
// 转场在组件内分层挂接（iOS 实态 HomeView.swift:538-540/620：scrim 只
// .transition(.opacity)，dialogCard 单独 .scale(0.95)+.opacity）——遮罩与卡片
// 拆层各挂 transition，遮罩不随卡片 0.95→1 缩放（整卡挂接会连遮罩一起缩、
// 出现/消失瞬间遮罩边缘内收）。宿主 if 出入直接挂载本组件即可。
// 按钮文案契约：AppAlertButton.label 是成品文案（调用方已过 L10n），本组件
// 不二次查表——二次 loc 在「文案值恰为另一 key 名」时会错译（双重本地化
// 契约收口）；语言切换触踪由调用方承担（宿主重渲染即传入新 buttons）。
// T12 扩展（iOS HomeView.swift:533-621 双阶段切换弹窗宿主需求，全部默认值
// 与既有调用点逐像素兼容）：
//   ① AppAlertButton.secondary —— 取消按钮 secondary 字色/常规字重
//      （iOS 自绘 dialogCard 按钮行：取消 .secondary 常规、确认 accent semibold；
//      destructive 仍红字，优先级高于 secondary）。
//   ② emphasis —— 正文按 ** 分段交替加粗（iOS Text 对 LocalizedStringKey 内联
//      渲染 **bold** 的直译；表值含 ** 标记，拆段后奇数段 semibold）。
//   ③ loading —— 断开阶段卡：大转圈 + subheadline 文案，无标题无按钮
//      （iOS disconnecting 阶段 dialogCard{ ProgressView + Text } 直译）。
// 范式：@ComponentV2 / 零 @StorageProp / cm.dark 触踪 / 对象字面量显式类型 /
// @kit 导入。
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { themeSignal } from '../store/ThemeManager';

/** 卡片宽度上限（iOS .frame(maxWidth: 300)） */
const CARD_MAX_WIDTH: number = 300;
/** 内容区内边距与条目间距（iOS .padding(20) / VStack spacing 14） */
const CARD_PADDING: number = 20;
const CONTENT_SPACING: number = 14;
/** 卡片圆角（iOS RoundedRectangle(cornerRadius: 16)） */
const CARD_RADIUS: number = 16;
/** 阴影（iOS shadow black 0.15 r12 y4 → alpha 0.15*255≈0x26） */
const SHADOW_COLOR: number = 0x26000000;
/** 遮罩（iOS Color.black.opacity(0.35) → alpha 0.35*255≈0x59） */
const SCRIM_COLOR: number = 0x59000000;
/** 按钮行高（系统 alert 按钮区标准高度） */
const BUTTON_HEIGHT: number = 44;
/** 按钮字号（系统 alert action ≈ callout 16） */
const FS_BUTTON: number = 16;
/** 断开阶段正文（iOS .subheadline 15）与转圈直径（iOS .controlSize(.large)） */
const FS_SUBHEADLINE: number = 15;
const LOADING_SPINNER: number = 36;
/** 卡片转场（iOS dialogCard .transition(.scale(0.95) + .opacity) 直译） */
const CARD_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
  .animation({ duration: 200, curve: Curve.EaseOut });
/** 遮罩转场（iOS scrim .transition(.opacity) 直译：只淡入淡出，不随卡片缩放） */
const SCRIM_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .animation({ duration: 200, curve: Curve.EaseOut });

/** alert 按钮（iOS .alert Button(role:action:) 直译）。label 为成品文案
 *  （调用方已过 L10n），本组件不二次查表（见文件头契约） */
export class AppAlertButton {
  label: string;
  /** iOS .destructive role：红字；其余按钮走主题 accent */
  destructive: boolean;
  action: () => void;
  /** 取消档（iOS 自绘 dialogCard 取消按钮直译）：secondary 字色 + 常规字重；
   *  destructive 优先（红字），默认 false 与既有调用点兼容 */
  secondary: boolean;

  constructor(label: string, destructive: boolean, action: () => void,
    secondary: boolean = false) {
    this.label = label;
    this.destructive = destructive;
    this.action = action;
    this.secondary = secondary;
  }
}

@ComponentV2
export struct AppAlert {
  /** 标题（必须具体——iOS alert 语义，禁「提示」类泛题） */
  @Param title: string = '';
  /** 正文（'' = 不渲染） */
  @Param message: string = '';
  /** 按钮组（0..2 个；空数组渲染纯信息卡） */
  @Param buttons: AppAlertButton[] = [];
  /** 正文 ** 分段交替加粗（iOS Text 内联 markdown 加粗直译；T12 扩展） */
  @Param emphasis: boolean = false;
  /** 断开阶段卡（T12 扩展）：大转圈 + subheadline 文案，无标题无按钮 */
  @Param loading: boolean = false;

  /** 深浅色触踪（发丝线/正文色切换重渲染） */
  @Local cm: ColorModeSignal = colorModeSignal;

  /** emphasis 分段（'**' 切分；奇数下标段加粗——iOS **bold** 对称标记直译） */
  private messageSegments(): string[] {
    return this.message.split('**');
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 全屏遮罩：black 0.35；点击不关闭（系统 alert 模态语义，无 onDismiss 入口）
      // 转场只 opacity（iOS scrim .transition(.opacity) 直译，不随卡片缩放）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SCRIM_COLOR)
        .transition(SCRIM_TRANSITION)

      // 卡片（iOS dialogCard 直译：footer 按钮区通栏贴底边，上方分隔线隔开）
      Column() {
        if (this.loading) {
          // 断开阶段（iOS disconnecting dialogCard 直译）：大转圈 + subheadline
          Column({ space: CONTENT_SPACING }) {
            LoadingProgress()
              .width(LOADING_SPINNER)
              .height(LOADING_SPINNER)
              .color(themeSignal.accent)
            if (this.message !== '') {
              Text(this.message)
                .fontSize(FS_SUBHEADLINE) // iOS .subheadline
                .fontWeight(FontWeight.Medium)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
                .textAlign(TextAlign.Center)
                .width('100%')
            }
          }
          .width('100%')
          .padding(CARD_PADDING)
        } else {
          Column({ space: CONTENT_SPACING }) {
            Text(this.title)
              .fontSize(17) // iOS .headline
              .fontWeight(600) // .headline semibold
              .fontColor(DesignTokens.textPrimary(this.cm.dark))
              .textAlign(TextAlign.Center)
              .width('100%')
            if (this.message !== '') {
              if (this.emphasis) {
                Text() {
                  ForEach(this.messageSegments(), (seg: string, idx: number) => {
                    Span(seg)
                      .fontSize(13) // iOS .footnote
                      .fontColor(DesignTokens.textSecondary(this.cm.dark))
                      .fontWeight(idx % 2 === 1 ? 600 : 400)
                  }, (seg: string, idx: number) =>
                    `${idx}:${seg}` + (this.cm.dark ? ':d' : ':l')) // 深浅档入 key（评审 I-3）
                }
                .textAlign(TextAlign.Center)
                .width('100%')
              } else {
                Text(this.message)
                  .fontSize(13) // iOS .footnote
                  .fontColor(DesignTokens.textSecondary(this.cm.dark))
                  .textAlign(TextAlign.Center)
                  .width('100%')
              }
            }
          }
          .width('100%')
          .padding(CARD_PADDING)

          if (this.buttons.length > 0) {
            Divider()
              .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
              .color(DesignTokens.hairline(this.cm.dark))
            Row() {
              ForEach(this.buttons, (btn: AppAlertButton, idx: number) => {
                if (idx > 0) {
                  Divider()
                    .vertical(true)
                    .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
                    .color(DesignTokens.hairline(this.cm.dark))
                }
                Text(btn.label)
                  .fontSize(FS_BUTTON)
                  .fontWeight(btn.secondary && !btn.destructive ? 400 : 600)
                  .fontColor(btn.destructive
                    ? DesignTokens.danger(this.cm.dark)
                    : btn.secondary
                      ? DesignTokens.textSecondary(this.cm.dark)
                      : themeSignal.accent)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height('100%')
                  .onClick((): void => btn.action())
              }, (btn: AppAlertButton) =>
                btn.label + (this.cm.dark ? ':d' : ':l')) // 深浅档入 key（评审 I-3 顺带）
            }
            .width('100%')
            .height(BUTTON_HEIGHT)
          }
        }
      }
      .constraintSize({ maxWidth: CARD_MAX_WIDTH })
      .backgroundBlurStyle(BlurStyle.Regular) // iOS .regularMaterial
      .borderRadius(CARD_RADIUS)
      .shadow({
        radius: 12,
        color: SHADOW_COLOR,
        offsetX: 0,
        offsetY: 4,
      })
      // 卡片单独 scale 0.95 + opacity（iOS dialogCard .transition 直译）；
      // 遮罩层已单独挂 SCRIM_TRANSITION，两层互不连带
      .transition(CARD_TRANSITION)
    }
    .width('100%')
    .height('100%')
  }
}
