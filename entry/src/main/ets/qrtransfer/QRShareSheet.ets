// QRShareSheet.ets — 分享端：分片二维码序列展示
// （iOS Modules/QRTransfer/Sources/Views/QRShareView.swift + QRShareSession 直译）
//
// 单帧退化为静态码（无控件）；多帧提供速度四档（0.3/0.5/0.8/1.2s）与手动模式
// （点方块阵列直接跳帧）。编码与渲染在打开 sheet 时进行（与 sheet 动画并行，
// iOS QRShareSession 同构），首张就绪即显示；全部就绪后才允许自动播放启动。
//
// 与 iOS 的实现差异（鸿蒙后端适配）：
//   - iOS QRShareSession 直接编码后逐帧渲染；本侧 QRTransfer.encode 用 ECC M
//     理论容量定帧，随后以 QRRender.moduleCount 实测首帧验证「真实后端能否在
//     maxModules 内渲染」（T4 裁决 1：把 fits 接到 ScanKit 真实行为）。实测超限
//     则按版本步长（4 模块）收缩容量重编——最坏 5 次探测（收缩重编路径下每轮
//     新帧文本缓存失效），仍在 ≤5 契约内（M-6 口径修正：非「≤2 次出图」的乐观
//     估计）；仍超限进 tooLarge 态——方向安全：显式 LEVEL_M 下理论与实测应当
//     一致，重编轮只是对 ScanKit 非标准实现的防御。
//   - 二维码边长 = 屏宽 72%（iOS UIScreen.main.bounds.width * 0.72 直译），
//     出图 px = 边长 vp × 屏幕密度，收敛到 ScanKit [200,4096] 域。
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { DesignTokens } from '../components/DesignTokens';
import { L10n } from '../components/L10n';
import { QRTransfer } from './QRTransfer';
import { QRRender, qrAccent, qrFmt } from './QRRender';
import { ShardGrid } from './ShardGrid';

/** 自动轮播速度四档（秒），iOS QRShareView.speeds 直译 */
const SPEEDS: number[] = [0.3, 0.5, 0.8, 1.2];
/** 实测超限时容量收缩重编上限（brief：ChunkPlanner 二分/探测轮数 ≤5 可接受） */
const MAX_PLAN_ATTEMPTS: number = 5;
/** 二维码边长 = 屏宽 72%（iOS QRShareView.side 直译） */
const SIDE_RATIO: number = 0.72;
/** 模块数下限（QRTransfer.recommendedMaxModules 的 v9 下限，收缩不可越过） */
const MIN_MODULES: number = 53;

@ComponentV2
export struct QRShareSheet {
  /** 待传输原始数据（QRShareSession.payload 直译） */
  @Param payload: Uint8Array = new Uint8Array(0);
  /** 标题查表键（iOS navigationTitle 由触发方传入） */
  @Param titleKey: string = 'planet.share.qr.title';
  /** 关闭回调（iOS dismiss 等价，由宿主收起 sheet） */
  @Param onClose: () => void = () => {};

  @Local frames: string[] = [];
  @Local images: image.PixelMap[] = [];
  @Local tooLarge: boolean = false;
  @Local index: number = 0;
  @Local manual: boolean = false;
  @Local speed: number = 0.5;

  /** 帧位图出图边长（px），prepare 定值 */
  private renderPx: number = 600;
  /** 二维码边长（vp），布局用 */
  private sideVp: number = 260;
  /** 自动轮播定时器（aboutToDisappear 必清，brief Step 2） */
  private timer: number = -1;
  /** prepare/render 异步链的存活门（sheet 关闭后不再写状态） */
  private alive: boolean = true;

  aboutToAppear(): void {
    this.alive = true;
    void this.prepare();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopTimer();
    // 释放已生成位图（M-3）：PixelMap 持有底层像素缓冲，不 release 逐张泄漏；
    // 逐张判空防双释（已 release 的 PixelMap 再 release 会报错），闭完清空集合
    for (const pm of this.images) {
      if (pm) {
        void pm.release().catch(() => {});
      }
    }
    this.images = [];
  }

