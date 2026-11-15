// ApplyTraceView.ets — 数据面诊断页（iOS ApplyTraceView.swift 全文直译，新建）
//
// 快照域透传（控制器裁决：缺字段记偏差不擅自扩 TunnelContract——快照已有
// applyTrace/eventLog 字符串字段，直接消费）：Extension 每次聚合应用写入的
// 决策追踪（只读，可长按选取复制）。两段：最新聚合决策（trace.last ←
// snapshot.applyTrace）+ 事件日志最近 40 条（trace.events ← snapshot.eventLog，
// '\n' 连接）。标题栏右侧复制钮 = 一键复制 applyTrace + "\n\n" + eventLog
// （iOS toolbar doc.on.doc 直译）；正文空显 trace.empty 占位。
import pasteboard from '@ohos.pasteboard';
import { AppNav } from '../ui/AppRoot';
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelSnapshot } from '../common/TunnelContract';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { L10n, l10nSignal } from '../components/L10n';

/** 字号（iOS .caption 12 / .body 17） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
/** 段间距与页内衬（iOS VStack spacing 16 + .padding() 直译） */
const SECTION_GAP: number = 16;
const PAGE_PAD: number = 16;
/** 段内标题与内容间距（iOS VStack spacing 6 直译） */
const SECTION_INNER_GAP: number = 6;

@ComponentV2
export struct ApplyTraceView {
  /** 页面入参（T5 契约；快照是隧道全局视图，本参数仅承载路由一致性） */
  @Param planetId: string = '';

  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 隧道快照（applyTrace/eventLog 唯一来源；整体替换触踪） */
  @Local snap: TunnelSnapshot | null = StatusStore.current();

  private unsubSnap: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubSnap = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      this.snap = s;
    });
    // 无快照先补读一次（直推链路冷启动兜底，StatusStore 订阅即推同语义）
    void StatusStore.refresh().then((): void => {
      this.snap = StatusStore.current();
    });
  }

  aboutToDisappear(): void {
    if (this.unsubSnap !== null) {
      this.unsubSnap();
      this.unsubSnap = null;
    }
  }

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 一键复制（iOS toolbar doc.on.doc 直译）：applyTrace + 空行 + eventLog */
  private copyAll(): void {
    const s = this.snap;
    const text = `${s === null ? '' : s.applyTrace}\n\n${s === null ? '' : s.eventLog}`;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
  }

  build() {
    Column() {
      this.titleBar()
      Scroll() {
        Column({ space: SECTION_GAP }) {
          this.section(this.loc('trace.last'),
            this.snap === null ? '' : (this.snap as TunnelSnapshot).applyTrace)
          this.section(this.loc('trace.events'),
            this.snap === null ? '' : (this.snap as TunnelSnapshot).eventLog)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(PAGE_PAD)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
  }

  /** 自绘标题栏（T5 骨架 + 右侧复制槽 = iOS toolbar Button 直译） */
  @Builder
  titleBar() {
    Row() {
      Row() {
        Image($r('sys.media.ohos_ic_back'))
          .width(24)
          .height(24)
          .fillColor(DesignTokens.textPrimary(this.cm.dark))
      }
      .width(44)
      .height(44)
      .onClick(() => AppNav.pop())
      Text(this.loc('trace.title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Row() {
        SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
          .fontSize(FS_BODY)
          .fontColor([DesignTokens.textPrimary(this.cm.dark)])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.copyAll();
      })
      .accessibilityText(this.loc('trace.copy'))
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .margin({ top: 12 })
  }

  /** 段（iOS section(_, _) 直译）：小号灰标题 + 等宽正文（空显占位文案，
   *  可长按选取复制 ≈ textSelection(.enabled)） */
  @Builder
  section(title: string, content: string) {
    Column({ space: SECTION_INNER_GAP }) {
      Text(title)
        .fontSize(FS_CAPTION)
        .fontWeight(600) // iOS .caption.weight(.semibold) 直译
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
      Text(content === '' ? this.loc('trace.empty') : content)
        .fontSize(FS_CAPTION) // iOS .system(.caption, design: .monospaced) 直译
        .fontFamily(DesignTokens.FONT_MONO)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .copyOption(CopyOptions.InApp) // iOS textSelection(.enabled) 直译
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
