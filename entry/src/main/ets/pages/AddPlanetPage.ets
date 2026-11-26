// AddPlanetPage.ets — 添加行星页 + 导入四通道 + ZTP 预填
// （iOS AddPlanetPage.swift 全文 + AddPlanetForm.swift 全文直译，表单区块内联）
//
// 直译源结构：身份预览区（72pt 磁贴 + 行内名称 + 随机按钮，虚线边框 =「尚未
// 创建」占位形态）→ 标题/副指引 → 表单卡（选文件/扫二维码/URL 三行）→ 添加
// 按钮。文件/URL/二维码三通道先「就绪」（pendingData 校验头字节），名称齐备
// 后点「添加」才落库（双查重 → importPlanetData → 选中 + reload + 重掷身份）。
//
// 四通道（iOS AddPlanetForm 同构）：
//   ① 文件 DocumentViewPicker → 读字节 → 头字节校验 → 就绪；
//   ② URL http requestInStream 下载（进度模态 180 高：Content-Length 已知走
//      linear 进度/未知转圈；onWillDismiss 拦截 = interactiveDismissDisabled；
//      失败/校验不过 → 顶部 Capsule toast 2.5s）；
//   ③ 动态二维码 QRReceiveSheet 分片聚合 → QRTransfer.decode → ZTP 容器解析
//      （key 1=planet/2=名称/3=图标/4=底色）→ 数据 + 名称/图标/底色预填
//      （预填表单不直接落库，仍走「添加」）；
//   ④ 扫码链接：onPlainFrame 识别 http(s) URL → 关扫码层 → 回填 URL → 走 ②。
// 通道③④宿主选 QRReceiveSheet 而非 QrScannerSheet（单帧即停语义不满足连续
// 分片聚合；QRReceiveSheet 的 onComplete/onPlainFrame/onClose 回调与存活门
// 齐备，qrtransfer 目录零改动）。
//
// 平台差异挂账（详见任务报告）：ArkUI 无 middle 截断档（Ellipsis 近似）与
// URL 键盘档；栈承载形态下「离开 5 分钟清表单」的 isCurrentPage 逻辑不可达
// （页面退出即销毁），不落地。图标磁贴接线（T11）：点击弹 IconPickerSheet
// （T10 组件），完成回传动物/底色，名称未手动编辑时跟随动物本地化名。
// T12 收口：①root 查重降级（T8 挂账 I-1）——首 root 地址命中既有行星不再
// 拦截，弹告警（参数=冲突行星展示名）后继续导入；②add() 在途闸（T8 挂账
// M-1）——提交在途时按钮禁重复触发；③添加成功 pop 回首页（T8 挂账 concern 4
// 落位语义核：iOS 添加页在首页 Swiper 内嵌，成功即分页落到新行星——栈承载
// 形态下 selectPlanet→reload 已让 Swiper 落位，pop 揭示即 iOS 同款终态）。
import fs from '@ohos.file.fs';
import { curves } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { AppNav } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StoreRepo } from '../store/StoreRepo';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import {
  ImportError, PlanetImporter,
  PLANET_TYPE_BYTE, parsePlanetPayload, rootAddressOf, worldIdOf,
} from '../store/PlanetImporter';
import { PlanetProfile } from '../store/Models';
import { PlanetIcon, PlanetIconView } from '../components/PlanetIcon';
import { IconCatalog, L10n, l10nSignal } from '../components/L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { HomeMetrics } from '../components/HomeMetrics';
import { QRReceiveSheet } from '../qrtransfer/QRReceiveSheet';
import { IconPickerSheet } from '../components/IconPickerSheet';
import { AppAlert, AppAlertButton } from '../components/AppAlert';

