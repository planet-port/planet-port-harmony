// PrefsView.ets — 全局设置页（iOS PrefsView.swift 505 行直译）
//
// 六段（spec 功能表 #12/#16/#29/#30/#31/#35，brief 段序）：
//   ①网络（禁用 IPv6 toggle → restartIfRunning；多连接上限 stepper 2..6）
//   ②节点身份（共享/每行星独立：独立需 alert 确认「互不可关联」；共享候选选择；
//     切换编排 iOS AppState.switchIdentityMode 直译——prefs 落盘 → seed/adopt
//     → notifyIdentityChanged → AppState.reload → **TunnelController.restartIfRunning
//     显式换代**，绝不静默）
//   ③语言（跟随系统/三语 Picker；LanguageManager.set 落盘后 L10n.notify 广播）
//   ④主题色入口（弹层：示例色块 120 圆角 20 + 随机动物 64 / 8 预设圆点 32 白环 2 /
//     HSL 取色器 / 状态色派生开关）
//   ⑤外观（背景图选择/清除 + 缩略图；视差 toggle 无图禁用）
//   ⑥关于（版本 / 构建时间（点击切 git hash [dirty]）/ ZeroTier Core）
//   + 支持区 `if (false)` 隐藏不删（iOS :141-155 直译）+ 商标保护 dormant 校验
//   （BrandGuard，消费点在行星导入路径，A5 不启用）。
//
// 平台差异（偏差清单见 .superpowers/sdd/task-10-report.md）：
//   - 连接超时 45s（#16）是 iOS AppState 运行时常量，非三平台 AppPrefs 字段
//     （D12 字节兼容红线，禁自拟落盘键）——不渲染设置行；
//   - On Demand 段（prefs.ondemand）不渲染：Android 金标有应用侧实现
//     （PrefsView.kt toggle + PrefsViewModel 开启即拉起 + 启动自恢复），鸿蒙
//     缺「启动自恢复」消费点接线，渲染死开关反而失真——AppPrefs.connectOnDemand
//     字段保留，接线挂账 A6/后续；
//   - 行星装饰盘开关（brief ④）：iOS/Android 金标主题弹层均无此开关且 AppPrefs
//     无对应字段——不自拟 schema，不渲染。
// 弹层宿主：单 bindSheet + SheetKind 判别分发（同节点多 bindSheet 有覆盖风险）；
// 身份确认 alert 走 AppAlert 宿主层（JoinNetworkSheet 同范式）。
// 主题弹层预览域：ThemeManager 无逐帧写 API（禁改本体），弹层自持 mainHex
// （拖动/预设只改预览域即时反映示例块与色盘），抬手/点预设才经
// ThemeManager.setMainColor 落盘发布（预设 custom=false 清 themeColorCustom，
// 自定义 custom=true——Android PrefsViewModel preview/commit 两段范式直译）。
import { bundleManager } from '@kit.AbilityKit';
import { AppNav } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { PlanetProfile } from '../store/Models';
import { StoreRepo } from '../store/StoreRepo';
import { IdentityStore } from '../store/IdentityStore';
import { LanguageManager, AppLanguage, nativeName } from '../store/LanguageManager';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import { TunnelController } from '../tunnel/TunnelController';
import { CoreRuntime, ColorMath } from '../common/CoreRuntime';
import { BackgroundImageStore, backgroundImageSignal, BackgroundImageSignal } from '../store/BackgroundImageStore';
import { L10n, l10nSignal, IconCatalog } from '../components/L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { AppAlert, AppAlertButton } from '../components/AppAlert';
import { PlanetIcon } from '../components/PlanetIcon';
import { HSLColorPicker } from '../components/HSLColorPicker';
import { BackgroundImagePickerSheet } from '../components/BackgroundImagePickerSheet';
// IconPickerSheet 归 PlanetSettings（T11）消费，本页不引用；其全量编译验证已在
// 上一步以临时 probe import 完成（BUILD SUCCESSFUL 后移除，无引用方组件不产目标）

/** 表单字号（iOS .body 17 / .caption 12 / .caption2 11 / .footnote 13） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_SECTION_HEADER: number = 11;
const FS_FOOTNOTE: number = 13;
/** 表单行高（iOS Form 行标准 44pt） */
const ROW_HEIGHT: number = 44;
/** 表单区水平边距 / 区间距（iOS Form grouped inset 直译） */
const FORM_MARGIN: number = DesignTokens.MARGIN_PAGE;
const FORM_SECTION_GAP: number = 20;
/** 多连接上限步进域（iOS Stepper in: 2...6） */
const NET_LIMIT_MIN: number = 2;
const NET_LIMIT_MAX: number = 6;
/** 主题弹层示例色块（iOS 120 圆角 20 内动物 64）与预设圆点（iOS 32 白环 2） */
const SAMPLE_SIZE: number = 120;
const SAMPLE_RADIUS: number = 20;
const SAMPLE_ANIMAL: number = 64;
const SWATCH_RING_INSET: number = 2;
const SWATCH_RING_WIDTH: number = 2;
/** 主题入口圆点（iOS 24）/ 背景缩略图（iOS 28 圆角 6）/ 身份行磁贴（iOS 24 圆角 7 内 14） */
const DOT_SIZE: number = 24;
const THUMB_SIZE: number = 28;
const THUMB_RADIUS: number = 6;
const PICK_TILE_SIZE: number = 24;
const PICK_TILE_RADIUS: number = 7;
const PICK_TILE_CONTENT: number = 14;

