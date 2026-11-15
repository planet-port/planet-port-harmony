// HSLColorPicker.ets — 自绘 HSL 取色器（iOS PrefsView.swift:313 HSLColorPicker 直译）
//
// 饱和度（横向 白→纯色）× 亮度（纵向 白→透明→黑）平面 + 色相彩虹条，三值一个
// 控件。不用系统 ColorPicker——它必然再弹一层系统面板，且「最近颜色」无法隐藏
// （iOS/Android 同裁决）。
//
// 读写协议（受控组件，iOS 直读 ThemeManager 单一数据源的解耦形态）：h/s/l 由
// 宿主传入（宿主持有当前主色，预设色板与色盘自动互相同步）；拖动/点按经
// onChange(h, s, l) 逐帧回报增量，抬手经 onCommit() 通知宿主一次性落盘——
// Android HslColorPicker 的 preview/commit 两段范式（拖动逐帧写 prefs.json 会
// 打爆盘；鸿蒙 ThemeManager 无逐帧写 API，宿主侧落盘见 PrefsView 主题弹层）。
// 坐标：GestureEvent.fingerList[0].localX/localY 为组件相对 vp（SDK
// component/gesture.d.ts :754-773），除以组件实际尺寸归一；组件尺寸经
// onAreaChange 实测（GeometryReader 无独立组件形态，ArkUI 等价物）。
import { PlanetIcon } from './PlanetIcon';
import { l10nSignal, L10n } from './L10n';

/** 平面高度（iOS .frame(height: 180)） */
const FIELD_HEIGHT: number = 180;
/** 色相条区域高度（iOS .frame(height: 28)） */
const BAR_HEIGHT: number = 28;
/** 色相彩虹轨道高（iOS Capsule height 10） */
const RAIL_HEIGHT: number = 10;
/** 游标直径（iOS cursorCircle 22） */
const CURSOR_SIZE: number = 22;
/** 平面圆角（iOS RoundedRectangle(cornerRadius: 10)） */
const FIELD_RADIUS: number = 10;
/** 平面/色相条间距（iOS VStack spacing 14） */
const PICKER_SPACING: number = 14;
/** 游标描边与阴影（iOS .black.opacity(0.25) ≈ 0x40 alpha；lineWidth 1.5 / r1 y1） */
const CURSOR_STROKE: number = 0x40000000;

/** [0,1] 钳制（iOS min(max(_, 0), 1) 直译） */
function clamp01(v: number): number {
  return Math.min(Math.max(v, 0), 1);
}

@ComponentV2
export struct HSLColorPicker {
  /** 色相 0..<360（宿主当前主色派生；预设改色后游标同步） */
  @Param hue: number = 0;
  /** 饱和度 0..1（平面横向） */
  @Param sat: number = 0;
  /** 亮度 0..1（平面纵向） */
  @Param light: number = 0;
  /** 增量回报（拖动中逐帧；宿主更新预览色不落盘） */
  @Param onChange: (h: number, s: number, l: number) => void =
    (_h: number, _s: number, _l: number): void => { };
  /** 拖动结束/点按完成（宿主一次性落盘发布） */
  @Param onCommit: () => void = (): void => { };

  /** 组件实测尺寸（vp；onAreaChange 维护，除法分母防零） */
  @Local fieldW: number = 1;
  @Local fieldH: number = 1;
  @Local barW: number = 1;

  /** L10n 触踪惯用形（本组件现无文案消费；保留同款 loc 以对齐项目范式） */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  // ---- 取值域 ----

  /** 平面横向渐变终点色：当前色相的纯色端（s=1 l=0.5，iOS hueColor 直译） */
  private hueColor(): number {
    return PlanetIcon.colorFromHex(PlanetIcon.hslToHex(this.hue, 1, 0.5)) ?? 0xFF808080;
  }

  /** 彩虹轨道 7 段 stops（红→黄→绿→青→蓝→洋红→红，iOS hueStops 直译） */
  private hueStops(): Array<[string, number]> {
    const stops: Array<[string, number]> = [];
    for (let i = 0; i <= 6; i++) {
      stops.push(['#FF' + PlanetIcon.hslToHex(i * 60, 1, 0.5), i / 6]);
    }
    return stops;
  }

  // ---- 手势 ----