/** 表单行字号（iOS .body 17）与脚注（iOS .footnote 13） */
const FS_BODY: number = 17;
const FS_FOOTNOTE: number = 13;
/** iOS .semibold → 600（ArkUI 无 Semibold 枚举档） */
const FW_SEMIBOLD: number = 600;
/** 进度模态高（iOS presentationDetents .height(180)） */
const PROGRESS_SHEET_HEIGHT: number = 180;
/** 表单入场位移（iOS offset 120 → 0）与延时（spring .delay(0.15)） */
const FORM_ENTRANCE_OFFSET: number = 120;
const FORM_ENTRANCE_DELAY_MS: number = 150;
/** toast 自动消失（iOS Task.sleep 2.5s）与底色（black 0.75） */
const TOAST_DURATION_MS: number = 2500;
const TOAST_BG: number = 0xBF000000;
/** 预览磁贴边长（iOS 72）与虚线卡圆角（iOS 16） */
const TILE_SIZE: number = 72;
const PREVIEW_RADIUS: number = 16;
/** 虚线边框色（iOS Color.secondary.opacity(0.35)：secondary 0.6 alpha × 0.35
 *  ≈ 0.21 → 0x36） */
const PREVIEW_DASH_COLOR_LIGHT: number = 0x363C3C43;
const PREVIEW_DASH_COLOR_DARK: number = 0x36EBEBF5;
/** iOS .quaternary 分层填充（ConfirmBubble 先例） */
const QUATERNARY_LIGHT: number = 0x243C3C43;
const QUATERNARY_DARK: number = 0x24EBEBF5;
/** 预览卡底（cardBg @0.5） */
const PREVIEW_BG_LIGHT: number = 0x80FFFFFF;
const PREVIEW_BG_DARK: number = 0x802C2C2E;
/** toast 转场（iOS .move(edge: .top) + .opacity 直译近似） */
const TOAST_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.translate({ y: -16 }))
  .animation({ duration: 250, curve: Curve.EaseOut });

/** 文件大小分级项（iOS locFileSize units 直译，十进制 KB=1000） */
interface FileSizeUnit {
  factor: number;
  unit: string;
}

/** 随机动物 key（本地化名与现有行星去重；候选全被占则全目录随机——iOS
 *  PlanetIcon.randomAnimal 直译。页面本地实现：PlanetIcon.ets 无此函数） */
function randomAnimalKey(exclude: Set<string>): string {
  const keys = IconCatalog.keys;
  const candidates = keys.filter((k: string): boolean =>
    !exclude.has(L10n.get('animal.' + k)));
  const pool = candidates.length === 0 ? keys : candidates;
  return pool[Math.floor(Math.random() * pool.length)];
}

/** http(s) 链接提取（iOS QRScannerView.swift:140 extractHttpUrl 直译）：trim
 *  → '://' 前段小写比对 scheme → 命中返回 trim 后原文，否则 null */
function extractHttpUrl(text: string): string | null {
  const t = text.trim();
  const sep = t.indexOf('://');
  if (sep <= 0) {
    return null;
  }
  const scheme = t.slice(0, sep).toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    return null;
  }
  return t;
}

@ComponentV2
export struct AddPlanetPage {
  /** 全局 UI 状态单例（行星表参与随机去重；添加成功后 reload） */
  @Local app: AppState = AppState.shared;
  /** 身份：动物 key + 底色 hex；名称未被手动编辑前跟随动物本地化名（iOS 同名） */
  @Local animal: string = IconCatalog.keys[0];
  @Local colorHex: string = PlanetIcon.randomColorHex();
  @Local previewName: string = '';
  @Local nameEditedByUser: boolean = false;
  /** URL 输入框内容（通道②④共享） */
  @Local url: string = '';
  /** 已就绪、等待「添加」的 planet 文件内容（四通道汇聚点） */
  @Local pendingData: Uint8Array | null = null;
  /** 下载中（= 进度模态显隐，iOS isPresented: $downloading）与进度 0~1/null */
  @Local downloading: boolean = false;
  @Local downloadProgress: number | null = null;
  /** 下载/验证失败轻提示（overlay 不受 sheet 收起竞争影响；'' = 隐藏） */
  @Local toast: string = '';
  /** 导入失败 alert 正文（iOS alert message；'' = 隐藏） */
  @Local alertMsg: string = '';
  /** root 查重告警显隐（T8 挂账 I-1 降级：不拦截，OK 后继续导入） */
  @Local rootConflictAlert: boolean = false;
  /** root 查重告警参数（冲突既有行星展示名） */
  @Local rootConflictName: string = '';
  /** root 告警已确认标记（同一份数据只告警一次；换数据重置） */
  private rootWarnAck: boolean = false;
  /** 添加提交在途（T8 挂账 M-1：await 窗口内按钮禁重复触发） */
  @Local adding: boolean = false;
  /** 扫码接收 sheet 显隐（通道③④宿主） */
  @Local showReceiver: boolean = false;
  /** 图标设置 sheet 显隐（T11 接线：磁贴点击弹 IconPickerSheet） */
  @Local showIconPicker: boolean = false;
  /** 表单入场动画状态（false = 下方 120vp 待入场） */
  @Local formShown: boolean = false;
  /** 主题/深浅色信号触踪锚（@Monitor 挂点；HomeView 同款范式） */
  @Local theme: ThemeSignal = themeSignal;
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 主题派生对勾成功色（已就绪字样用；初值取既有基线，applyTheme 修正） */
  @Local successColor: number = 0xFF009830;