/** 弹层种类（SheetKind 判别分发；'none' = 关闭） */
type SheetKind = 'none' | 'theme' | 'identity' | 'identityPick' | 'language' | 'background';

/** 共享身份候选（iOS IdentityPickView candidates + 地址投影直译） */
interface PlanetCandidate {
  planet: PlanetProfile;
  address: string | null;
}

/** 预设色名 i18n 键（iOS ThemeManager.presetNames 逐序直译，a11y 消费） */
const PRESET_NAME_KEYS: string[] = [
  'theme.preset.defaultRed',
  'theme.preset.gamboge',
  'theme.preset.bamboo',
  'theme.preset.malachite',
  'theme.preset.ultramarine',
  'theme.preset.indigo',
  'theme.preset.dark',
  'theme.preset.carmine',
];

/** 语言选项序（iOS AppLanguage.allCases 源序；nativeName null 的 system 单列） */
const LANGUAGE_OPTIONS: AppLanguage[] = [
  AppLanguage.System,
  AppLanguage.ZhHans,
  AppLanguage.ZhHant,
  AppLanguage.En,
];

/**
 * 构建信息（iOS Generated/BuildInfo.swift 直译位）：hvigor 无 RunScript 注入
 * 惯例，先静态占位可显示（空值显示 '—'），A6 CI 注入真实时间戳与 git 短 hash。
 */
class BuildInfo {
  static readonly time: string = '';
  static readonly hash: string = '';
  static readonly dirty: boolean = false;
}

/**
 * 商标保护校验（#35「默认隐藏」；iOS PlanetImporter.swift containsReservedBrand
 * 注释态直译）：名称不得包含 ZeroTier 及其变体（不区分大小写），
 * "ZeroTier One"/"Zero Tier One" 分别被 "zerotier"/"zero tier" 前缀覆盖。
 * 消费点在行星导入路径（AddPlanetPage 等，T8/T11 领地）——A5 设置页不启用，
 * 按「隐藏 ≠ 删除」保留实现与文案键（error.planet.reservedName 已入三语表），
 * 启用时于导入校验处调用。
 */
export class BrandGuard {
  static containsReservedBrand(name: string): boolean {
    const lower = name.toLowerCase();
    return lower.includes('zerotier') || lower.includes('zero tier');
  }
}

/** 0xRRGGBB（ColorMath/prefs 域）→ 0xAARRGGBB（ArkUI 渲染域） */
function rgbToArgb(hex: number): number {
  return 0xFF000000 + hex;
}

/** '#rrggbb'（PlanetIcon.hslToHex 出口）→ 0xRRGGBB（prefs/ColorMath 域） */
function rgbFromHex(hex: string): number {
  return parseInt(hex.slice(1), 16);
}

@ComponentV2
export struct PrefsView {
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 主题信号触踪锚（入口圆点/弹层 accent 即时重组） */
  @Local theme: ThemeSignal = themeSignal;
  /** 背景图信号（缩略图 + 视差门控同源；@Trace 字段 build 内读即追踪） */
  @Local bgSignal: BackgroundImageSignal = backgroundImageSignal;

  // ---- prefs 镜像（进入页读一次 + 弹层应用后回读） ----
  @Local disableIpv6: boolean = false;
  @Local maxNetworks: number = NET_LIMIT_MIN;
  @Local identityPerPlanet: boolean = false;
  @Local parallax: boolean = true;
  @Local hasBgPrefs: boolean = false;
  /** 当前语言（LanguageManager 内存态镜像） */
  @Local language: AppLanguage = AppLanguage.System;

  // ---- 主题弹层（预览域 + 派生开关 + 行星色盘） ----
  private themeRef: ThemeManager | null = null;
  @Local themeMainHex: number = 0xD44037;
  @Local derive: boolean = false;
  @Local tints: number[] = [];
  /** 示例色块随机动物（每次打开弹层随机换一只，iOS onAppear 直译） */
  @Local themeAnimal: string = IconCatalog.keys[0];

  // ---- 弹层宿主 ----
  @Local sheet: SheetKind = 'none';
  /** 切独立身份确认 alert（iOS alert(isPresented: $confirmPerPlanet) 直译） */
  @Local identityConfirm: boolean = false;
  /** 共享身份候选（切共享时查询；identityPick 弹层消费） */
  @Local candidates: PlanetCandidate[] = [];

  // ---- 关于段 ----
  @Local versionText: string = '—';
  /** 核心版本（空显示 common.unknown，iOS 直译） */
  @Local coreVersion: string = '';
  /** 构建信息行当前显示 hash（false 显示时间，iOS 直译） */
  @Local buildInfoShowsHash: boolean = false;

