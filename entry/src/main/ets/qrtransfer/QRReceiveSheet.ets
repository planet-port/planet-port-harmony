// QRReceiveSheet.ets — 接收端：连续扫码聚合分片
// （iOS Modules/QRTransfer/Sources/Views/QRReceiveView.swift 直译 +
//  ContinuousScanner.swift 的聚合语义）
//
// 不区分单帧/多帧——解码任意帧 → 按 index 聚合 → 齐全后整体校验（Base45 →
// 解压 → CRC）→ 通过即回调一次。total/checksum 与已收集合不一致（扫到新会话）
// 时自动清空重来；CRC 失败同样清空。非分片帧交给 onPlainFrame：返回 true 表示
// 调用方已消费（如 http(s) 链接二维码），整页结束。
//
// 扫码通路（鸿蒙适配，iOS 为 AVCapture 连续取景器）：
//   - 相机走 ScanKit scanBarcode.startScanForResult 系统默认扫码 UI（系统级
//     预授相机权限，App 无需索权）；每帧回传后自动接力重启扫码 UI（relay），
//     发送端轮播场景下对准即逐帧聚合。用户取消（1000500002）即停接力回到
//     sheet——iOS 连续取景无「暂停」概念，此处取消即暂停，停止态给「继续扫码
//     + 相册」入口（键复用 qr.title / qrtransfer.album，20 键表无 resume 键）。
//   - 相册走 PhotoViewPicker 多选 → ScanKit 图像识别（AlbumQrPicker 串行限流），
//     逐帧喂同一聚合状态机（iOS sheet 回调同构）；失败按 iOS AlbumScanError
//     三态归因：无码 / 序列不完整 / 数据格式不正确。
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { DesignTokens } from '../components/DesignTokens';
import { L10n } from '../components/L10n';
import { QRFrame } from './QRFrame';
import { QRTransfer } from './QRTransfer';
import { qrAccent, qrFmt } from './QRRender';
import { AlbumQrPicker } from './AlbumQrPicker';
import { ShardGrid } from './ShardGrid';

@ComponentV2
export struct QRReceiveSheet {
  /** 聚合完成回调（通过整体校验的原始数据，一次） */
  @Param onComplete: (data: Uint8Array) => void = (_data: Uint8Array) => {};
  /** 非分片帧回调：返回 true 表示该帧即结果，扫码随即结束（iOS 同名直译） */
  @Param onPlainFrame: (text: string) => boolean = (_text: string) => false;
  /** 关闭回调（宿主收起 sheet） */
  @Param onClose: () => void = () => {};

  @Local total: number = 0;
  @Local received: Set<number> = new Set<number>();
  @Local corrupt: boolean = false;
  @Local finished: boolean = false;
  /** 相册识别失败文案键：'' / albumNoQr / albumIncomplete / albumInvalid（iOS 三态） */
  @Local albumErrorKey: string = '';
  /** 系统扫码 UI 打开中（接力进行）；false 且未完成 → 停止态（继续扫码入口） */
  @Local relayOn: boolean = false;
  /** 相册选择/识别进行中（接力暂停） */
  @Local albumBusy: boolean = false;
  /** 扫码能力不可用/服务错误（引导态：非权限问题——相机权限归系统扫码 UI） */
  @Local unsupported: boolean = false;

