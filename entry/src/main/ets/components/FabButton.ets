// FabButton.ets — FAB（可拖动 + 松手左右吸附 + 位置记忆）
//
// 直译源：iOS FabButton.swift（拖动/吸附/持久化行为与全部定值）+
// Android FabButton.kt（ArkUI 化的动画承载范式）。
//
// 行为（iOS 1:1）：
// - 56×56 accent 圆形 + 白 plus（SF plus title2 semibold → sys.symbol.plus 22fp）；
//   点击回调 action（T6 骨架期占位，T9 接 JoinNetworkSheet）。
// - 默认右下（侧距 22 + 底距 54）；垂直活动范围：头区以下（上限 88）到底距以上。
// - 跟手拖动（PanGesture distance 2，每帧直接赋值不包动画——Android 同裁决，
//   offset 逐帧重绘等价 iOS 跟手弹簧观感）；拖动缩放 0.95 + 阴影增强
//   （0.25→0.3 / 10→14，spring 0.5/0.7），松手弹回。
// - 松手水平吸附较近一侧（spring 0.35/0.7），吸附落位后持久化。
// - 位置记忆：dataPreferences（iOS UserDefaults / Android SharedPreferences 等
//   价落盘域——AppStorage 不落盘，brief 的「AppStorage 键」按控制器裁决改为
//   preferences；实例名 planetport_ui 与键名 HomeView.fab.x/y 沿用 Android）。
//   x>0 且 y>0 才恢复；仅恢复一次（尺寸就绪后）。
//
// 容器契约：本组件根节点是满幅 Stack，hitTestBehavior(None)——自身不参与命中
// 且不阻塞子/兄弟节点：空白区触摸穿透到下层 Swiper，仅 56×56 圆面响应手势，
// iOS GeometryReader + .overlay 的命中语义等价物。
import { preferences } from '@kit.ArkData';
import { curves } from '@kit.ArkUI';
import { themeSignal } from '../store/ThemeManager';
import { L10n, l10nSignal } from './L10n';

/** FAB 半径（直径 56）；左右吸附与屏幕边框 22 安全距离；垂直范围头区下 88 到底距 54 */
const RADIUS: number = 28;
const SIDE_MARGIN: number = 22;
const BOTTOM_MARGIN: number = 54;
const TOP_LIMIT: number = 88;
/** 位置记忆 preferences 实例名与键（Android planetport_ui 同名沿用） */
const PREF_STORE: string = 'planetport_ui';
const KEY_X: string = 'HomeView.fab.x';
const KEY_Y: string = 'HomeView.fab.y';

@ComponentV2
export struct FabButton {
  /** 点击回调（iOS onTapGesture(action)；T9 换 JoinNetworkSheet 弹层真值） */
  @Param action: () => void = () => {};

