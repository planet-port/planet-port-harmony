// QrScannerSheet.ets — 单帧扫码弹层（Android ui/home/QrScannerSheet.kt sheet
// 宿主形态 + iOS QRScannerView 语义直译）
//
// 相机走 ScanKit scanBarcode.startScanForResult 系统默认扫码 UI（系统级预授
// 相机权限，App 无需索权、无 iOS/Android 的权限被拒分支——denied 态在鸿蒙
// 通路下不可达，能力缺失时由 QRReceiveSheet 式引导态兜底，本弹层不做）。
// 进入 sheet 即拉起系统扫码；识别到 `ZTQR1|` 前缀、纯 16 位 hex 网络 ID 或
// URL/文件 scheme 即回调 onScanned（一次即停）；用户取消后回 sheet，点按取
// 景区可重新拉起。相册单选 → ScanKit 图像识别（与相机路径同一 extract，
// Android 同构）。相册识别失败提示：无码 qr.albumNoQr / 有码但内容不符
// qr.albumNoUrl（Android AlbumScanError 直译；qr.* 键组是单帧扫码场景的既有键组）。
import { common } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { DesignTokens } from '../components/DesignTokens';
import { L10n } from '../components/L10n';
import { AlbumQrPicker } from './AlbumQrPicker';

/** 网络 ID 定长（16 位 hex；iOS NetworkEntry.nwid 同口径） */
const NWID_LEN: number = 16;

/** hex 字符判定（0-9 a-f A-F；本地实现，不反向依赖 components/JoinNetworkSheet） */
function isHexDigit(c: string): boolean {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/** 整段 hex 判定（空串恒假） */
function isHexString(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    if (!isHexDigit(s[i])) {
      return false;
    }
  }
  return true;
}

@ComponentV2
export struct QrScannerSheet {
  /** 识别命中回调（提取后的内容；宿主收到后收起 sheet） */
  @Param onScanned: (text: string) => void = (_text: string) => {};
  /** 关闭回调（iOS cancellationAction 直译） */
  @Param onClose: () => void = () => {};