  /** 分片载荷聚合表：index(1 基) → chunk（iOS chunks: [Int: String] 直译） */
  private chunks: Map<number, string> = new Map();
  /** 当前会话 CRC（会话切换判定用；0 = 尚无会话） */
  private checksum: number = 0;
  /** 接力循环存活门 */
  private relayAlive: boolean = false;
  /** 组件存活门（QRShareSheet.alive 同款范式）：sheet 关闭后，在途扫码/相册
   *  回调一律丢弃，不再喂聚合、不再回调 onComplete/onPlainFrame、不再写状态 */
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    this.resumeRelay();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.relayAlive = false;
  }

  // ---------------------------------------------------------------- 聚合状态机

  /** iOS QRReceiveView.handle 直译 */
  private handle(text: string): void {
    if (!this.alive || this.finished) {
      return; // !alive：sheet 已关，在途回调丢弃（I-2）
    }
    const frame = QRTransfer.parse(text);
    if (frame === null) {
      // 非分片帧：交调用方识别，消费成功（如扫到链接二维码）即整页结束
      if (this.onPlainFrame(text)) {
        this.finished = true;
        this.relayAlive = false;
      }
      return;
    }
    // 换了传输会话（total 或 CRC 不同）：丢弃旧集合
    if (this.total > 0 && (this.total !== frame.total || this.checksum !== frame.crc32)) {
      this.chunks.clear();
      this.syncReceived();
    }
    this.total = frame.total;
    this.checksum = frame.crc32;
    this.chunks.set(frame.index, frame.payload);
    this.corrupt = false;
    this.syncReceived();
    if (this.chunks.size !== frame.total) {
      return;
    }
    const all: QRFrame[] = [];
    for (let i = 1; i <= frame.total; i++) {
      const chunk = this.chunks.get(i);
      if (chunk !== undefined) {
        all.push(new QRFrame(frame.total, i, frame.crc32, frame.length, chunk));
      }
    }
    try {
      const data = QRTransfer.decodeStrict(all);
      this.finished = true;
      this.relayAlive = false;
      this.onComplete(data);
    } catch (e) {
      // QRTransferError：数据损坏 → 清空重扫（iOS catch 分支直译）
      this.chunks.clear();
      this.syncReceived();
      this.corrupt = true;
    }
  }

  /** @Local Set 整体替换（内容变更即换新引用，重渲染确定性不依赖集合装饰器） */
  private syncReceived(): void {
    const keys: number[] = Array.from(this.chunks.keys());
    this.received = new Set<number>(keys);
  }

  // ---------------------------------------------------------------- 扫码接力

  private ctx(): common.UIAbilityContext {
    // getHostContext 在已渲染组件内恒有值；undefined 仅异常时序，转译后由
    // ScanKit 参数校验兜错（scanOnce 已 catch）
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 停止态恢复入口（用户点继续扫码） */
  private resumeRelay(): void {
    this.unsupported = false;
    void this.runRelay();
  }

  /** 相机接力：系统扫码 UI 每帧回传后自动重启，取消/完成/相册即停（见文件头） */
  private async runRelay(): Promise<void> {
    if (this.relayAlive) {
      return;
    }
    this.relayAlive = true;
    this.relayOn = true;
    while (this.relayAlive && !this.finished && !this.unsupported && !this.albumBusy) {
      const text = await this.scanOnce();
      if (text === null || !this.alive) {
        // null = 用户取消 / 能力不可用：停接力回 sheet（停止态给继续+相册入口）；
        // !alive = sheet 已关：在途结果作废并退出循环（I-2）
        break;
      }
      this.handle(text);
    }
    this.relayAlive = false;
    if (this.alive) {
      this.relayOn = false; // 已关 sheet 不再写状态（在途退出路径，I-2）
    }
  }

  /** 单次系统扫码。返回码内容；null = 用户取消或能力/服务异常（后者置 unsupported） */
  private async scanOnce(): Promise<string | null> {
    const opts: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE] };
    try {
      const r = await scanBarcode.startScanForResult(this.ctx(), opts);
      return r.originalValue;
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
        return null; // 用户取消：静默停接力
      }
      if (this.alive) {
        this.unsupported = true; // 内部错误/设备不支持：引导态（相册通路仍可用）
      }
      return null;
    }
  }

  // ---------------------------------------------------------------- 相册通路

  private async pickAlbum(): Promise<void> {
    if (this.albumBusy) {
      return;
    }
    this.albumBusy = true;
    this.albumErrorKey = '';
    // pickTexts 内部已兜错恒不上抛（取消/识别失败统一返回空数组），无需
    // try/finally 保护——原 finally 包聚合属无 catch 的死防御（M-2），聚合
    // 挪回成功路径正常执行
    const texts = await AlbumQrPicker.pickTexts(this.ctx(), true);
    if (!this.alive) {
      this.albumBusy = false;
      return; // sheet 已关：在途相册结果作废，不再喂聚合/写状态（I-2）
    }
    // 逐帧喂现有聚合：分片/校验/会话切换逻辑与相机路径完全同构（iOS 直译）
    if (!this.finished) {
      if (texts.length === 0) {
        this.albumErrorKey = 'qrtransfer.albumNoQr';
      } else {
        for (const text of texts) {
          this.handle(text);
        }
        if (!this.finished) {
          // 解码失败（corrupt）→ 格式错误；有协议帧但没凑齐 → 序列不完整；
          // 一张协议帧都没有 → 视为格式不正确（有码但不是本协议内容）
          if (this.corrupt || this.chunks.size === 0) {
            this.albumErrorKey = 'qrtransfer.albumInvalid';
          } else {
            this.albumErrorKey = 'qrtransfer.albumIncomplete';
          }
        }
      }
    }
    this.albumBusy = false;
  }

  // ---------------------------------------------------------------- UI

  private dark(): boolean {
    return DesignTokens.dark();
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.scanArea()
      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(0xFF000000) // 取景器底恒黑（iOS ContinuousScanner .black 直译）
  }

  /** 中央取景区：接力中（黑底即系统扫码 UI 间隙）/ 停止态 / 引导态；
   *  完成后保持黑底（iOS onComplete 后由宿主立即收起，不露出停止态） */
  @Builder
  scanArea() {
    if (this.unsupported) {
      this.guide(false)
    } else if (this.relayOn || this.finished) {
      // 系统扫码 UI 全屏承载取景；本区只在 UI 间隙短暂露出，保持黑底即可
      Column().width('100%').height('100%')
    } else {
      // 停止态（用户取消后）：继续扫码 + 相册入口
      this.guide(true)
    }
  }

  /** 引导面板：unsupported = 能力不可用引导（iOS denied 分支等价：图标 40 +
   *  标题 + 说明 + 相册入口——相机被拒时相册识别仍可用，无相机场景留完整通路）；
   *  停止态（用户取消接力后）= 等待文案 + 继续扫码 + 相册。 */
  @Builder
  guide(showResume: boolean) {
    Column({ space: 12 }) {
      Image($r('sys.media.ohos_ic_public_camera'))
        .width(40)
        .height(40)
        .fillColor(DesignTokens.textSecondary(this.dark()))
      Text(this.unsupported
        ? L10n.get('qrtransfer.cameraDenied')
        : L10n.get('qrtransfer.waiting'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary(this.dark()))
      if (this.unsupported) {
        Text(L10n.get('qrtransfer.cameraDenied.hint'))
          .fontSize(12)
          .fontColor(DesignTokens.textSecondary(this.dark()))
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      }
      if (showResume) {
        // 键复用 qr.title（「扫码」动作语义；20 键表无独立 resume 键，iOS 连续
        // 取景无暂停态故无此键——偏差已在任务报告记档）
        Text(L10n.get('qr.title'))
          .fontSize(14)
          .fontColor(qrAccent())
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(DesignTokens.RADIUS_SM)
          .border({ width: 1, color: qrAccent() })
          .onClick(() => this.resumeRelay())
      }
      Text(L10n.get('qrtransfer.album'))
        .fontSize(14)
        .fontColor(DesignTokens.textPrimary(this.dark()))
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .borderRadius(DesignTokens.RADIUS_SM)
        .border({ width: 1, color: DesignTokens.hairline(this.dark()) })
        .onClick(() => void this.pickAlbum())
    }
    .width('100%')
  }

  /** 底部状态栏：分片阵列 + 已收计数 + 等待/损坏/相册错误文案（iOS 直译） */
  @Builder
  bottomBar() {
    Column({ space: 12 }) {
      if (this.total > 0) {
        ShardGrid({ total: this.total, received: this.received })
          .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })
        Text(this.receivedText())
          .fontSize(13)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textPrimary(this.dark()))
      }
      if (this.albumErrorKey !== '') {
        Text(L10n.get(this.albumErrorKey))
          .fontSize(12)
          .fontColor(DesignTokens.warn(this.dark()))
      } else if (this.corrupt) {
        Text(L10n.get('qrtransfer.corrupt'))
          .fontSize(12)
          .fontColor(DesignTokens.danger(this.dark()))
      } else {
        Text(L10n.get('qrtransfer.waiting'))
          .fontSize(12)
          .fontColor(DesignTokens.textSecondary(this.dark()))
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 20 })
    .backgroundColor(DesignTokens.cardBg(this.dark()))
    .alignItems(HorizontalAlign.Center)
  }

  private receivedText(): string {
    return qrFmt('qrtransfer.received %d/%d', [this.received.size, this.total]);
  }
}
