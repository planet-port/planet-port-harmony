// BackgroundImagePickerSheet.ets — 背景图选择半模态（iOS BackgroundImagePickerSheet.swift 直译）
//
// 相册（PhotoViewPicker，系统选择器无需相册权限）或 URL 下载（仅 http/https）；
// 已设置时显示清除行（红字 destructive）。校验/落盘/解码全部收口在
// BackgroundImageStore（错误码 → error.bg.* 文案映射在本层，Android PrefsViewModel
// 的「VM 层本地化」同分层）；应用成功（prefs.backgroundImage=true 双写 + store
// 信号发布）经 onApplied 通知宿主关层——iOS「成功后 dismiss」直译。
// PhotoPicker 差异：iOS 侧把相册结果统一重编码为 JPEG（避免 HEIC 直存后解码
// 失败）；鸿蒙 PhotoViewPicker 返回 file:// uri，store 按 uri 直接拷贝沙盒并做
// 可解码校验——重编码步骤天然不需要（不产位图，校验失败即拒）。
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { StoreRepo } from '../store/StoreRepo';
import { BackgroundImageStore, BgImageError } from '../store/BackgroundImageStore';
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { themeSignal } from '../store/ThemeManager';

/** 表单字号（iOS .body 17 / .caption 12 / .caption2 11） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_SECTION_HEADER: number = 11;
/** 表单行高（iOS Form 行标准 44pt） */
const ROW_HEIGHT: number = 44;
/** 表单区水平边距 / 区间距（iOS Form grouped inset 直译，JoinNetworkSheet 同款） */
const FORM_MARGIN: number = DesignTokens.MARGIN_PAGE;
const FORM_SECTION_GAP: number = 20;

@ComponentV2
export struct BackgroundImagePickerSheet {
  /** 是否已设置背景图（清除行显隐；宿主传 hasBackgroundImage 真值） */
  @Param hasImage: boolean = false;
  /** 应用成功回调（宿主关层 + 偏好镜像刷新；iOS dismiss 直译） */
  @Param onApplied: () => void = (): void => { };
  /** 收起回调（iOS dismiss；宿主收起 sheet） */
  @Param onClose: () => void = (): void => { };