  /** 当前中心点（vp，相对本组件容器）；null = 未拖动且未恢复 → 默认右下 */
  @Local centerX: number | null = null;
  @Local centerY: number | null = null;
  /** 拖起/放下（缩放 0.95↔1 与阴影增强共用一根弹簧） */
  @Local dragging: boolean = false;
  /** 容器尺寸（onAreaChange 就绪后恢复持久化位置；0×0 阶段不渲染按钮） */
  @Local areaW: number = 0;
  @Local areaH: number = 0;

  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private prefs: preferences.Preferences | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const opt: preferences.Options = { name: PREF_STORE };
    this.prefs = preferences.getPreferencesSync(ctx, opt);
  }

  // ---- 位置 ----

  /** 位置约束：水平不越左右安全边距，垂直在头区以下、底距以上；未就绪原样返回 */
  private clampX(x: number): number {
    if (this.areaW <= 0) {
      return x;
    }
    return Math.min(Math.max(x, SIDE_MARGIN + RADIUS), this.areaW - SIDE_MARGIN - RADIUS);
  }

  private clampY(y: number): number {
    if (this.areaH <= 0) {
      return y;
    }
    return Math.min(Math.max(y, TOP_LIMIT + RADIUS), this.areaH - BOTTOM_MARGIN - RADIUS);
  }

  /** 默认右下角（trailing 22 + bottom 54，与原固定位置一致） */
  private defaultX(): number {
    return this.areaW - SIDE_MARGIN - RADIUS;
  }

  private defaultY(): number {
    return this.areaH - BOTTOM_MARGIN - RADIUS;
  }

  /** L10n 查表 + l10nSignal.rev 触踪（HomeView.loc 同一惯用形）：无障碍文案
   *  随语言切换刷新（评审 M-1——直读 L10n.get 无触踪不重渲染） */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 仅在无位置且尺寸就绪时恢复一次；无记录（x≤0 或 y≤0）保持默认右下 */
  private restoreIfNeeded(): void {
    if (this.centerX !== null || this.areaW <= 0 || this.areaH <= 0 || this.prefs === null) {
      return;
    }
    const x = this.prefs.getSync(KEY_X, 0) as number;
    const y = this.prefs.getSync(KEY_Y, 0) as number;
    if (x > 0 && y > 0) {
      this.centerX = this.clampX(x);
      this.centerY = this.clampY(y);
    }
  }

  /** 落盘（putSync 内存即时生效 + flush 异步刷盘，失败不放大） */
  private save(x: number, y: number): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.putSync(KEY_X, x);
    this.prefs.putSync(KEY_Y, y);
    this.prefs.flush().catch(() => {});
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.areaW > 0 && this.areaH > 0) {
        // 56×56 accent 圆 + 白 plus（iOS SF plus title2 semibold → 22fp）
        Row() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(22)
            .fontColor([Color.White])
            .fontWeight(600) // iOS .semibold → 600（ArkUI 无该枚举档）
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(themeSignal.accent)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .shadow({
          radius: this.dragging ? 14 : 10,
          color: this.dragging ? 0x4D000000 : 0x40000000,
          offsetX: 0,
          offsetY: 5,
        })
        .scale({ x: this.dragging ? 0.95 : 1, y: this.dragging ? 0.95 : 1 })
        .offset({
          x: (this.centerX !== null ? this.centerX : this.defaultX()) - RADIUS,
          y: (this.centerY !== null ? this.centerY : this.defaultY()) - RADIUS,
        })
        .onClick(() => this.action())
        .accessibilityText(this.loc('fab.addNetwork'))
        .gesture(
          PanGesture({ distance: 2 })
            .onActionStart(() => {
              // 拖起：以当前落位（含吸附落点）为基准（iOS dragStart = position(in:)）
              this.dragStartX = this.centerX !== null ? this.centerX : this.defaultX();
              this.dragStartY = this.centerY !== null ? this.centerY : this.defaultY();
              // 拿起手感：缩小 0.95 + 阴影增强（iOS withAnimation spring 0.5/0.7）
              this.getUIContext().animateTo(
                { curve: curves.springMotion(0.5, 0.7) },
                () => {
                  this.dragging = true;
                });
            })
            .onActionUpdate((event: PanGestureEvent) => {
              // 跟手：每帧直接赋值（offset 逐帧重绘，Android 直接用拖动值同裁决）
              this.centerX = this.clampX(this.dragStartX + event.offsetX);
              this.centerY = this.clampY(this.dragStartY + event.offsetY);
            })
            .onActionEnd(() => {
              // 松手水平吸附较近一侧（iOS onEnded 同判定），spring 0.35/0.7 弹回
              const fromX = this.centerX !== null ? this.centerX : this.defaultX();
              const snappedX = fromX < this.areaW / 2
                ? SIDE_MARGIN + RADIUS
                : this.areaW - SIDE_MARGIN - RADIUS;
              const toY = this.centerY !== null ? this.centerY : this.defaultY();
              const finalX = this.clampX(snappedX);
              const finalY = this.clampY(toY);
              this.getUIContext().animateTo(
                { curve: curves.springMotion(0.35, 0.7) },
                () => {
                  this.dragging = false;
                  this.centerX = finalX;
                  this.centerY = finalY;
                });
              this.save(finalX, finalY);
            }))
      }
    }
    .width('100%')
    .height('100%')
    // 空白区穿透：满幅容器自身不参与命中、不阻塞子/兄弟节点（子 FAB 正常响应，
    // 下层 Swiper 在空白区可滑动/点击）——iOS overlay 命中语义等价物
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      // 首帧布局 0×0，就绪后才恢复（否则 clamp 成负值，每次打开都在左上角）
      this.areaW = newValue.width as number;
      this.areaH = newValue.height as number;
      this.restoreIfNeeded();
    })
  }
}
