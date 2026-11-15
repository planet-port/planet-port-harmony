// HomeParallaxBackground.ets — 首页背景：自定义背景图 + 蒙纱 + 重力视差
//
// 直译源：iOS HomeParallaxBackground.swift:9-85（视觉与滤波参数）+
// Android HomeParallaxBackground.kt（@ohos.sensor 实现范式）。
//
// 行为（iOS 同名视图 1:1）：
// - 有图：Image 出血放大 1.12（每边余量 6%，最小屏 375vp 下 22.5vp ≥ 偏移上限
//   20vp，任何角度不露底色）+ 页面底色蒙纱（浅 0.4 / 深 0.78，保证身份区文字
//   对比度）+ 重力视差——手机倾斜时背景在出血余量内平移（最大 ±20vp），前景
//   UI 不动，形成「背景在深处」的层次。
// - 无图（T6 骨架期恒走此分支——BackgroundImageStore 归 T10）：退化为纯页面
//   底色，不注册传感器。
// - 无重力传感器（模拟器/平板）自动退化为静止背景。
//
// 传感器契约（brief 定值）：TYPE_GRAVITY 30Hz（interval 33_333_333ns）低通滤波
// α=0.1；归一化除 GRAVITY_EARTH=9.80665（@ohos.sensor 单位 m/s²，iOS CoreMotion
// gravity 单位 g——不除会放大 ~10 倍冲出出血余量，Android 审查 I-1 同账）；
// x 取负（手机右倾 gravity.x 增大 → 背景向左移）；y 直接取重力分量；aboutToDisappear
// 注销（进程后台随页面销毁收口，对齐 iOS onDisappear stop）。
import { sensor } from '@kit.SensorServiceKit';
import { image } from '@kit.ImageKit';
import { DesignTokens, colorModeSignal } from './DesignTokens';

/** 视差最大偏移（iOS parallaxRange 20pt） */
const PARALLAX_RANGE: number = 20;
/** 出血比例（iOS bleed 1.12；余量校验见文件头） */
const BLEED_PERCENT: string = '112%';
/** 重力归一化基准（Android SensorManager.GRAVITY_EARTH 同值，m/s²） */
const GRAVITY_EARTH: number = 9.80665;
/** 采样周期 ≈33ms（30Hz，对齐 iOS deviceMotionUpdateInterval 1/30） */
const SAMPLE_INTERVAL_NS: number = 33_333_333;
/** 低通滤波系数（iOS alpha 0.1；手机回正时偏移自然回零） */
const LOW_PASS_ALPHA: number = 0.1;

/**
 * 蒙纱色 = 页面底色（DesignTokens.pageBg 同值）叠加 alpha 档
 * （iOS .overlay Color.opacity 直译：浅 0.4→0x66 / 深 0.78→0xC7）。
 * 显式分支而非位运算：>2^31 的 0xAARRGGBB 经 int32 位运算会翻转成负数。
 */
function veilColor(dark: boolean): number {
  return dark ? 0xC71C1C1E : 0x66F2F2F7;
}

@ComponentV2
export struct HomeParallaxBackground {
  /** 自定义背景图（null = 未设置，仅页面底色；真值由 T10 BackgroundImageStore 接线） */
  @Param image: image.PixelMap | null = null;
  /** 视差开关（仅 image != null 时有意义；T10 接 prefs.parallax 前恒 true） */
  @Param parallaxEnabled: boolean = true;

  /** 平滑偏移（-1..1，发布到主线程；@Trace 驱动 30fps 重绘） */
  @Local offsetX: number = 0;
  @Local offsetY: number = 0;

  private sensing: boolean = false;

  /** 低通滤波回调（箭头函数持 this；off 用同一引用精确注销） */
  private gravityCb = (data: sensor.GravityResponse): void => {
    // 手机右倾（gravity.x 增大）→ 背景向左移；y 直接取重力分量（iOS :69-71）
    const targetX = -data.x / GRAVITY_EARTH;
    const targetY = data.y / GRAVITY_EARTH;
    this.offsetX += (targetX - this.offsetX) * LOW_PASS_ALPHA;
    this.offsetY += (targetY - this.offsetY) * LOW_PASS_ALPHA;
  };

  aboutToAppear(): void {
    this.syncSensing();
  }

  aboutToDisappear(): void {
    this.stop();
  }

  /** image/parallaxEnabled 变化实时生效（iOS onChange(of: parallaxEnabled)） */
  @Monitor('image', 'parallaxEnabled')
  onVisualParamChange(): void {
    this.syncSensing();
  }

  private syncSensing(): void {
    if (this.image !== null && this.parallaxEnabled) {
      this.start();
    } else {
      this.stop();
    }
  }

  private start(): void {
    if (this.sensing) {
      return;
    }
    try {
      // 无传感器设备 on 抛错（930100001 等）：catch 后保持静止（offsets 恒 0）
      const opt: sensor.Options = { interval: SAMPLE_INTERVAL_NS };
      sensor.on(sensor.SensorId.GRAVITY, this.gravityCb, opt);
      this.sensing = true;
    } catch (e) {
      // 静止退化：offsets 保持 0（iOS isDeviceMotionAvailable false 同语义）
    }
  }

  private stop(): void {
    if (!this.sensing) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.GRAVITY, this.gravityCb);
    } catch (e) {
      // 注销失败不放大（sensing 已翻 false，泄漏窗口仅限服务异常场景）
    }
    this.sensing = false;
    this.offsetX = 0;
    this.offsetY = 0;
  }

  build() {
    Stack() {
      if (this.image !== null) {
        // 出血 1.12：预放大铺满 + 居中（余量四边均分），偏移在余量内不露底色
        Image(this.image)
          .width(BLEED_PERCENT)
          .height(BLEED_PERCENT)
          .objectFit(ImageFit.Cover)
          .translate({
            x: this.offsetX * PARALLAX_RANGE,
            y: this.offsetY * PARALLAX_RANGE,
          })
        // 蒙纱：systemGroupedBackground 等价页面底色（iOS :38-42 浅 0.4/深 0.78）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(veilColor(colorModeSignal.dark))
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(DesignTokens.pageBg(colorModeSignal.dark))
      }
    }
    .width('100%')
    .height('100%')
  }
}