  aboutToAppear(): void {
    this.language = LanguageManager.current();
    void this.reloadPrefs();
    void BackgroundImageStore.refresh(); // 背景图缩略图真值装载（文件→位图→信号）
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.themeMainHex = t.mainHex;
      this.derive = t.deriveStatusColor;
      this.tints = t.planetTintsHex();
    });
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const short = info.versionName === '' ? '—' : info.versionName;
    this.versionText = info.versionCode > 0 ? `${short} (${info.versionCode})` : short;
    this.coreVersion = CoreRuntime.getCoreVersion();
  }

  // ---- 数据 ----

  private async reloadPrefs(): Promise<void> {
    const p = await StoreRepo.store.readPrefs();
    this.disableIpv6 = p.disableIpv6;
    this.maxNetworks = Math.min(Math.max(Math.round(p.maxNetworks), NET_LIMIT_MIN), NET_LIMIT_MAX);
    this.identityPerPlanet = p.identityPerPlanet;
    this.parallax = p.parallax;
    this.hasBgPrefs = p.backgroundImage;
  }

  /** 背景图是否已设置（Android 走查修复直译：盘面位图或偏好布尔任一为真） */
  private hasBgImage(): boolean {
    return this.bgSignal.pixelMap !== null || this.hasBgPrefs;
  }

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

  /** 行星显示名（HomeView.displayNameOf 直译：官方行星走 i18n 键） */
  private displayNameOf(planet: PlanetProfile): string {
    return planet.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name') : planet.name;
  }

  // ---- ① 网络 ----

  /** 禁用 IPv6：落盘 → 显式重启在跑隧道（iOS VPNManager.restartIfRunning 直译） */
  private async setDisableIpv6(on: boolean): Promise<void> {
    this.disableIpv6 = on;
    await StoreRepo.store.writePrefs(p => {
      p.disableIpv6 = on;
      return p;
    });
    await TunnelController.restartIfRunning();
  }

  /** 多连接上限：落盘（下次起隧道生效，iOS/Android 同语义——无重启编排） */
  private async setMaxNetworks(v: number): Promise<void> {
    const clamped = Math.min(Math.max(Math.round(v), NET_LIMIT_MIN), NET_LIMIT_MAX);
    this.maxNetworks = clamped;
    await StoreRepo.store.writePrefs(p => {
      p.maxNetworks = clamped;
      return p;
    });
  }

  // ---- ② 节点身份（终审挂账红线：显式换代，绝不静默） ----

  /**
   * 切换身份模式（iOS AppState.switchIdentityMode 直译）：prefs 落盘 →
   * seedSharedIdentity（to=true，共享身份播种到活跃行星）/ adoptSharedIdentity
   * （to=false 且指定候选，行星身份收编为共享）→ notifyIdentityChanged →
   * AppState.reload → TunnelController.restartIfRunning 显式换代。
   */
  private async switchIdentityMode(perPlanet: boolean, adopting: string | null): Promise<void> {
    const store = StoreRepo.store;
    await store.writePrefs(p => {
      p.identityPerPlanet = perPlanet;
      return p;
    });
    this.identityPerPlanet = perPlanet;
    const activeId = await store.activePlanetId();
    if (perPlanet) {
      await IdentityStore.seedSharedIdentity(store.paths, activeId);
    } else if (adopting !== null) {
      await IdentityStore.adoptSharedIdentity(store.paths, adopting);
    }
    store.notifyIdentityChanged();
    await AppState.shared.reload();
    await TunnelController.restartIfRunning();
  }

  /** 已生成独立身份的行星（切共享候选；地址取自 identity.public，iOS 直译） */
  private async sharedIdentityCandidates(): Promise<PlanetCandidate[]> {
    const store = StoreRepo.store;
    const planets = await store.readPlanets();
    const out: PlanetCandidate[] = [];
    for (const p of planets) {
      if (await IdentityStore.hasPlanetIdentity(store.paths, p.id)) {
        const c: PlanetCandidate = {
          planet: p,
          address: await IdentityStore.planetIdentityAddress(store.paths, p.id),
        };
        out.push(c);
      }
    }
    return out;
  }

  /**
   * 模式选择分发（iOS IdentityModeSheet 行为直译）：切独立 → 关层 + alert 确认；
   * 切共享 → 无候选直接切换（保持现共享身份），有候选进选择层。
   */
  private async onIdentityModeSelect(target: boolean): Promise<void> {
    if (target === this.identityPerPlanet) {
      this.sheet = 'none';
      return;
    }
    if (target) {
      this.sheet = 'none';
      this.identityConfirm = true;
      return;
    }
    const cands = await this.sharedIdentityCandidates();
    if (cands.length === 0) {
      this.sheet = 'none';
      await this.switchIdentityMode(false, null);
    } else {
      this.candidates = cands;
      this.sheet = 'identityPick';
    }
  }

  // ---- ③ 语言 ----

  /** 语言切换：落盘 + L10n.notify 广播（LanguageManager.set 不自发通知） */
  private async onLanguageSelect(l: AppLanguage): Promise<void> {
    this.language = l;
    await LanguageManager.set(l);
    L10n.notify();
    this.sheet = 'none'; // 选完即回层（iOS Picker 选完菜单收起 / Android 选完即回同语义）
  }

  // ---- ④ 主题 ----

  /** 打开主题弹层：预览域对齐落盘真值 + 随机动物（iOS onAppear 直译） */
  private openThemeSheet(): void {
    const t = this.themeRef;
    if (t !== null) {
      this.themeMainHex = t.mainHex;
      this.derive = t.deriveStatusColor;
    }
    this.themeAnimal =
      IconCatalog.keys[Math.floor(Math.random() * IconCatalog.keys.length)];
    this.sheet = 'theme';
  }

  /** 取色拖动/点选即时预览（只改预览域，不落盘——见文件头预览域裁决） */
  private onThemePreview(hex: number): void {
    this.themeMainHex = hex;
  }

  /** 抬手/点预设落盘发布（预设 custom=false 清自定义位，自定义 custom=true） */
  private onThemeCommit(hex: number, custom: boolean): void {
    this.themeMainHex = hex;
    const t = this.themeRef;
    if (t !== null) {
      void t.setMainColor(hex, custom);
      this.tints = t.planetTintsHex();
    }
  }

  private onDeriveChange(on: boolean): void {
    this.derive = on;
    const t = this.themeRef;
    if (t !== null) {
      void t.setDeriveStatusColor(on);
    }
  }

  // ---- ⑤ 外观 ----

  /** 视差开关：内存态即时生效（syncParallax）+ 落盘（Android 直译） */
  private async setParallax(on: boolean): Promise<void> {
    this.parallax = on;
    BackgroundImageStore.syncParallax(on); // 内存态即时，不等待落盘（Android 同语义）
    try {
      await StoreRepo.store.writePrefs(p => {
        p.parallax = on;
        return p;
      });
    } catch (_e) {
      // 落盘失败静默：内存态已生效，下次 toggle / 进入页回读再收敛（全文件同风格）
    }
  }

  /** 背景图应用/清除后：关层 + 偏好与缩略图回读 */
  private onBackgroundApplied(): void {
    this.sheet = 'none';
    void this.reloadPrefs();
    void BackgroundImageStore.refresh();
  }

  // ---- 渲染 ----

  build() {
    Stack() {
      Column() {
        this.titleBar()
        Scroll() {
          Column({ space: FORM_SECTION_GAP }) {
            this.networkSection()
            this.identitySection()
            this.languageSection()
            this.themeSection()
            this.appearanceSection()
            this.aboutSection()
            // 支持区暂隐藏（内容待补充），代码保留（iOS :141-155 直译）
            if (false) {
              this.supportSection()
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

      // 切独立身份确认 alert（iOS .alert 直译：AppAlert 宿主层挂载）
      if (this.identityConfirm) {
        AppAlert({
          title: this.loc('prefs.identity.perPlanet.confirmTitle'),
          message: this.loc('prefs.identity.perPlanet.confirmMessage'),
          buttons: [
            new AppAlertButton(this.loc('prefs.identity.perPlanet.confirmAction'), false,
              (): void => {
                this.identityConfirm = false;
                void this.switchIdentityMode(true, null);
              }),
            new AppAlertButton(this.loc('common.cancel'), false, (): void => {
              this.identityConfirm = false;
            }),
          ],
        })
      }
    }
    .width('100%')
    .height('100%')
    // 弹层宿主（单 bindSheet + SheetKind 判别分发；iOS 四个 .sheet 直译合并）
    .bindSheet(this.sheet !== 'none', (): void => {
      this.sheetContent()
    }, {
      height: SheetSize.LARGE,
      showClose: false, // iOS sheet 无系统关闭钮（取消走各弹层头部）
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.sheet = 'none';
      },
    })
  }

  /** 弹层内容分发（iOS 四个私有 struct 直译形态，文件尾同文件内聚） */
  @Builder
  sheetContent() {
    if (this.sheet === 'theme') {
      ThemeColorSheet({
        mainHex: this.themeMainHex,
        derive: this.derive,
        animalKey: this.themeAnimal,
        onChangeMain: (hex: number): void => this.onThemePreview(hex),
        onCommitMain: (hex: number, custom: boolean): void => this.onThemeCommit(hex, custom),
        onChangeDerive: (on: boolean): void => this.onDeriveChange(on),
        onClose: (): void => {
          this.sheet = 'none';
        },
      })
    } else if (this.sheet === 'identity') {
      IdentityModeSheet({
        perPlanet: this.identityPerPlanet,
        onSelect: (target: boolean): void => void this.onIdentityModeSelect(target),
        onClose: (): void => {
          this.sheet = 'none';
        },
      })
    } else if (this.sheet === 'identityPick') {
      IdentityPickSheet({
        candidates: this.candidates,
        tints: this.tints,
        onPick: (planetId: string): void => {
          this.sheet = 'none';
          void this.switchIdentityMode(false, planetId);
        },
        onClose: (): void => {
          this.sheet = 'none';
        },
      })
    } else if (this.sheet === 'language') {
      LanguagePickerSheet({
        current: this.language,
        onSelect: (l: AppLanguage): void => void this.onLanguageSelect(l),
        onClose: (): void => {
          this.sheet = 'none';
        },
      })
    } else if (this.sheet === 'background') {
      BackgroundImagePickerSheet({
        hasImage: this.hasBgImage(),
        onApplied: (): void => this.onBackgroundApplied(),
        onClose: (): void => {
          this.sheet = 'none';
        },
      })
    }
  }

  /** 自绘标题栏（T5 骨架保留：返回热区 44×44 + 标题居中 + 右平衡占位） */
  @Builder
  titleBar() {
    Row() {
      Row() {
        Image($r('sys.media.ohos_ic_back'))
          .width(24)
          .height(24)
          .fillColor(DesignTokens.textPrimary(this.cm.dark))
      }
      .width(44)
      .height(44)
      .onClick(() => AppNav.pop())
      Text(this.loc('common.settings'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Row().width(44)
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .margin({ top: 12 })
  }

  // ---- 区/行通用形态（JoinNetworkSheet 表单范式） ----

  @Builder
  sectionHeader(key: string) {
    Text(this.loc(key))
      .fontSize(FS_SECTION_HEADER)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, bottom: 4 })
  }

  @Builder
  sectionFooter(key: string) {
    Text(this.loc(key))
      .fontSize(FS_CAPTION)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
  }

  /** 行间发丝线（iOS Form separator 直译；左内缩 16 对齐文本） */
  @Builder
  rowDivider() {
    Divider()
      .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
      .color(DesignTokens.hairline(this.cm.dark))
      .margin({ left: 16 })
  }

  /** toggle 行（iOS Toggle(label, isOn) 直译；禁用时标签同步置灰） */
  @Builder
  toggleRow(label: string, isOn: boolean, disabled: boolean,
    onChange: (on: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(FS_BODY)
        .fontColor(disabled
          ? DesignTokens.textSecondary(this.cm.dark)
          : DesignTokens.textPrimary(this.cm.dark))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .enabled(!disabled)
        .onChange((on: boolean): void => onChange(on))
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
  }

  /** 值行（iOS Button(.plain) + chevron.right 直译；themeDot=true 时尾缀主色圆点） */
  @Builder
  valueRow(label: string, value: string, themeDot: boolean, bgThumb: boolean,
    onTap: () => void) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      if (bgThumb && this.bgSignal.pixelMap !== null) {
        // 28pt 缩略图：与 Form 默认行高一致，不撑开选项高度（iOS 直译）
        Image(this.bgSignal.pixelMap)
          .width(THUMB_SIZE)
          .height(THUMB_SIZE)
          .borderRadius(THUMB_RADIUS)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else if (value !== '') {
        Text(value)
          .fontSize(FS_BODY)
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
      }
      if (themeDot) {
        Column()
          .width(DOT_SIZE)
          .height(DOT_SIZE)
          .borderRadius(DOT_SIZE / 2)
          .backgroundColor(themeSignal.accent)
      }
      SymbolGlyph($r('sys.symbol.chevron_forward'))
        .fontSize(FS_FOOTNOTE)
        .fontWeight(FontWeight.Bold)
        .fontColor([DesignTokens.textTertiary(this.cm.dark)])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .onClick((): void => onTap())
  }

  // ---- ① 网络段（#12；#16 连接超时为运行时常量，不渲染设置行——见文件头） ----

  @Builder
  networkSection() {
    Column() {
      this.sectionHeader('prefs.network.sectionHeader')
      Column() {
        this.toggleRow(this.loc('prefs.network.disableIPv6'), this.disableIpv6, false,
          (on: boolean): void => void this.setDisableIpv6(on))
        this.rowDivider()
        this.stepperRow()
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('prefs.network.footer')
    }
    .width('100%')
  }

  /** 多连接上限 stepper（iOS Stepper 直译：label %lld + 越界禁用） */
  @Builder
  stepperRow() {
    Row({ space: 4 }) {
      Text(this.locFmt('prefs.network.multiConnectLimit %lld', [this.maxNetworks]))
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      Row() {
        SymbolGlyph($r('sys.symbol.minus'))
          .fontSize(18)
          .fontColor([this.maxNetworks <= NET_LIMIT_MIN
            ? DesignTokens.textTertiary(this.cm.dark)
            : DesignTokens.textSecondary(this.cm.dark)])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .enabled(this.maxNetworks > NET_LIMIT_MIN)
      .opacity(this.maxNetworks > NET_LIMIT_MIN ? 1 : 0.35)
      .onClick((): void => void this.setMaxNetworks(this.maxNetworks - 1))
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([this.maxNetworks >= NET_LIMIT_MAX
            ? DesignTokens.textTertiary(this.cm.dark)
            : DesignTokens.textSecondary(this.cm.dark)])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .enabled(this.maxNetworks < NET_LIMIT_MAX)
      .opacity(this.maxNetworks < NET_LIMIT_MAX ? 1 : 0.35)
      .onClick((): void => void this.setMaxNetworks(this.maxNetworks + 1))
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 4 })
  }

  // ---- ② 节点身份段 ----

  @Builder
  identitySection() {
    Column() {
      this.sectionHeader('prefs.identity.sectionHeader')
      Column() {
        this.valueRow(this.loc('prefs.identity.mode'),
          this.loc(this.identityPerPlanet
            ? 'prefs.identity.mode.perPlanet' : 'prefs.identity.mode.shared'),
          false, false, (): void => {
            this.sheet = 'identity';
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('prefs.identity.footer')
    }
    .width('100%')
  }

  // ---- ③ 语言段（iOS 无 section header，行 label 即「语言」） ----

  @Builder
  languageSection() {
    Column() {
      Column() {
        this.valueRow(this.loc('prefs.language.sectionHeader'), this.languageValue(),
          false, false, (): void => {
            this.sheet = 'language';
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** 语言行值：nativeName（自身语言显示，不随界面语言变化）/「跟随系统」 */
  private languageValue(): string {
    if (this.language === AppLanguage.System) {
      return this.loc('prefs.language.system');
    }
    return nativeName(this.language) ?? this.loc('prefs.language.system');
  }

  // ---- ④ 主题段（iOS 同语言：无 header，行 label「主题色」+ 主色圆点） ----

  @Builder
  themeSection() {
    Column() {
      Column() {
        this.valueRow(this.loc('prefs.theme.sectionHeader'), '', true, false,
          (): void => this.openThemeSheet())
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  // ---- ⑤ 外观段（背景图 + 视差） ----

  @Builder
  appearanceSection() {
    Column() {
      this.sectionHeader('prefs.appearance.sectionHeader')
      Column() {
        this.valueRow(this.loc('prefs.appearance.background'),
          this.bgSignal.pixelMap !== null ? '' : this.loc('common.notSet'),
          false, true, (): void => {
            this.sheet = 'background';
          })
        this.rowDivider()
        this.toggleRow(this.loc('prefs.appearance.parallax'), this.parallax,
          !this.hasBgImage(), (on: boolean): void => void this.setParallax(on))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('prefs.appearance.footer')
    }
    .width('100%')
  }

  // ---- ⑥ 关于段（版本 / 构建信息 / 核心） ----

  @Builder
  aboutSection() {
    Column() {
      this.sectionHeader('prefs.about.sectionHeader')
      Column() {
        this.aboutRow(this.loc('prefs.about.version'), this.versionText)
        this.rowDivider()
        // 构建信息行：默认时间，点击切 git hash（iOS 直译；Button 染色问题 →
        // iOS 用手势，此处直接行 onClick 同语义）
        Row() {
          Text(this.loc('prefs.about.buildTime'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          Text(this.buildValue())
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textSecondary(this.cm.dark))
            .fontFamily(DesignTokens.FONT_MONO)
                .maxLines(1)
        }
        .width('100%')
        .height(ROW_HEIGHT)
        .padding({ left: 16, right: 16 })
        .onClick((): void => {
          this.buildInfoShowsHash = !this.buildInfoShowsHash;
        })
        this.rowDivider()
        this.aboutRow('ZeroTier Core',
          this.coreVersion === '' ? this.loc('common.unknown') : this.coreVersion)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** 构建信息值（iOS buildHashText 直译：hash + [dirty]） */
  private buildValue(): string {
    if (this.buildInfoShowsHash) {
      const hash = BuildInfo.hash + (BuildInfo.dirty ? ' [dirty]' : '');
      return hash === '' ? '—' : hash;
    }
    return BuildInfo.time === '' ? '—' : BuildInfo.time;
  }

  /** 关于行（iOS aboutRow 直译：值 mono secondary 单行） */
  @Builder
  aboutRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      Text(value)
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
        .fontFamily(DesignTokens.FONT_MONO)
        .maxLines(1)
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
  }

  // ---- 支持区（`if (false)` 隐藏不删，iOS :141-155 直译） ----

  @Builder
  supportSection() {
    Column() {
      this.sectionHeader('prefs.support.sectionHeader')
      Column() {
        Row({ space: 8 }) {
          Text(this.loc('prefs.support.donate'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(18)
            .fontColor([themeSignal.accent])
        }
        .width('100%')
        .height(ROW_HEIGHT)
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }
}

/**
 * 主题色弹层（iOS ThemeColorPickerSheet 直译）：示例色块（随机动物叠加）→
 * 预置色板（单行 8 圆点，选中白环）→ 色盘（自绘 HSL）→ 状态色派生开关。
 * mainHex 由宿主传入（预览域单一数据源——预设/色盘互相同步）。
 */
@ComponentV2
struct ThemeColorSheet {
  /** 预览域主色（宿主持有；拖动经 onChangeMain 即时回写） */
  @Param mainHex: number = 0xD44037;
  @Param derive: boolean = false;
  /** 示例色块随机动物（宿主打开时随机，iOS onAppear 直译） */
  @Param animalKey: string = IconCatalog.keys[0];
  @Param onChangeMain: (hex: number) => void = (_hex: number): void => { };
  @Param onCommitMain: (hex: number, custom: boolean) => void =
    (_hex: number, _custom: boolean): void => { };
  @Param onChangeDerive: (on: boolean) => void = (_on: boolean): void => { };
  @Param onClose: () => void = (): void => { };

  @Local cm: ColorModeSignal = colorModeSignal;

  private loc(key: string): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.get(key);
  }

  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.format(key, args);
  }

  /** HSL 取色器当前三值（iOS ThemeManager.hsl 直译，NAPI ColorMath） */
  private hsl(): number[] {
    return ColorMath.hslOf(this.mainHex);
  }

  /** 取色器（M-2：hsl() 单次 NAPI 求值经入参复用，不再 build 内三调） */
  @Builder
  hslPicker(hsl: number[]) {
    HSLColorPicker({
      hue: hsl[0],
      sat: hsl[1],
      light: hsl[2],
      onChange: (h: number, s: number, l: number): void =>
        this.onChangeMain(rgbFromHex(PlanetIcon.hslToHex(h, s, l))),
      onCommit: (): void => this.onCommitMain(this.mainHex, true),
    })
  }

  /** 示例色块动物白图（资源缺失降级纯色块，PlanetIconView 同语义） */
  @Builder
  sampleAnimal() {
    if (PlanetIcon.src(this.animalKey, getContext()) !== '') {
      Image(PlanetIcon.src(this.animalKey, getContext()))
        .width(SAMPLE_ANIMAL)
        .height(SAMPLE_ANIMAL)
        .objectFit(ImageFit.Contain)
    }
  }

  @Builder
  navBar() {
    Row() {
      Row().width(60)
      Text(this.loc('prefs.theme.sectionHeader'))
        .fontSize(FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.loc('common.done'))
        .fontSize(FS_BODY)
        .fontWeight(600)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ right: 12, top: 12, bottom: 12, left: 4 })
    }
    .width('100%')
    .height(48)
  }

  @Builder
  presetRow() {
    Row({ space: 4 }) {
      ForEach(ThemeManager.PRESETS, (hex: number, idx: number) => {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius('50%')
            .backgroundColor(rgbToArgb(hex))
          // 选中标记：白色描环（iOS strokeBorder lineWidth 2 padding 2 直译）
          if (hex === this.mainHex) {
            Column() {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius('50%')
                .border({ width: SWATCH_RING_WIDTH, color: '#FFFFFFFF' })
            }
            .width('100%')
            .height('100%')
            .padding(SWATCH_RING_INSET)
          }
        }
        .width('100%')
        .aspectRatio(1)
        .onClick((): void => this.onCommitMain(hex, false))
        .accessibilityText(this.locFmt('prefs.theme.a11yPreset %@',
          [this.loc(PRESET_NAME_KEYS[idx])]))
      }, (hex: number) => hex.toString())
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: FORM_SECTION_GAP }) {
          // ---- 示例块 + 预设（iOS 同组无标题 Section 直译）----
          Column() {
            Column() {
              // 示例色块：当前主色大样 + 随机小动物（取色即时变化）
              Stack({ alignContent: Alignment.Center }) {
                this.sampleAnimal()
              }
              .width(SAMPLE_SIZE)
              .height(SAMPLE_SIZE)
              .borderRadius(SAMPLE_RADIUS)
              .backgroundColor(rgbToArgb(this.mainHex))
              .margin({ top: 8, bottom: 8 })
              this.presetRow()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
          }
          .width('100%')

          // ---- 色盘（iOS Section("prefs.theme.wheel") 直译）----
          Column() {
            this.sheetSectionHeader('prefs.theme.wheel')
            Column() {
              this.hslPicker(this.hsl())
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
          }
          .width('100%')

          // ---- 派生开关（iOS Section footer 直译）----
          Column() {
            Column() {
              Row() {
                Text(this.loc('prefs.theme.deriveStatus'))
                  .fontSize(FS_BODY)
                  .fontColor(DesignTokens.textPrimary(this.cm.dark))
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.derive })
                  .onChange((on: boolean): void => this.onChangeDerive(on))
              }
              .width('100%')
              .height(ROW_HEIGHT)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            Text(this.loc('prefs.theme.footer'))
              .fontSize(FS_CAPTION)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
              .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
          }
          .width('100%')
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

  /** 弹层内区头（PrefsView.sectionHeader 的同款形态；struct 间不共享 @Builder） */
  @Builder
  sheetSectionHeader(key: string) {
    Text(this.loc(key))
      .fontSize(FS_SECTION_HEADER)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, bottom: 4 })
  }
}

/**
 * 身份模式选择弹层（iOS IdentityModeSheet 直译）：共享 / 每行星独立两行，
 * 当前模式 checkmark 纯展示；点另一行回调宿主分发（确认/候选选择）。
 */
@ComponentV2
struct IdentityModeSheet {
  @Param perPlanet: boolean = false;
  @Param onSelect: (target: boolean) => void = (_t: boolean): void => { };
  @Param onClose: () => void = (): void => { };

  @Local cm: ColorModeSignal = colorModeSignal;

  private loc(key: string): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.get(key);
  }

  @Builder
  navBar() {
    Row() {
      Row().width(60)
      Text(this.loc('prefs.identity.sectionHeader'))
        .fontSize(FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.loc('common.done'))
        .fontSize(FS_BODY)
        .fontWeight(600)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ right: 12, top: 12, bottom: 12, left: 4 })
    }
    .width('100%')
    .height(48)
  }

  /** 模式行：当前模式 checkmark 纯展示，其它模式可点（iOS modeRow 直译） */
  @Builder
  modeRow(titleKey: string, isCurrent: boolean, target: boolean) {
    Row() {
      Text(this.loc(titleKey))
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      if (isCurrent) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(FS_BODY)
          .fontColor([themeSignal.accent])
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .onClick((): void => {
      if (!isCurrent) {
        this.onSelect(target);
      }
    })
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: FORM_SECTION_GAP }) {
          Column() {
            Column() {
              // 共享在上、独立在下（iOS/Android 同序）
              this.modeRow('prefs.identity.mode.shared', !this.perPlanet, false)
              Divider()
                .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
                .color(DesignTokens.hairline(this.cm.dark))
                .margin({ left: 16 })
              this.modeRow('prefs.identity.mode.perPlanet', this.perPlanet, true)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            Text(this.loc('prefs.identity.footer'))
              .fontSize(FS_CAPTION)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
              .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
          }
          .width('100%')
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

/**
 * 共享身份选择弹层（iOS IdentityPickView 直译）：列出已生成独立身份的行星，
 * 点选其身份成为全局共享身份（宿主经 switchIdentityMode(false, planetId) 编排）。
 */
@ComponentV2
struct IdentityPickSheet {
  @Param candidates: PlanetCandidate[] = [];
  /** 行星装饰盘（宿主 ThemeManager.planetTintsHex 投影；磁贴底色） */
  @Param tints: number[] = [];
  @Param onPick: (planetId: string) => void = (_id: string): void => { };
  @Param onClose: () => void = (): void => { };

  @Local cm: ColorModeSignal = colorModeSignal;

  private loc(key: string): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.get(key);
  }

  /** 行星显示名（官方行星走 i18n 键，宿主同款直译） */
  private displayNameOf(planet: PlanetProfile): string {
    return planet.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name') : planet.name;
  }

  /** 磁贴底色（iOS PlanetIcon.tint(for:) 直译：自定义色优先，id 哈希回退 tints） */
  private tileTint(planet: PlanetProfile): number {
    if (this.tints.length === 0) {
      return 0xFF808080; // 色盘未种子化兜底（PlanetIcon 同款）
    }
    return PlanetIcon.fallbackColorHex(planet, this.tints);
  }

  @Builder
  navBar() {
    Row() {
      Text(this.loc('common.cancel'))
        .fontSize(FS_BODY)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ left: 12, top: 12, bottom: 12, right: 4 })
      Text(this.loc('prefs.identity.pick.title'))
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

  /** 候选行（iOS IdentityPickView label 直译：24 圆角 7 磁贴内 14 动物 + 名 + 地址） */
  @Builder
  candidateRow(c: PlanetCandidate) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (PlanetIcon.src(PlanetIcon.animalKey(c.planet), getContext()) !== '') {
          Image(PlanetIcon.src(PlanetIcon.animalKey(c.planet), getContext()))
            .width(PICK_TILE_CONTENT)
            .height(PICK_TILE_CONTENT)
            .objectFit(ImageFit.Contain)
        }
      }
      .width(PICK_TILE_SIZE)
      .height(PICK_TILE_SIZE)
      .borderRadius(PICK_TILE_RADIUS)
      .backgroundColor(this.tileTint(c.planet))
      Text(this.displayNameOf(c.planet))
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .maxLines(1)
      Blank()
      Text(c.address ?? '—')
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
        .fontFamily(DesignTokens.FONT_MONO)
        .maxLines(1)
    }
    .width('100%')
    .height(ROW_HEIGHT + 8)
    .padding({ left: 16, right: 16 })
    .onClick((): void => this.onPick(c.planet.id))
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: FORM_SECTION_GAP }) {
          Column() {
            Column() {
              if (this.candidates.length === 0) {
                Text(this.loc('prefs.identity.pick.empty'))
                  .fontSize(FS_BODY)
                  .fontColor(DesignTokens.textSecondary(this.cm.dark))
                  .width('100%')
                  .height(ROW_HEIGHT + 8)
                  .padding({ left: 16, right: 16 })
              }
              ForEach(this.candidates, (c: PlanetCandidate, idx: number) => {
                if (idx > 0) {
                  Divider()
                    .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
                    .color(DesignTokens.hairline(this.cm.dark))
                    .margin({ left: 16 })
                }
                this.candidateRow(c)
              }, (c: PlanetCandidate) => c.planet.id)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            Text(this.loc('prefs.identity.pick.footer'))
              .fontSize(FS_CAPTION)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
              .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
          }
          .width('100%')
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

/** 语言选择弹层（iOS Form Picker 直译：四行单选，当前行 checkmark） */
@ComponentV2
struct LanguagePickerSheet {
  @Param current: AppLanguage = AppLanguage.System;
  @Param onSelect: (l: AppLanguage) => void = (_l: AppLanguage): void => { };
  @Param onClose: () => void = (): void => { };

  @Local cm: ColorModeSignal = colorModeSignal;

  private loc(key: string): string {
    if (l10nSignal.rev < 0) {
      return key;
    }
    return L10n.get(key);
  }

  /** 选项名：跟随系统以当前语言文案（iOS String(localized:) 直译），其余自身名 */
  private optionName(l: AppLanguage): string {
    if (l === AppLanguage.System) {
      return this.loc('prefs.language.system');
    }
    return nativeName(l) ?? this.loc('prefs.language.system');
  }

  @Builder
  navBar() {
    Row() {
      Row().width(60)
      Text(this.loc('prefs.language.sectionHeader'))
        .fontSize(FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.loc('common.done'))
        .fontSize(FS_BODY)
        .fontWeight(600)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ right: 12, top: 12, bottom: 12, left: 4 })
    }
    .width('100%')
    .height(48)
  }

  build() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: FORM_SECTION_GAP }) {
          Column() {
            Column() {
              ForEach(LANGUAGE_OPTIONS, (l: AppLanguage, idx: number) => {
                if (idx > 0) {
                  Divider()
                    .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
                    .color(DesignTokens.hairline(this.cm.dark))
                    .margin({ left: 16 })
                }
                Row() {
                  Text(this.optionName(l))
                    .fontSize(FS_BODY)
                    .fontColor(DesignTokens.textPrimary(this.cm.dark))
                  Blank()
                  if (l === this.current) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(FS_BODY)
                      .fontColor([themeSignal.accent])
                  }
                }
                .width('100%')
                .height(ROW_HEIGHT)
                .padding({ left: 16, right: 16 })
                .onClick((): void => this.onSelect(l))
                .accessibilityText(this.optionName(l))
              }, (l: AppLanguage) => l as string)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
          }
          .width('100%')
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