  /** 相册识别失败文案键：'' / qr.albumNoQr / qr.albumNoUrl */
  @Local albumErrorKey: string = '';
  /** 系统扫码 UI 已拉起（避免重复启动） */
  private scanning: boolean = false;
  /** 组件存活门（QRShareSheet.alive 同款范式）：sheet 关闭后，在途扫码/相册
   *  识别回调一律丢弃，不再触发 onScanned（I-2） */
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    void this.startScan();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private ctx(): common.UIAbilityContext {
    // getHostContext 在已渲染组件内恒有值；undefined 仅异常时序，转译后由
    // ScanKit 参数校验兜错（startScan 已 catch）
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 内容提取（iOS QRScannerView.extract 语义 + brief 键约定）：
   *  `ZTQR1|` 前缀原样返回（分片传输入口）；纯 16 位 hex（trim + 忽略大小写）
   *  原样返回——iOS NetworkQRSheet 生成的二维码就是网络 ID 纯文本
   *  （NetworkDetailView.swift:312「内容 = 网络 ID 纯文本,与 App 内扫码填 ID
   *  互逆」），iOS 侧经 QRScannerView.extractNetworkId 整段合法分支命中
   *  （QRScannerView.swift:127-137），宿主 JoinNetworkSheet 回调内再归一小写
   *  回填；http(s)/file scheme 原样返回（URL 导入场景）；非整段文本再走
   *  [0-9a-f]{16} 正则子串兜底（iOS extractNetworkId 同款：第三方工具的
   *  "ID: abc..." 码也能识别，返回命中子串的小写形态）——兜底置于 URL 检查
   *  之后，防 URL 路径内嵌 16 位 hex 时被截胡破坏 URL 导入通道。
   *  检查序 ZTQR1| → hex 整段 → URL → hex 子串：不影响已闭环的分片/URL
   *  语义与存活门。 */
  private extract(text: string): string | null {
    const t = text.trim();
    if (t.startsWith('ZTQR1|')) {
      return t;
    }
    const lowered = t.toLowerCase();
    if (lowered.length === NWID_LEN && isHexString(lowered)) {
      return t;
    }
    const sep = t.indexOf('://');
    if (sep > 0) {
      const scheme = t.slice(0, sep).toLowerCase();
      if (scheme === 'http' || scheme === 'https' || scheme === 'file') {
        return t;
      }
    }
    const embedded = lowered.match(/[0-9a-f]{16}/);
    if (embedded !== null) {
      return embedded[0];
    }
    return null;
  }

  /** 拉起系统扫码 UI；命中即回调（一次即停），取消/服务错误均静默回 sheet
   *  （单帧扫码场景无聚合状态可展示，iOS QRScannerView 同款静默语义） */
  private async startScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    const opts: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE] };
    try {
      const r = await scanBarcode.startScanForResult(this.ctx(), opts);
      const hit = this.extract(r.originalValue);
      if (hit !== null && this.alive) {
        this.onScanned(hit); // 存活门：sheet 已关（晚于 onClose 到达）则作废（I-2）
      }
    } catch (err) {
      // 用户取消（1000500002）与服务异常统一静默
    } finally {
      this.scanning = false;
    }
  }

  /** 相册单选 → 图像识别 → 同一 extract 提取（Android QrScannerSheet 直译）：
   *  区分无码 / 有码但内容不符，提示才有诊断价值 */
  private async pickAlbum(): Promise<void> {
    this.albumErrorKey = '';
    const texts = await AlbumQrPicker.pickTexts(this.ctx(), false);
    if (!this.alive) {
      return; // sheet 已关：在途识别结果作废，不再触发 onScanned/写状态（I-2）
    }
    if (texts.length === 0) {
      this.albumErrorKey = 'qr.albumNoQr';
      return;
    }
    for (const text of texts) {
      const hit = this.extract(text);
      if (hit !== null) {
        this.onScanned(hit);
        return;
      }
    }
    this.albumErrorKey = 'qr.albumNoUrl';
  }

  private dark(): boolean {
    return DesignTokens.dark();
  }

  build() {
    Column() {
      this.header()
      this.scanArea()
      if (this.albumErrorKey !== '') {
        this.albumErrorBar()
      }
    }
    .width('100%')
    .backgroundColor(DesignTokens.pageBg(this.dark()))
  }

  /** 头部：左「取消」+ 居中标题 + 右「相册」（Android SheetScaffold 头区直译） */
  @Builder
  header() {
    Row() {
      Text(L10n.get('qrtransfer.cancel'))
        .fontSize(15)
        .fontColor(DesignTokens.textPrimary(this.dark()))
        .onClick(() => this.onClose())
      Blank()
      Text(L10n.get('qr.title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.dark()))
      Blank()
      Image($r('sys.media.ohos_ic_public_albums'))
        .width(24)
        .height(24)
        .fillColor(DesignTokens.textSecondary(this.dark()))
        .onClick(() => void this.pickAlbum())
    }
    .width('100%')
    .height(48)
    .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })
  }

  /** 取景区：点按重新拉起系统扫码（进入 sheet 已自动拉起一次） */
  @Builder
  scanArea() {
    Column({ space: 12 }) {
      Image($r('sys.media.ohos_ic_public_camera'))
        .width(40)
        .height(40)
        .fillColor(DesignTokens.textSecondary(this.dark()))
      Text(L10n.get('qr.title'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary(this.dark()))
    }
    .width('100%')
    .height(300)
    .justifyContent(FlexAlign.Center)
    .onClick(() => void this.startScan())
  }

  /** 相册识别失败提示条（Android AlbumErrorBar 直译：warn 色随主题） */
  @Builder
  albumErrorBar() {
    Text(L10n.get(this.albumErrorKey))
      .fontSize(13)
      .fontColor(DesignTokens.warn(this.dark()))
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .backgroundColor(DesignTokens.cardBg(this.dark()))
  }
}