  /** 导入编排（planet 解析/查重/落库/下载） */
  private importer: PlanetImporter = new PlanetImporter(StoreRepo.store);
  /** 主题管理器实例（异步单例；就绪后 applyTheme 派生成功色） */
  private themeRef: ThemeManager | null = null;
  private toastTimer: number = -1;
  private entranceTimer: number = -1;

  aboutToAppear(): void {
    // 每次进入重掷身份：未添加就离开视为放弃，下次进来重新随机（iOS onAppear）
    this.rollIdentity();
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.applyTheme();
    });
    // iOS withAnimation(.spring(0.4, 0.85).delay(0.15))：延时后弹簧入场
    this.entranceTimer = setTimeout(() => {
      this.getUIContext().animateTo(
        { curve: curves.springMotion(0.4, 0.85) },
        () => { this.formShown = true; });
    }, FORM_ENTRANCE_DELAY_MS);
  }

  aboutToDisappear(): void {
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
      this.entranceTimer = -1;
    }
    this.clearToastTimer();
  }

  /** 主题/深浅色变化 → 重算成功色（HomeView.applyTheme 同构） */
  @Monitor('theme.rev', 'cm.dark')
  applyTheme(): void {
    const t = this.themeRef;
    if (t === null) {
      return;
    }
    const raw = this.cm.dark ? t.successDarkHex() : t.successLightHex();
    this.successColor = raw > 0xFFFFFF ? raw : 0xFF000000 + raw;
  }

  // ---- 文案/派生域 ----

  /** L10n 查表 + rev 触踪（HomeView.loc 恒假分支惯用形） */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 带占位符查表，同 rev 触踪 */
  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.format(key, args);
  }

  /** 动物本地化名（iOS PlanetIcon.localizedName 直译） */
  private localizedName(key: string): string {
    return L10n.get('animal.' + key);
  }

  private trimmedName(): string {
    return this.previewName.trim();
  }

  /** canAdd：已就绪数据 + 名称齐备（iOS 同名计算属性直译） */
  private canAdd(): boolean {
    return this.pendingData !== null && this.trimmedName() !== '';
  }

  /** iOS .quaternary 分层填充（ConfirmBubble 先例色值） */
  private quaternary(): number {
    return this.cm.dark ? QUATERNARY_DARK : QUATERNARY_LIGHT;
  }

  /** 预览磁贴底色（"#RRGGBB" → 0xAARRGGBB；非法值灰兜底 = iOS Color(hex:) ?? .gray） */
  private iconTint(): number {
    const c = PlanetIcon.colorFromHex(this.colorHex);
    return c === null ? 0xFF808080 : c;
  }

  /** 文件大小展示（iOS locFileSize 直译：十进制分级 %.1f，不足 1KB 显 B） */
  private fileSizeText(bytes: number): string {
    const units: FileSizeUnit[] = [
      { factor: 1000000000000, unit: 'TB' },
      { factor: 1000000000, unit: 'GB' },
      { factor: 1000000, unit: 'MB' },
      { factor: 1000, unit: 'KB' },
    ];
    for (const u of units) {
      if (bytes >= u.factor) {
        return (Math.round((bytes / u.factor) * 10) / 10).toFixed(1) + ' ' + u.unit;
      }
    }
    return `${bytes} B`;
  }

  // ---- 身份域 ----

  /** 重掷身份：随机动物（本地化名与现有行星去重）+ 随机底色；名称未手动
   *  编辑过则跟随动物本地化名（iOS rollIdentity 直译） */
  private rollIdentity(): void {
    const used = new Set<string>();
    for (const p of this.app.planets) {
      used.add(p.name);
    }
    this.animal = randomAnimalKey(used);
    this.colorHex = PlanetIcon.randomColorHex();
    this.nameEditedByUser = false;
    this.previewName = this.localizedName(this.animal);
  }

  // ---- 通道①：文件 ----

  /** DocumentViewPicker 单选 → 读字节 → 头字节校验 → 就绪（iOS fileImporter
   *  直译：取消静默；读失败/校验失败进 alert） */
  private async pickFile(): Promise<void> {
    try {
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker().select(opts);
      if (uris.length === 0) {
        return; // 用户取消：静默
      }
      const data = await this.readUriBytes(uris[0]);
      if (data === null) {
        this.alertMsg = this.loc('error.moon.readFailed'); // 文件读取失败（iOS Data(contentsOf:) 抛错同位）
        return;
      }
      if (data.length === 0 || data[0] !== PLANET_TYPE_BYTE) {
        this.alertMsg = this.loc('error.planet.badHeader'); // iOS validate 直译
        return;
      }
      this.pendingData = data;
      this.rootWarnAck = false; // 换数据：root 告警确认标记重置
    } catch (_e) {
      // 选择器通路异常（iOS fileImporter failure 分支同位 → alert）
      this.alertMsg = this.loc('error.moon.readFailed');
    }
  }

  /** 选择器 URI → 恰长字节；失败 null（picker URI 无需额外授权，fs 直开） */
  private async readUriBytes(uri: string): Promise<Uint8Array | null> {
    let fd = -1;
    try {
      const f = await fs.open(uri, fs.OpenMode.READ_ONLY);
      fd = f.fd;
      const st = await fs.stat(fd);
      const size = st.size;
      if (size <= 0) {
        return new Uint8Array(0);
      }
      const ab = new ArrayBuffer(size);
      const n = await fs.read(fd, ab, { offset: 0, length: size });
      return new Uint8Array(ab.slice(0, n));
    } catch (_e) {
      return null;
    } finally {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
    }
  }

  // ---- 通道②：URL ----

  /** URL 下载 → 校验 → 就绪（iOS importFromURL 直译）：进度模态随 downloading
   *  显隐，失败/校验不过走 toast（不走 alert——iOS 刻意区分） */
  private importFromURL(): void {
    const target = this.url.trim();
    if (this.downloading || target === '') {
      return;
    }
    this.downloading = true;
    this.downloadProgress = null;
    this.importer.downloadPlanetFile(target, (fraction: number | null) => {
      this.downloadProgress = fraction;
    }).then((data: Uint8Array) => {
      this.downloading = false;
      if (data.length === 0 || data[0] !== PLANET_TYPE_BYTE) {
        this.showToast(this.loc('error.planet.badHeader')); // iOS validate → toast
        return;
      }
      this.pendingData = data;
      this.rootWarnAck = false; // 换数据：root 告警确认标记重置
    }).catch((e: Object) => {
      this.downloading = false;
      // ImportError（downloadFailed/tooLarge）按文案键提示；网络栈杂散异常
      // 兜底通用导入失败文案（iOS error.localizedDescription 同位）
      this.showToast(e instanceof ImportError
        ? this.loc((e as ImportError).locKey)
        : this.loc('addplanet.importFailed'));
    });
  }

  /** toast 展示 2.5s 自动消失（iOS .task(id: toast) 直译；重复触发重置计时） */
  private showToast(text: string): void {
    this.clearToastTimer();
    this.toast = text;
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.clearToastTimer();
    }, TOAST_DURATION_MS);
  }

  private clearToastTimer(): void {
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  // ---- 通道③④：扫码接收 ----

  /** 分片聚合完成（iOS QRReceiveView onComplete 直译）：关扫码层 → ZTP 容器
   *  解析 → 头字节校验 → 数据 + 名称/图标/底色预填（不直接落库） */
  private onReceiveComplete(data: Uint8Array): void {
    this.showReceiver = false;
    // 非法容器（magic/边界不成立、缺 planet 字段）或旧版裸 planet 载荷都走
    // 统一「数据无效」提示（iOS 直译）
    const payload = parsePlanetPayload(data);
    if (payload === null) {
      this.alertMsg = this.loc('addplanet.qrInvalid');
      return;
    }
    if (payload.planet.length === 0 || payload.planet[0] !== PLANET_TYPE_BYTE) {
      this.alertMsg = this.loc('error.planet.badHeader'); // iOS validate → alert
      return;
    }
    this.pendingData = payload.planet;
    this.rootWarnAck = false; // 换数据：root 告警确认标记重置
    if (payload.name !== null && payload.name !== '') {
      this.previewName = payload.name;
      // iOS onChange(of: previewName) 对程序化赋值同样触发：与当前动物本地化
      // 名不同即视为「已手动编辑」（后续 rollIdentity 不再覆盖该名称）
      if (payload.name !== this.localizedName(this.animal)) {
        this.nameEditedByUser = true;
      }
    }
    if (payload.icon !== null) {
      this.animal = payload.icon;
    }
    if (payload.iconColor !== null) {
      this.colorHex = payload.iconColor;
    }
  }

  /** 非分片帧（iOS onPlainFrame 直译）：扫到 http(s) 链接二维码 → 关扫码层 →
   *  回填 URL → 直接下载导入；返回 true 表示已消费、扫码结束 */
  private onPlainFrame(text: string): boolean {
    const scanned = extractHttpUrl(text);
    if (scanned === null) {
      return false;
    }
    this.showReceiver = false;
    this.url = scanned;
    this.importFromURL();
    return true;
  }

  // ---- 主操作 ----

  /**
   * 添加（iOS add() 直译 + #8 节点地址扩展查重 + T8 挂账收口）：在途闸 →
   * World ID 查重（阻断，iOS 直译）→ 首 root 节点地址查重（T8 挂账 I-1 降级：
   * 命中仅告警、OK 后继续导入）→ importPlanetData 落库 → 清表单 → 选中 +
   * reload → pop 回首页（concern 4 落位语义，见文件头）。
   */
  private async add(): Promise<void> {
    if (this.adding) {
      return; // T8 挂账 M-1 在途闸
    }
    const data = this.pendingData;
    if (data === null || this.trimmedName() === '') {
      return;
    }
    this.adding = true;
    try {
      const worldId = worldIdOf(data);
      if (worldId !== null) {
        const owners = await this.importer.worldIdOwners();
        const owner = owners.get(worldId);
        if (owner !== undefined) {
          this.alertMsg = this.locFmt('addplanet.duplicate %@', [this.displayNameOf(owner)]);
          return;
        }
      }
      const addr = rootAddressOf(data);
      if (addr !== null && !this.rootWarnAck) {
        const owners = await this.importer.existingRootAddresses();
        const owner = owners.get(addr);
        if (owner !== undefined) {
          // 告警可继续（不拦）：无取消路径，OK 后带确认标记重入导入
          this.rootConflictName = this.displayNameOf(owner);
          this.rootConflictAlert = true;
          return;
        }
      }
      await this.importPlanet(data);
    } finally {
      this.adding = false;
    }
  }

  /** 行星展示名：官方行星走本地化名（HomeView.displayNameOf 同构；root 告警
   *  参数用——官方行星无 .planet 文件、天然不入查重集合，仅防御性兜底） */
  private displayNameOf(planet: PlanetProfile): string {
    return planet.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name')
      : planet.name;
  }

  /** 落库编排（原 add() 后段拆出）：导入 → 清表单 → 选中 + reload → pop 回首页 */
  private async importPlanet(data: Uint8Array): Promise<void> {
    try {
      const profile = await this.importer.importPlanetData(data, this.trimmedName(),
        this.animal, this.colorHex);
      this.pendingData = null;
      this.url = '';
      this.rootWarnAck = false;
      // iOS onImported: reloadConfig + selectPlanet；鸿蒙 store.selectPlanet 是
      // 静默写，先选后 reload——reload 读回 selectedPlanetId 驱动首页 Swiper
      // 落位到新行星（iOS pagerSelection 绑定同效）
      await StoreRepo.store.selectPlanet(profile.id);
      await AppState.shared.reload();
      // T8 挂账 concern 4：iOS 添加成功分页即落到新行星（添加页是首页 Swiper
      // 末位）——栈承载形态 pop 回首页揭示已落位的新行星页；身份重掷由下次
      // 进页 aboutToAppear 承担（本页随即销毁，无需原地重掷）
      AppNav.pop();
    } catch (e) {
      this.alertMsg = e instanceof ImportError
        ? this.loc((e as ImportError).locKey)
        : this.loc('addplanet.importFailed');
    }
  }

  // ---- 渲染 ----

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column({ space: 14 }) {
          // 身份预览区（iOS .padding(.horizontal, 20).padding(.top, 4)）
          Column() {
            this.previewIdentity()
          }
          .width('100%')
          .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE, top: 4 })

          // 标题 + 副指引（iOS header 直译）
          Column() {
            this.header()
          }
          .width('100%')
          .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })

          // 表单区（入场动画 + toast overlay + 扫码 sheet 宿主）
          this.formZone()
        }
        .width('100%')
        .padding({ top: HomeMetrics.pageTopPadding, bottom: 96 }) // iOS .padding(.bottom, 96)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)

      // 导入失败 alert（iOS .alert(addplanet.importFailed) 直译）：AppAlert
      // 宿主（遮罩/卡片转场内部自持，宿主只管 if 出入）
      if (this.alertMsg !== '') {
        AppAlert({
          title: this.loc('addplanet.importFailed'),
          message: this.alertMsg,
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.alertMsg = '';
          })],
        })
      }

      // root 查重告警（T8 挂账 I-1 降级：无取消路径 = 不拦截，OK 后带确认
      // 标记重入 add() 继续导入）
      if (this.rootConflictAlert) {
        AppAlert({
          title: this.loc('addplanet.rootConflictTitle'),
          message: this.locFmt('addplanet.rootConflictMessage %@',
            [this.rootConflictName]),
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.rootConflictAlert = false;
            this.rootWarnAck = true;
            void this.add();
          })],
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
    // 下载进度模态（iOS .sheet(downloading) + presentationDetents(.height(180))
    // + interactiveDismissDisabled 直译）：onWillDismiss 空实现拦截下滑/点外
    // 关闭，收起只走 downloading = false 的程序化路径
    .bindSheet(this.downloading, (): void => {
      this.progressSheet()
    }, {
      height: PROGRESS_SHEET_HEIGHT,
      dragBar: false,
      showClose: false,
      backgroundColor: DesignTokens.cardBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        // interactiveDismissDisabled：下载中禁止手势关闭
      },
    })
  }

  /** 身份预览区：72pt 磁贴 + 行内名称 + 随机按钮，maxWidth 260，虚线边框 =
   *  「尚未创建」占位形态（iOS previewIdentity 直译） */
  @Builder
  previewIdentity() {
    Column({ space: 12 }) {
      // 图标磁贴（点击弹图标设置——T10 组件接线，iOS showIconPicker 直译）
      Column() {
        PlanetIconView(this.animal, this.iconTint(), TILE_SIZE)
      }
      .accessibilityText(this.loc('common.icon'))
      .onClick((): void => {
        this.showIconPicker = true;
      })
      // 图标设置 sheet（iOS .sheet(isPresented: $showIconPicker) 直译）：完成
      // 回传动物/底色；名称未被手动编辑过则跟随新动物本地化名
      // （iOS AddPlanetPage syncNameWithAnimal 直译）
      .bindSheet(this.showIconPicker, (): void => {
        IconPickerSheet({
          animal: this.animal,
          color: this.colorHex,
          onSelect: (animal: string, colorHex: string): void => {
            this.animal = animal;
            this.colorHex = colorHex;
            if (!this.nameEditedByUser) {
              this.previewName = this.localizedName(animal);
            }
          },
          onClose: (): void => {
            this.showIconPicker = false;
          },
        })
      }, {
        height: SheetSize.LARGE,
        showClose: false,
        backgroundColor: DesignTokens.pageBg(this.cm.dark),
        onWillDismiss: (_action: DismissSheetAction): void => {
          this.showIconPicker = false;
        },
      })

      Row({ space: 8 }) {
        TextInput({ text: this.previewName, placeholder: this.loc('addplanet.namePlaceholder') })
          .fontSize(DesignTokens.FS_ROW_TITLE)
          .fontWeight(FW_SEMIBOLD)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
          .textAlign(TextAlign.Center)
          .enterKeyType(EnterKeyType.Done)
          .backgroundColor(this.quaternary())
          .borderRadius(DesignTokens.RADIUS_SM)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .layoutWeight(1)
          .onChange((v: string) => {
            if (v === this.previewName) {
              return; // 程序化赋值回声（rollIdentity/ZTP 预填已自管编辑标记）
            }
            this.previewName = v;
            // iOS onChange(of: previewName)：与当前动物本地化名不同 = 手动编辑
            if (v !== this.localizedName(this.animal)) {
              this.nameEditedByUser = true;
            }
          })
        Column() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(FS_BODY)
            .fontColor([DesignTokens.textPrimary(this.cm.dark)])
        }
        .width(38)
        .height(38)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.quaternary())
        .borderRadius(DesignTokens.RADIUS_SM)
        .onClick(() => this.rollIdentity())
        .accessibilityText(this.loc('addplanet.randomIcon'))
      }
      .width('100%')
      .constraintSize({ maxWidth: 260 })
    }
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .padding(14)
    .backgroundColor(this.cm.dark ? PREVIEW_BG_DARK : PREVIEW_BG_LIGHT)
    .borderRadius(PREVIEW_RADIUS)
    .border({
      width: 1.5,
      color: this.cm.dark ? PREVIEW_DASH_COLOR_DARK : PREVIEW_DASH_COLOR_LIGHT,
      style: BorderStyle.Dashed, // iOS dash [6,4]：ArkUI 无步距参数，Dashed 近似
    })
  }

  /** 标题区：headline 主标题 + footnote 副指引（iOS header 直译） */
  @Builder
  header() {
    Column({ space: 4 }) {
      Text(this.loc('planet.add.title'))
        .fontSize(17)
        .fontWeight(FW_SEMIBOLD)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Text(this.loc('addplanet.subtitle'))
        .fontSize(FS_FOOTNOTE)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 表单区（iOS AddPlanetForm body 直译）：表单卡 + 添加按钮 + toast overlay；
   *  入场动画挂整区（offset 120→0 + opacity）；扫码 sheet 挂本节点（与页根
   *  进度模态分挂，规避同组件多 bindSheet 冲突） */
  @Builder
  formZone() {
    Stack({ alignContent: Alignment.Top }) {
      Column({ space: 16 }) {
        this.formCard()
        // 添加按钮（iOS addButton 直译：宽 84%（左右各 8%）+ 顶距 20）
        Column() {
          Text(this.loc('addplanet.action'))
            .fontSize(16)
            .fontWeight(FW_SEMIBOLD)
            .fontColor(0xFFFFFFFF)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .backgroundColor(themeSignal.accent)
            .borderRadius(DesignTokens.RADIUS_CARD)
            .opacity(this.canAdd() && !this.adding ? 1 : 0.4)
            .onClick(() => {
              if (this.canAdd() && !this.adding) {
                void this.add();
              }
            })
        }
        .width('100%')
        .padding({ left: '8%', right: '8%', top: 20 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 下载/验证失败 toast：顶部胶囊 2.5s 自动消失（iOS overlay(.top) 直译）
      if (this.toast !== '') {
        Row() {
          Text(this.toast)
            .fontSize(FS_FOOTNOTE)
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .backgroundColor(TOAST_BG)
            .borderRadius(100) // Capsule
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 24, right: 24, top: 4 })
        .transition(TOAST_TRANSITION)
      }
    }
    .width('100%')
    .padding({ left: DesignTokens.MARGIN_PAGE, right: DesignTokens.MARGIN_PAGE })
    .translate({ y: this.formShown ? 0 : FORM_ENTRANCE_OFFSET })
    .opacity(this.formShown ? 1 : 0)
    // 扫码接收 sheet（iOS .sheet(showPlanetReceiver) 直译）：同一扫码层自动
    // 识别链接二维码（onPlainFrame）与动态分片（onComplete）
    .bindSheet(this.showReceiver, (): void => {
      QRReceiveSheet({
        onComplete: (data: Uint8Array): void => this.onReceiveComplete(data),
        onPlainFrame: (text: string): boolean => this.onPlainFrame(text),
        onClose: (): void => {
          this.showReceiver = false;
        },
      })
    }, {
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false,
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showReceiver = false; // 下滑/点外关闭（iOS sheet 默认可交互关闭）
      },
    })
  }

  /** 表单卡（iOS formCard 直译）：选文件/扫二维码/URL 三行，padding 18、
   *  圆角 20、行距 14 */
  @Builder
  formCard() {
    Column({ space: 14 }) {
      // 选择文件行：整块（含背景）为点击热区；就绪态显成功色文件大小
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.doc'))
          .fontSize(FS_BODY)
          .fontColor([DesignTokens.textPrimary(this.cm.dark)])
        Text(this.loc('addplanet.chooseFile'))
          .fontSize(FS_BODY)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
        Blank()
        if (this.pendingData !== null) {
          Text(this.locFmt('addplanet.ready %@',
            [this.fileSizeText(this.pendingData.byteLength)]))
            .fontSize(DesignTokens.FS_CAPTION)
            .fontColor(this.successColor)
        } else {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(DesignTokens.FS_CAPTION)
            .fontColor([DesignTokens.textTertiary(this.cm.dark)])
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .backgroundColor(this.quaternary())
      .borderRadius(DesignTokens.RADIUS_SM)
      .onClick(() => void this.pickFile())

      // 扫二维码导入行（下载中禁用 = iOS .disabled(downloading)）
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.qrcode'))
          .fontSize(FS_BODY)
          .fontColor([DesignTokens.textPrimary(this.cm.dark)])
        Text(this.loc('addplanet.scanImport'))
          .fontSize(FS_BODY)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
        Blank()
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.quaternary())
      .borderRadius(DesignTokens.RADIUS_SM)
      .onClick(() => {
        if (!this.downloading) {
          this.showReceiver = true;
        }
      })

      // URL 行：输入框左（link 图标 + 输入），导入按钮右（56×42；下载中显转圈）
      Row({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(FS_BODY)
            .fontColor([DesignTokens.textPrimary(this.cm.dark)])
          TextInput({ text: this.url, placeholder: this.loc('addplanet.urlPlaceholder') })
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
            .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
            .enterKeyType(EnterKeyType.Done)
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 0, top: 0, bottom: 0 })
            .layoutWeight(1)
            .onChange((v: string) => {
              this.url = v;
            })
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 11, bottom: 11 })
        .backgroundColor(this.quaternary())
        .borderRadius(DesignTokens.RADIUS_SM)

        Column() {
          if (this.downloading) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(themeSignal.accent)
          } else {
            Text(this.loc('common.import'))
              .fontSize(DesignTokens.FS_ROW_TITLE)
              .fontWeight(FW_SEMIBOLD)
              .fontColor(DesignTokens.textPrimary(this.cm.dark))
          }
        }
        .width(56)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.quaternary())
        .borderRadius(DesignTokens.RADIUS_SM)
        .onClick(() => this.importFromURL())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(18)
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_LG)
    .alignItems(HorizontalAlign.Start)
  }

  /** 进度模态内容（iOS downloading sheet 直译）：spacing 16 + padding 24；
   *  Content-Length 已知 → linear 进度 / 未知 → 转圈；URL 行单行省略截断 */
  @Builder
  progressSheet() {
    Column({ space: 16 }) {
      if (this.downloadProgress !== null) {
        Progress({ value: Math.round(this.downloadProgress * 100), total: 100,
          type: ProgressType.Linear })
          .width('100%')
          .color(themeSignal.accent)
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(themeSignal.accent)
      }
      Text(this.loc('addplanet.downloading'))
        .fontSize(DesignTokens.FS_ROW_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Text(this.url)
        .fontSize(FS_FOOTNOTE)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
        .maxLines(1)
        // iOS .truncationMode(.middle)：ArkUI 无 middle 档，Ellipsis 近似（偏差记档）
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