  /** 平面点位 → (s, l) 增量回报（iOS satLightField onChanged 直译） */
  private pickField(event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return; // 键盘/手柄触发无手指信息（SDK d.ts :764）
    }
    const p = event.fingerList[0];
    const s = clamp01(p.localX / Math.max(this.fieldW, 1));
    const l = 1 - clamp01(p.localY / Math.max(this.fieldH, 1));
    this.onChange(this.hue, s, l);
  }

  /** 色相条点位 → h 增量回报（iOS hueBar onChanged 直译） */
  private pickHue(event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return;
    }
    const p = event.fingerList[0];
    const h = clamp01(p.localX / Math.max(this.barW, 1)) * 360;
    this.onChange(h, this.sat, this.light);
  }

  /** 平面/色相条共用拖动手势组：点按（distance 0 语义）+ 拖动并行，抬手提交 */
  private pickGestures(pick: (event: GestureEvent) => void): GestureGroupInterface {
    return GestureGroup(GestureMode.Parallel,
      TapGesture().onAction((event: GestureEvent): void => {
        pick(event);
        this.onCommit();
      }),
      PanGesture({ distance: 1 })
        .onActionStart((event: GestureEvent): void => pick(event))
        .onActionUpdate((event: GestureEvent): void => pick(event))
        .onActionEnd((): void => this.onCommit()));
  }

  build() {
    Column({ space: PICKER_SPACING }) {
      // ---- 饱和度×亮度平面（iOS satLightField 直译）----
      Stack({ alignContent: Alignment.TopStart }) {
        // 底层：横向 白→纯色（s: 0→1）
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            direction: GradientDirection.Right,
            colors: [['#FFFFFFFF', 0], [this.hueColor(), 1]],
          })
        // 上层：纵向 白→透明→黑（l: 1→0.5→0）
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#FFFFFFFF', 0], ['#00FFFFFF', 0.5], ['#FF000000', 1]],
          })
        // 游标（iOS cursorCircle 直译：白心 + 黑 25% 描边 1.5 + 阴影 r1 y1）
        Column()
          .width(CURSOR_SIZE)
          .height(CURSOR_SIZE)
          .borderRadius(CURSOR_SIZE / 2)
          .backgroundColor('#FFFFFFFF')
          .border({ width: 1.5, color: CURSOR_STROKE })
          .shadow({ radius: 1, color: CURSOR_STROKE, offsetX: 0, offsetY: 1 })
          .position({
            x: this.fieldW * this.sat - CURSOR_SIZE / 2,
            y: this.fieldH * (1 - this.light) - CURSOR_SIZE / 2,
          })
      }
      .width('100%')
      .height(FIELD_HEIGHT)
      .borderRadius(FIELD_RADIUS)
      .clip(true) // iOS clipShape RoundedRectangle 直译（游标贴边溢出裁掉）
      .onAreaChange((_old: Area, nv: Area): void => {
        this.fieldW = Math.max(nv.width as number, 1);
        this.fieldH = Math.max(nv.height as number, 1);
      })
      .gesture(this.pickGestures((event: GestureEvent): void => this.pickField(event)))

      // ---- 色相条（iOS hueBar 直译：彩虹轨道 10 + 游标垂直居中）----
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height(RAIL_HEIGHT)
          .borderRadius(RAIL_HEIGHT / 2)
          .linearGradient({
            direction: GradientDirection.Right,
            colors: this.hueStops(),
          })
        Column()
          .width(CURSOR_SIZE)
          .height(CURSOR_SIZE)
          .borderRadius(CURSOR_SIZE / 2)
          .backgroundColor('#FFFFFFFF')
          .border({ width: 1.5, color: CURSOR_STROKE })
          .shadow({ radius: 1, color: CURSOR_STROKE, offsetX: 0, offsetY: 1 })
          .position({
            x: this.barW * this.hue / 360 - CURSOR_SIZE / 2,
            y: BAR_HEIGHT / 2 - CURSOR_SIZE / 2,
          })
      }
      .width('100%')
      .height(BAR_HEIGHT)
      .onAreaChange((_old: Area, nv: Area): void => {
        this.barW = Math.max(nv.width as number, 1);
      })
      .gesture(this.pickGestures((event: GestureEvent): void => this.pickHue(event)))
    }
    .width('100%')
  }
}
