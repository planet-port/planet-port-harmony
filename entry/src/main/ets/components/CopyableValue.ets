// CopyableValue.ets — 可复制值文本（iOS CopyableValue.swift 直译）
//
// 点击（透明热区外扩 5，不改变布局）复制到剪贴板；可选常驻复制图标；复制
// 成功后图标位置短暂变对勾（0.8s，句柄于 aboutToDisappear 清理）。占位值
// （空 / "—" / "-"，调用方无数据时的显示约定）不可复制，常驻图标随之隐藏。
// 热区外扩 5 的 ArkUI 等价：容器 padding(5) 扩出可点区 + margin(-5) 抵消布局
// 占位（iOS overlay Rectangle .padding(-5) 直译），文字本身不挂手势。
import pasteboard from '@ohos.pasteboard';
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';

/** 对勾反馈停留时长（iOS asyncAfter 0.8s） */
const CHECKMARK_MS: number = 800;
/** iOS .body 默认字号（CopyableValue font 缺省 .system(.body, mono)） */
const FS_BODY: number = 17;

@ComponentV2
export struct CopyableValue {
  /** 值文本（单行中段截断） */
  @Param text: string = '';
  /** 是否常驻复制图标；false 时仅复制成功瞬间显示对勾 */
  @Param showsIcon: boolean = true;
  /** 值文字字号（iOS font 参数的 size 维度） */
  @Param fontSize: number = FS_BODY;
  /** 是否等宽（iOS design: .monospaced 直译；ID/IP/hex 均等宽） */
  @Param mono: boolean = true;
  /** 值文字色（iOS color 参数直译；深浅色分支由调用方求值传入） */
  @Param color: number = DesignTokens.textSecondary(DesignTokens.dark());
  /** 复制图标字号（iOS iconSize 缺省 11：约为文字字高 2/3） */
  @Param iconSize: number = 11;
  /** 对勾成功色（iOS ThemeManager.success 直译）：主题派生色随 derive 开关/
   *  深浅色变化由调用方经 applyTheme 重算传入；缺省 = SuccessGreen 资产真值
   *  （与 ThemeManager.SUCCESS_FALLBACK_HEX 0x009830 同源，互指勿单改） */
  @Param successColor: number = 0xFF009830;

  /** 复制反馈：图标短暂变对勾 */
  @Local copied: boolean = false;
  /** 深浅色触踪（对勾成功色/三级色切换重渲染） */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 对勾复位定时器句柄（重复复制/组件销毁时清理） */
  private copyTimer: number = -1;

  aboutToDisappear(): void {
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
  }

  /** 占位值不可复制：看着能点、点了没反应的防线（iOS isPlaceholder 直译） */
  private isPlaceholder(): boolean {
    return this.text === '' || this.text === '—' || this.text === '-';
  }

  private copy(): void {
    if (this.isPlaceholder()) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer); // 重复复制：重置在途复位定时器
    }
    this.copied = true;
    this.copyTimer = setTimeout(() => {
      this.copied = false;
      this.copyTimer = -1;
    }, CHECKMARK_MS);
  }

  /** L10n 查表 + l10nSignal.rev 触踪（HomeView loc() 恒假分支同款范式） */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  build() {
    Row({ space: 4 }) {
      Text(this.text)
        .fontSize(this.fontSize)
        .fontFamily(this.mono ? DesignTokens.FONT_MONO : 'HarmonyOS Sans')
        .fontColor(this.color)
        .maxLines(1)
        // iOS truncationMode(.middle) 无枚举等价（TextOverflow 仅 None/Clip/
        // Ellipsis/MARQUEE）：降级尾省略，中段截断归 T9 详情页评审再裁
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if ((this.showsIcon && !this.isPlaceholder()) || this.copied) {
        // iOS doc.on.doc 鸿蒙 symbol 表无对应名，取同形 doc_filled_on_doc
        SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
          .fontSize(this.iconSize)
          .fontWeight(this.copied ? 600 : 400) // iOS semibold/regular
          .fontColor([this.copied ? this.successColor
            : DesignTokens.textTertiary(this.cm.dark)])
      }
    }
    .alignItems(VerticalAlign.Center)
    // 透明热区外扩 5：padding 扩出可点区 + 负 margin 抵消布局占位
    .padding(5)
    .margin(-5)
    .onClick(() => this.copy())
    .accessibilityText(this.loc('common.copy'))
    .accessibilityDescription(this.text) // iOS accessibilityValue 的近似（值朗读走描述位）
  }
}