  // ---------------------------------------------------------------- 编码与渲染

  private async prepare(): Promise<void> {
    const dsp = display.getDefaultDisplaySync();
    const density = dsp.densityPixels > 0 ? dsp.densityPixels : 3;
    this.sideVp = dsp.width / density * SIDE_RATIO;
    this.renderPx = QRRender.clampPx(this.sideVp * density);
    const maxModules = QRTransfer.recommendedMaxModules(this.sideVp);

    // 容量规划：理论编码 → 首帧实测 →（超限时）按版本步长收缩重编；最坏 5 次
    // 探测（收缩重编路径下每轮新帧文本缓存失效），仍在 ≤5 契约内（M-6 口径修正）
    let effective = maxModules;
    let planned: string[] = [];
    let measured = 0;
    for (let attempt = 0; attempt < MAX_PLAN_ATTEMPTS; attempt++) {
      try {
        planned = QRTransfer.encode(this.payload, effective);
      } catch (err) {
        // QRTransferError.TooLarge：容量/帧数超限（iOS session.tooLarge 同态）
        if (this.alive) {
          this.tooLarge = true;
        }
        return;
      }
      try {
        measured = await QRRender.moduleCount(planned[0]);
      } catch (err) {
        measured = 0; // 实测不可用 → 退回理论容量（显式 LEVEL_M 下即为上界）
      }
      if (measured <= maxModules) {
        break; // 真实渲染达标（或实测失败回退理论）
      }
      const next = Math.max(MIN_MODULES, effective - 4 * Math.ceil((measured - maxModules) / 4));
      if (next >= effective) {
        if (this.alive) {
          this.tooLarge = true; // 已到下限仍超限：数据过大
        }
        return;
      }
      effective = next;
    }
    // 循环耗尽（I-1）：5 轮全部实测超限且收缩未触下限退出——末轮 planned 仍
    // 超限，不得静默展示，按数据过大收口（与上两个出口同态）
    if (measured > maxModules) {
      if (this.alive) {
        this.tooLarge = true;
      }
      return;
    }
    if (!this.alive) {
      return;
    }
    this.frames = planned;
    this.index = 0;

    // 逐帧串行渲染（与 sheet 动画并行，首张就绪即显示；进度文案随 images 增长）
    for (const frame of planned) {
      if (!this.alive) {
        return;
      }
      try {
        const pm = await QRRender.render(frame, this.renderPx);
        if (!this.alive) {
          // 关闭后才完成：该图未入列、无人释放，就地 release 防泄漏（M-3）
          void pm.release().catch(() => {});
          return;
        }
        this.images = this.images.concat([pm]);
      } catch (err) {
        // 单帧渲染失败：跳过（后续帧继续；该帧缺失时 currentImage 取末张已生成）
        continue;
      }
      if (this.images.length === planned.length) {
        this.restartTimer(); // 渲染全部就绪后才允许自动播放（iOS autoplay 前置条件）
      }
    }
  }

  // ---------------------------------------------------------------- 轮播控制

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private restartTimer(): void {
    this.stopTimer();
    if (this.manual || this.frames.length <= 1 || this.images.length < this.frames.length) {
      return;
    }
    this.timer = setInterval(() => {
      this.index = (this.index + 1) % this.frames.length;
    }, Math.round(this.speed * 1000));
  }

  /** 1 基分片号跳转（iOS jump 直译） */
  private jump(oneBased: number): void {
    if (this.frames.length <= 0) {
      return;
    }
    this.index = (oneBased - 1 + this.frames.length) % this.frames.length;
  }

  private onManualToggle(on: boolean): void {
    this.manual = on;
    this.restartTimer();
  }

  private onSpeedPick(s: number): void {
    this.speed = s;
    this.restartTimer();
  }

  // ---------------------------------------------------------------- UI

  private dark(): boolean {
    return DesignTokens.dark();
  }

