// ShardGrid.ets — 分片方块阵列（iOS ShardGridView.swift / Android ShardGrid.kt 直译）
//
// 两种形态：
//   发送端：current 高亮当前帧，onTap 非空时可点跳转（手动模式）；
//   接收端：received 填充已收格，未收格描边强调缺片。
// 块上直接写分片号，替代独立的数字分片提示；流式换行、每行居中，方块定宽
// 不撑满整行（ArkUI 用 Flex wrap + Center 承载 iOS 自绘 FlowLayout 语义）。
// 三态色值（brief 逐字）：current = accent 实底 / received = accent @0.35 /
// missing = cardBg + 描边；块内分片号 mono 10。
// accent 直读不订 rev（T4 裁决 2：sheet 瞬态视图非响应式，T6 统一收口）。
import { DesignTokens } from '../components/DesignTokens';
import { qrAccent, qrAccentAlpha } from './QRRender';

const BLOCK_W: number = 30;
const BLOCK_H: number = 22;
const BLOCK_RADIUS: number = 6;
const BLOCK_GAP: number = 6;
const BLOCK_TEXT: number = 10;
/** received 态透明度 0.35 → 0x59（iOS Color.accentColor.opacity(0.35) 直译） */
const ALPHA_35: number = 0x59;

@ComponentV2
export struct ShardGrid {
  /** 分片总数（≥1） */
  @Param total: number = 0;
  /** 发送端当前帧（1 基）；0 = 接收端形态（未收格描边） */
  @Param current: number = 0;
  /** 接收端已收分片号集合（1 基） */
  @Param received: Set<number> = new Set<number>();
  /** 点击回调（1 基分片号）；发送端手动模式传 jump，缺省不可点 */
  @Param onTap: (index: number) => void = (_index: number) => {};

  private dark(): boolean {
    return DesignTokens.dark();
  }

  private indices(): number[] {
    const out: number[] = [];
    for (let i = 1; i <= this.total; i++) {
      out.push(i);
    }
    return out;
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
      ForEach(this.indices(), (i: number) => {
        this.block(i)
      }, (i: number) => `${i}`)
    }
    .constraintSize({ maxWidth: '100%' })
  }

  @Builder
  block(i: number) {
    Text(`${i}`)
      .width(BLOCK_W)
      .height(BLOCK_H)
      .borderRadius(BLOCK_RADIUS)
      .fontSize(BLOCK_TEXT)
      .fontFamily(DesignTokens.FONT_MONO)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.blockBg(i))
      .fontColor(this.blockFg(i))
      .border({
        width: this.isMissing(i) ? 1 : 0,
        color: DesignTokens.hairline(this.dark()),
      })
      .margin(BLOCK_GAP / 2)
      .onClick(() => this.onTap(i))
  }

  private isCurrent(i: number): boolean {
    return this.current === i;
  }

  private isReceived(i: number): boolean {
    return this.received.has(i);
  }

  /** current==0 即接收端形态：未收格描边（iOS isMissing 直译） */
  private isMissing(i: number): boolean {
    return this.current === 0 && !this.isReceived(i);
  }

  private blockBg(i: number): number {
    if (this.isCurrent(i)) {
      return qrAccent();
    }
    if (this.isReceived(i)) {
      return qrAccentAlpha(ALPHA_35);
    }
    return DesignTokens.cardBg(DesignTokens.dark());
  }

  private blockFg(i: number): number {
    if (this.isCurrent(i)) {
      return 0xFFFFFFFF; // onPrimary（Android 直译：current 块白字）
    }
    return DesignTokens.textSecondary(DesignTokens.dark());
  }
}
