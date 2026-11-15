// HomeMetrics.ets — 首页布局度量（iOS HomeMetrics.swift 直译）
//
// 行星页与添加页共享；T6 首页骨架落 pageTopPadding，其余度量消费随 T7-T12 回填。

export class HomeMetrics {
  /** 页面内容顶部固定间距 = 标题区高度 64 + 24 空隙（原 12，整体再下移 12）。
   *  标题区高度为常量：6 顶距 + 36 标题行（设置按钮撑高）+ 4 行距 + 6 圆点行
   *  + 12 底距。标题区任何子视图（行星提示 chip、圆点数量）变化都不改变该高度。 */
  static readonly pageTopPadding: number = 88;
}