  build() {
    Column() {
      this.header()
      if (this.frames.length === 0) {
        this.emptyState()
      } else {
        this.readyState()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.dark()))
  }

  /** 头部：左占位 + 居中标题 + 右「完成」（iOS confirmationAction 直译） */
  @Builder
  header() {
    Row() {
      Row().width(64)
      Text(L10n.get(this.titleKey))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.dark()))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(L10n.get('qrtransfer.done'))
        .fontSize(15)
        .fontColor(qrAccent())
        .width(64)
        .textAlign(TextAlign.End)
        .onClick(() => this.onClose())
    }
    .width('100%')
    .height(48)
    .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })
  }

  /** 未就绪态：生成中（Progress + 文案）或 数据过大（标题 + 提示） */
  @Builder
  emptyState() {
    Column({ space: 10 }) {
      if (this.tooLarge) {
        Text(L10n.get('qrtransfer.tooLarge'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(DesignTokens.textPrimary(this.dark()))
        Text(L10n.get('qrtransfer.tooLarge.hint'))
          .fontSize(13)
          .fontColor(DesignTokens.textSecondary(this.dark()))
          .textAlign(TextAlign.Center)
          .padding({ left: 30, right: 30 })
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(DesignTokens.textSecondary(this.dark()))
        Text(L10n.get('qrtransfer.generating'))
          .fontSize(13)
          .fontColor(DesignTokens.textSecondary(this.dark()))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 就绪态：二维码 + 生成进度 + 分片阵列 + 速度/手动控件（多帧才有） */
  @Builder
  readyState() {
    Column({ space: 18 }) {
      if (this.images.length > 0) {
        // 已渲染图按 index 取；该帧未就绪时取最后一张已生成的（iOS currentImage 直译）
        Image(this.images[Math.min(this.index, this.images.length - 1)])
          .width(this.sideVp)
          .height(this.sideVp)
          .interpolation(ImageInterpolation.None)
      } else {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(DesignTokens.textSecondary(this.dark()))
        }
        .width(this.sideVp)
        .height(this.sideVp)
        .justifyContent(FlexAlign.Center)
      }
      if (this.images.length < this.frames.length) {
        Text(qrFmt('qrtransfer.generating %d/%d', [this.images.length, this.frames.length]))
          .fontSize(13)
          .fontColor(DesignTokens.textSecondary(this.dark()))
      }
      if (this.frames.length > 1) {
        ShardGrid({
          total: this.frames.length,
          current: this.index + 1,
          onTap: (i: number) => {
            if (this.manual) {
              this.jump(i); // 手动模式点阵列跳帧（iOS onTap: manual ? jump : nil 直译）
            }
          },
        })
        this.controls()
      }
      Blank()
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 12, left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })
  }

  /** 手动开关 + 速度四档（手动开启时隐藏速度档，iOS controls 直译） */
  @Builder
  controls() {
    Column({ space: 10 }) {
      Row() {
        Text(L10n.get('qrtransfer.manual'))
          .fontSize(14)
          .fontColor(DesignTokens.textPrimary(this.dark()))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.manual })
          .selectedColor(qrAccent())
          .onChange((on: boolean) => this.onManualToggle(on))
      }
      .width('100%')
      if (!this.manual) {
        Row({ space: 6 }) {
          ForEach(SPEEDS, (s: number) => {
            Text(`${s.toFixed(1)}s`)
              .fontSize(13)
              .fontColor(this.speed === s ? 0xFFFFFFFF : DesignTokens.textSecondary(this.dark()))
              .textAlign(TextAlign.Center)
              .width(56)
              .height(30)
              .borderRadius(8)
              .backgroundColor(this.speed === s ? qrAccent() : DesignTokens.cardBg(this.dark()))
              .border({
                width: this.speed === s ? 0 : 1,
                color: DesignTokens.hairline(this.dark()),
              })
              .onClick(() => this.onSpeedPick(s))
          }, (s: number) => `${s}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 300 })
  }
}