  /** URL 输入（iOS @State urlText 直译） */
  @Local urlText: string = '';
  /** 下载在途（按钮禁用 + 尾部转圈） */
  @Local downloading: boolean = false;
  /** 区脚红字错误提示（iOS footer errorText 直译） */
  @Local errorText: string = '';
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.format(key, args);
  }

  // ---- 应用路径 ----

  /** store 错误码 → 三语文案（error.bg.*；文案映射收口在本层见文件头） */
  private errorTextOf(err: BgImageError): string {
    return this.loc(err === BgImageError.TooLarge
      ? 'error.bg.tooLarge' : 'error.bg.notImage');
  }

  /** 应用成功：prefs.backgroundImage 双写（Android applyBackgroundImage 直译——
   *  布尔位控制首启冷加载路径）→ 通知宿主关层 */
  private async applied(): Promise<void> {
    await StoreRepo.store.writePrefs(p => {
      p.backgroundImage = true;
      return p;
    });
    this.onApplied();
  }

  /** 相册选图 → 校验 + 拷贝沙盒 + 应用（iOS PhotoPicker 回调直译） */
  private async pickPhoto(): Promise<void> {
    const opts: photoAccessHelper.PhotoSelectOptions = {
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1,
    };
    const picker = new photoAccessHelper.PhotoViewPicker();
    let uris: string[] = [];
    try {
      uris = (await picker.select(opts)).photoUris;
    } catch (_e) {
      return; // 取消选择 / 选择器异常静默（AlbumQrPicker 同语义）
    }
    if (uris.length === 0) {
      return; // 用户取消：不关层、不清错误（iOS nil 回调同语义）
    }
    const err = await BackgroundImageStore.saveFromUri(uris[0]);
    if (err === null) {
      await this.applied();
    } else {
      this.errorText = this.errorTextOf(err);
    }
  }

  /** URL 下载 → 校验字节 → 落盘应用（iOS download() 直译） */
  private async download(): Promise<void> {
    const trimmed = this.urlText.trim();
    // scheme 守卫：仅 http/https（iOS URL(string:) + scheme 比对直译；
    // isValidURL 的正则等价物，空串也走此分支）
    if (!/^https?:\/\//i.test(trimmed)) {
      this.errorText = this.loc('bg.error.invalidUrl');
      return;
    }
    this.downloading = true;
    this.errorText = '';
    try {
      const data = await BackgroundImagePickerSheet.httpGet(trimmed);
      if (data.byteLength === 0) {
        this.errorText = this.loc('bg.error.emptyContent'); // iOS guard !data.isEmpty 直译
        return;
      }
      const err = await BackgroundImageStore.saveData(data);
      if (err === null) {
        await this.applied();
      } else {
        this.errorText = this.errorTextOf(err);
      }
    } catch (e) {
      const be = e as BusinessError;
      const detail = typeof be.message === 'string' && be.message !== ''
        ? be.message : String(be.code); // iOS error.localizedDescription 等价
      this.errorText = this.locFmt('bg.error.download %@', [detail]);
    } finally {
      this.downloading = false;
    }
  }

  /** GET 字节（URLSession.shared.data(from:) 直译）：非 2xx 抛错并入下载失败文案 */
  private static async httpGet(url: string): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return resp.result as ArrayBuffer;
    } finally {
      req.destroy(); // destroy 幂等，成功/失败路径统一收口
    }
  }

  /** 清除（iOS clear 行直译：store 清文件 + prefs 布尔复位 → 宿主关层） */
  private async clearBg(): Promise<void> {
    await BackgroundImageStore.clear();
    await StoreRepo.store.writePrefs(p => {
      p.backgroundImage = false;
      return p;
    });
    this.onApplied();
  }

  // ---- 渲染（JoinNetworkSheet 表单范式） ----

  @Builder
  navBar() {
    Row() {
      // iOS toolbar .cancellationAction 位唯一按钮即「完成」（源如此，直译不挪位）
      Text(this.loc('common.done'))
        .fontSize(FS_BODY)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ left: 12, top: 12, bottom: 12, right: 4 })
      Text(this.loc('bg.title'))
        .fontSize(FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Row().width(60)
    }
    .width('100%')
    .height(48)
  }

  @Builder
  sectionHeader(key: string) {
    Text(this.loc(key))
      .fontSize(FS_SECTION_HEADER)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, bottom: 4 })
  }

  /** 区脚：错误红字（iOS footer if let errorText 直译）或空占位 */
  @Builder
  errorFooter() {
    Text(this.errorText)
      .fontSize(FS_CAPTION)
      .fontColor(DesignTokens.danger(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: FORM_SECTION_GAP }) {
          // ---- 相册区（iOS Section("bg.albumHeader") 直译；鸿蒙符号域无
          // photo.on.rectangle，取 picture 同族降级——偏差记录见报告）----
          Column() {
            this.sectionHeader('bg.albumHeader')
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.picture'))
                .fontSize(20)
                .fontColor([themeSignal.accent])
              Text(this.loc('bg.choosePhoto'))
                .fontSize(FS_BODY)
                .fontColor(themeSignal.accent)
            }
            .width('100%')
            .height(ROW_HEIGHT)
            .padding({ left: 16, right: 16 })
            .onClick((): void => void this.pickPhoto())
            .accessibilityText(this.loc('bg.choosePhoto'))
          }
          .width('100%')

          // ---- URL 区（iOS Section TextField + 下载行 footer 直译）----
          Column() {
            this.sectionHeader('bg.urlHeader')
            Column() {
              TextInput({ text: this.urlText, placeholder: 'https://example.com/bg.jpg' })
                .fontSize(FS_BODY)
                .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
                .backgroundColor(Color.Transparent)
                .padding({ left: 0, right: 0 })
                .height(ROW_HEIGHT)
                // iOS keyboardType(.URL) 直译缺口：ArkUI ContentType 域解析异常
                // （URL=13 存于 text_input.d.ts，编译期 ambient 冲突），降级默认键盘
                .onChange((v: string): void => {
                  this.urlText = v;
                })
              Divider()
                .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
                .color(DesignTokens.hairline(this.cm.dark))
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                  .fontSize(20)
                  .fontColor([themeSignal.accent])
                Text(this.loc('bg.download'))
                  .fontSize(FS_BODY)
                  .fontColor(themeSignal.accent)
                Blank()
                if (this.downloading) {
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .color(themeSignal.accent)
                }
              }
              .width('100%')
              .height(ROW_HEIGHT)
              .padding({ left: 16, right: 16 })
              .opacity(this.urlText.trim() === '' || this.downloading ? 0.35 : 1) // .disabled 直译
              .onClick((): void => {
                if (this.urlText.trim() !== '' && !this.downloading) {
                  void this.download();
                }
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            this.errorFooter()
          }
          .width('100%')

          // ---- 清除区（仅已设置时；destructive 红，iOS Button(role: .destructive) 直译）----
          if (this.hasImage) {
            Column() {
              Row() {
                Text(this.loc('bg.clear'))
                  .fontSize(FS_BODY)
                  .fontColor(DesignTokens.danger(this.cm.dark))
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .height(ROW_HEIGHT)
              .backgroundColor(DesignTokens.cardBg(this.cm.dark))
              .borderRadius(DesignTokens.RADIUS_SM)
              .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
              .onClick((): void => void this.clearBg())
              .accessibilityText(this.loc('bg.clear'))
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 24 })
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
}
