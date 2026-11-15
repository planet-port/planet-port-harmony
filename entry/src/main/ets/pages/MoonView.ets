// MoonView.ets — Moon 管理页（iOS MoonView.swift 全文 + MoonImporter.swift 直译）
//
// List 卡片行（与首页/Peers 同语言：灰底圆角卡 + 水平 20 / 上下 6 边距）：
// 32×32 accent 底圆角 10 白 moon 徽标 + worldId body mono + seed caption（仅
// 手动添加的行显示）+ 缓存徽标 Capsule（已缓存成功绿 0.12 / 未缓存中性
// secondary 0.12；文件导入附 doc 图标）。左滑删除（ArkUI List swipeAction ≈
// iOS swipeActions(.trailing)，Android SwipeToDismissBox 同范式）+ 长按菜单
// （bindContextMenu LongPress：删除入轨/复制地址/删缓存——删缓存仅文件导入行）。
// 添加 sheet：文件导入（DocumentViewPicker + 0x7f 头校验 + 落盘 moons.d）/
// 手动 orbit 表单（worldId/seed 16 位 hex，双段齐备才可点）。
// 文件导入语义（MoonImporter.importMoonFile 直译）：≥9B 且首字节 0x7f →
// [1..8] 大端 worldId → 原文件整体写入 planetStateDir(planetId)/moons.d/
// %016x.moon → MoonEntry(worldId, seed: 0, fromFile: true)。
// 平台差异（详见任务报告）：iOS seed 显示字面为 "seed " + 16 位 hex 无 0x
// （brief 简写 `seed 0x…`，按直译源落码）；worldId/seed 十六进制文本按 number
// 解析承载（>2^53 精度损失——与 store 层「moon worldId ≪ 2^53」同一前提）。
import fs from '@ohos.file.fs';
import { picker } from '@kit.CoreFileKit';
import pasteboard from '@ohos.pasteboard';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppNav } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StoreRepo } from '../store/StoreRepo';
import { MoonEntry, PlanetProfile } from '../store/Models';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { L10n, l10nSignal } from '../components/L10n';
import { AppAlert, AppAlertButton } from '../components/AppAlert';

/** 字号（iOS .body 17 / .caption 12 / .caption2 11 / .subheadline 15 /
 *  .footnote 13；32 为空态图标、15 为徽标符号） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_CAPTION2: number = 11;
const FS_SUBHEADLINE: number = 15;
const FS_FOOTNOTE: number = 13;
const FS_EMPTY_ICON: number = 32;
const FS_BADGE_ICON: number = 15;
/** 行卡片边距（iOS cardInsets：水平 20 / 上下 6）与卡内衬（padding 14） */
const CARD_MARGIN_H: number = 20;
const CARD_MARGIN_V: number = 6;
const CARD_PAD: number = 14;
/** moon 徽标（iOS 32×32 圆角 10 内 15 semibold 白） */
const BADGE_SIZE: number = 32;
const BADGE_RADIUS: number = 10;
/** 徽标胶囊圆角（= 高度一半）与左滑删除钮宽 */
const CAPSULE_RADIUS: number = 999;
const SWIPE_BTN_WIDTH: number = 72;
/** 缓存目录名与 .moon 文件头字节（MoonImporter 直译） */
const MOONS_DIR: string = 'moons.d';
const MOON_HEADER_BYTE: number = 0x7f;
/** 添加 sheet 收起 → 文件选择器拉起的等待（iOS asyncAfter 0.3 直译） */
const SHEET_TO_PICKER_DELAY_MS: number = 300;
/** 成功色兜底（applyTheme 派生前首帧；HomeView 同款） */
const FALLBACK_SUCCESS: number = 0xFF009830;

@ComponentV2
export struct MoonView {
  /** 页面入参（T5 契约；轨道按本行星读写） */
  @Param planetId: string = '';

  /** 全局 UI 状态 */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  @Local theme: ThemeSignal = themeSignal;
  /** 本行星轨道表（整体替换触踪） */
  @Local moons: MoonEntry[] = [];
  /** 首次读盘完成前不渲染列表（Android MoonView loaded 闸：防空态闪变） */
  @Local loaded: boolean = false;
  /** 已落盘缓存文件集合（moon.id ∈ 集合 = 已缓存） */
  @Local cachedIds: Set<string> = new Set();
  /** 添加 sheet 与手动表单 */
  @Local showAdd: boolean = false;
  @Local worldIdText: string = '';
  @Local seedText: string = '';
  /** 错误提示（iOS .alert(common.notice) 直译） */
  @Local alertMsg: string = '';
  /** 主题派生域：成功绿（缓存徽标） */
  @Local successColor: number = FALLBACK_SUCCESS;

  private themeRef: ThemeManager | null = null;
  private pickTimer: number = -1;

  aboutToAppear(): void {
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.applyTheme();
    });
    // 本页数据域不走 configChanged 全量重读（写入路径都在本页收口后手动刷新，
    // 外部写入与删除页的 moons 域无交互），与 Android MoonViewModel refresh
    // 语义一致
    void this.refreshMoons();
  }

  aboutToDisappear(): void {
    this.clearPickTimer();
  }

  /** 主题/深浅色变化 → 重算成功绿 */
  @Monitor('theme.rev', 'cm.dark')
  applyTheme(): void {
    const t = this.themeRef;
    if (t === null) {
      return;
    }
    const raw = this.cm.dark ? t.successDarkHex() : t.successLightHex();
    this.successColor = raw > 0xFFFFFF ? raw : 0xFF000000 + raw;
  }

  // ---- 数据域 ----

  /** 轨道表 + 缓存文件探测（iOS app.moons 装载 + cacheBadge fileExists 直译） */
  private async refreshMoons(): Promise<void> {
    const moons = await StoreRepo.store.readMoons(this.planetId);
    this.moons = moons;
    this.loaded = true;
    const next = new Set<string>();
    for (const m of moons) {
      const exists = await this.cacheFileExists(m);
      if (exists) {
        next.add(m.id);
      }
    }
    this.cachedIds = next;
  }

  /** 缓存文件路径（iOS MoonEntry.cacheFileURL 直译）：
   *  planetStateDir(planetId)/moons.d/%016x.moon */
  private cachePath(moon: MoonEntry): string {
    const owner = moon.planetId ?? this.planetId;
    return `${StoreRepo.store.paths.planetStateDir(owner)}/${MOONS_DIR}/`
      + `${MoonEntry.formatWorldId(moon.worldId)}.moon`;
  }

  private async cacheFileExists(moon: MoonEntry): Promise<boolean> {
    try {
      return await fs.access(this.cachePath(moon));
    } catch (_e) {
      return false;
    }
  }

  private isCached(moon: MoonEntry): boolean {
    return this.cachedIds.has(moon.id);
  }

  // ---- 操作域 ----

  /** 添加轨道（iOS addMoon 直译）：同 worldId 顶替 + 表尾追加 + 落盘 + 刷新 */
  private async addMoon(entry: MoonEntry): Promise<void> {
    const moons = this.moons.filter((m: MoonEntry): boolean =>
      m.worldId !== entry.worldId);
    moons.push(entry);
    await StoreRepo.store.writeMoons(moons, this.planetId);
    void this.app.reload();
    await this.refreshMoons();
  }

  /** 删除入轨（iOS deleteOrbit 直译）：只清记录不删缓存文件（文件留存供同
   *  worldId 重新入轨时复用；store.deleteMoon 同语义） */
  private async deleteOrbit(moon: MoonEntry): Promise<void> {
    await StoreRepo.store.deleteMoon(moon.worldId, this.planetId);
    void this.app.reload();
    await this.refreshMoons();
  }

  /** 删缓存（iOS deleteCache 直译）：仅移除 moons.d 落盘文件，记录保留 */
  private async deleteCache(moon: MoonEntry): Promise<void> {
    try {
      await fs.unlink(this.cachePath(moon));
    } catch (_e) {
      // 不存在/删除失败静默（iOS try? removeItem 同语义）
    }
    await this.refreshMoons();
  }

  /** 复制地址（iOS copyAddress 直译）：worldId 16 位 hex 入系统剪贴板 */
  private copyAddress(moon: MoonEntry): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
      MoonEntry.formatWorldId(moon.worldId));
    pasteboard.getSystemPasteboard().setDataSync(data);
  }

  /** 添加 sheet → 文件选择器（iOS onFileImport 直译：收起 sheet 延时 0.3s
   *  再拉起选择器，避免同帧双模态冲突） */
  private startFileImport(): void {
    this.showAdd = false;
    this.clearPickTimer();
    this.pickTimer = setTimeout((): void => {
      this.pickTimer = -1;
      void this.pickMoonFile();
    }, SHEET_TO_PICKER_DELAY_MS);
  }

  private clearPickTimer(): void {
    if (this.pickTimer >= 0) {
      clearTimeout(this.pickTimer);
      this.pickTimer = -1;
    }
  }

  /** 文件导入（iOS fileImporter + MoonImporter.importMoonFile 直译）：单选 →
   *  读字节 → ≥9B 且头 0x7f → worldId 大端解 → 整文件落盘 moons.d → 入轨 */
  private async pickMoonFile(): Promise<void> {
    try {
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker().select(opts);
      if (uris.length === 0) {
        return; // 用户取消：静默
      }
      const data = await this.readUriBytes(uris[0]);
      if (data === null || data.length < 9) {
        this.alertMsg = this.loc('error.moon.readFailed'); // ImportError.readFailed 同位
        return;
      }
      if (data[0] !== MOON_HEADER_BYTE) {
        this.alertMsg = this.loc('error.moon.badHeader'); // ImportError.badHeader 同位
        return;
      }
      let worldId = 0;
      for (let i = 1; i <= 8; i++) {
        worldId = worldId * 256 + data[i];
      }
      const entry = new MoonEntry(worldId, 0, true, this.planetId);
      const ok = await this.writeBytes(this.cachePath(entry), data);
      if (!ok) {
        this.alertMsg = this.loc('error.moon.readFailed'); // write 抛错 → readFailed 同位
        return;
      }
      await this.addMoon(entry);
    } catch (_e) {
      this.alertMsg = this.loc('error.moon.readFailed'); // 选择器通路异常同位
    }
  }

  /** 手动 orbit（iOS AddMoonSheet onManualOrbit 直译）：16 位 hex 双段合法
   *  才可点（按钮 disabled 域），解析失败按 0（iOS UInt64(..., radix:16) ?? 0） */
  private manualOrbit(): void {
    if (!MoonView.hex16Valid(this.worldIdText) || !MoonView.hex16Valid(this.seedText)) {
      return;
    }
    const entry = new MoonEntry(MoonView.parseHex16(this.worldIdText),
      MoonView.parseHex16(this.seedText), false, this.planetId);
    this.showAdd = false;
    this.worldIdText = '';
    this.seedText = '';
    void this.addMoon(entry);
  }

  /** 16 位 hex 合法性（iOS hex16Valid 直译：长度 16 且全 hex 位） */
  private static hex16Valid(text: string): boolean {
    if (text.length !== 16) {
      return false;
    }
    return /^[0-9a-fA-F]{16}$/.test(text);
  }

  /** 16 位 hex → number（逐 nibble 累进；>2^53 精度损失见文件头平台差异注） */
  private static parseHex16(text: string): number {
    const normalized = text.toLowerCase();
    let v = 0;
    for (let i = 0; i < normalized.length; i++) {
      const code = normalized.charCodeAt(i);
      const d = code >= 0x30 && code <= 0x39 ? code - 0x30 : code - 0x61 + 10;
      if (d < 0 || d > 15) {
        return 0;
      }
      v = v * 16 + d;
    }
    return v;
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

  /** 浏览行星展示名（官方走本地化名，HomeView.displayNameOf 同款） */
  private planetName(): string {
    const p = this.app.planets.find(
      (q: PlanetProfile): boolean => q.id === this.planetId);
    if (p === undefined) {
      return this.loc('planet.official.name');
    }
    return p.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name') : p.name;
  }

  /** 选择器 URI → 恰长字节；失败 null（AddPlanetPage.readUriBytes 同款） */
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

  /** 整文件落盘（逐级建目录；失败 false 不放大） */
  private async writeBytes(path: string, data: Uint8Array): Promise<boolean> {
    let fd = -1;
    try {
      await this.mkdirP(path.substring(0, path.lastIndexOf('/')));
      const f = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      fd = f.fd;
      const ab = data.buffer.slice(data.byteOffset,
        data.byteOffset + data.byteLength) as ArrayBuffer;
      await fs.write(fd, ab);
      await fs.close(fd);
      fd = -1;
      return true;
    } catch (_e) {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
      return false;
    }
  }

  /** 逐级建目录（JsonFileStore.mkdirP 同款；已存在吞错） */
  private async mkdirP(dir: string): Promise<void> {
    const parts = dir.split('/');
    let cur = '';
    for (const part of parts) {
      if (part === '') {
        if (cur === '') {
          cur = '/';
        }
        continue;
      }
      cur = cur === '/' ? `/${part}` : cur === '' ? part : `${cur}/${part}`;
      try { await fs.mkdir(cur); } catch (_e) { /* 已存在 */ }
    }
  }

  // ---- 渲染 ----

  build() {
    Stack() {
      Column() {
        this.titleBar()
        List() {
          if (this.loaded && this.moons.length === 0) {
            ListItem() {
              this.emptyCard()
            }
          }
          ForEach(this.moons, (moon: MoonEntry) => {
            ListItem() {
              this.moonRow(moon)
            }
              // 左滑删除（iOS swipeActions(.trailing) 直译）
              .swipeAction({
                end: {
                  builder: (): void => {
                    this.swipeDeleteBtn(moon)
                  },
                  onAction: (): void => {
                    void this.deleteOrbit(moon);
                  },
                },
              })
              // 长按菜单（iOS contextMenu 直译）
              .bindContextMenu((): void => {
                this.moonMenu(moon)
              }, ResponseType.LongPress)
          }, (moon: MoonEntry) => `${moon.worldId}:${moon.seed}:${moon.fromFile}:`
            + `${moon.planetId ?? ''}:${this.isCached(moon) ? 1 : 0}`
            + `:${this.theme.rev}:${this.cm.dark ? '1' : '0'}:${l10nSignal.rev}`) // 数据指纹 keyer
          // （T7 C-1 教训）：key 相同即复用整棵子树——除数据字段外拼入行渲染
          // 消费的主题/深浅/语言指纹（accent 徽标、缓存徽标、cached 文案），
          // 切主题/语言时存量行才能随指纹变化重建
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      if (this.alertMsg !== '') {
        AppAlert({
          title: this.loc('common.notice'),
          message: this.alertMsg,
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.alertMsg = '';
          })],
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
    // 添加 sheet（iOS .sheet(isPresented: $showAdd) 直译）
    .bindSheet(this.showAdd, (): void => {
      this.addMoonSheet()
    }, {
      height: SheetSize.LARGE,
      showClose: false,
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showAdd = false;
      },
    })
  }

  /** 自绘标题栏（T5 骨架 + 右侧加号槽 = iOS topBarTrailing 直译） */
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
      Text(this.loc('moon.title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(20)
          .fontColor([DesignTokens.textPrimary(this.cm.dark)])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.showAdd = true;
      })
      .accessibilityText(this.loc('moon.addTitle'))
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .margin({ top: 12 })
  }

  /** 空态卡（iOS emptyCard 直译）：moon 图标 + 标题 + 「右上角 + 添加」提示 */
  @Builder
  emptyCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.star_2_moon'))
        .fontSize(FS_EMPTY_ICON)
        .fontWeight(FontWeight.Lighter)
        .fontColor([DesignTokens.textSecondary(this.cm.dark)])
      Text(this.locFmt('moon.emptyTitle %@', [this.planetName()]))
        .fontSize(FS_SUBHEADLINE)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Text(this.loc('moon.emptyHint'))
        .fontSize(FS_FOOTNOTE)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
    }
    .width('100%')
    .padding({ top: 36, bottom: 36 })
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .margin({
      left: CARD_MARGIN_H, right: CARD_MARGIN_H,
      top: CARD_MARGIN_V, bottom: CARD_MARGIN_V,
    })
  }

  /** Moon 行（iOS moonRow 直译）：徽标 + worldId/seed/缓存徽标 */
  @Builder
  moonRow(moon: MoonEntry) {
    Row({ space: 12 }) {
      // 徽标：与首页身份区同语言（accent 实底圆角 10 + 白符号）
      Row() {
        SymbolGlyph($r('sys.symbol.star_2_moon_fill'))
          .fontSize(FS_BADGE_ICON)
          .fontWeight(600) // iOS .semibold 直译
          .fontColor([0xFFFFFFFF])
      }
      .width(BADGE_SIZE)
      .height(BADGE_SIZE)
      .justifyContent(FlexAlign.Center)
      .borderRadius(BADGE_RADIUS)
      .backgroundColor(this.accent())
      Column({ space: 5 }) {
        Text(MoonEntry.formatWorldId(moon.worldId))
          .fontSize(FS_BODY)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          if (!moon.fromFile) {
            // iOS 字面为 "seed " + 16 位 hex（无 0x 前缀，按直译源落码）
            Text(`seed ${MoonEntry.formatWorldId(moon.seed)}`)
              .fontSize(FS_CAPTION)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .maxLines(1)
          }
          this.cacheBadge(moon)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .margin({
      left: CARD_MARGIN_H, right: CARD_MARGIN_H,
      top: CARD_MARGIN_V, bottom: CARD_MARGIN_V,
    })
  }

  /** 缓存徽标（iOS cacheBadge 直译）：已缓存成功绿 / 未缓存中性；文件导入
   *  附 doc 图标 */
  @Builder
  cacheBadge(moon: MoonEntry) {
    Row({ space: 3 }) {
      if (moon.fromFile) {
        SymbolGlyph($r('sys.symbol.doc'))
          .fontSize(FS_CAPTION2)
          .fontColor([this.badgeColor(moon)])
      }
      Text(this.isCached(moon) ? this.loc('moon.cached') : this.loc('moon.notCached'))
        .fontSize(FS_CAPTION2)
        .fontWeight(600)
        .fontColor(this.badgeColor(moon))
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .borderRadius(CAPSULE_RADIUS)
    .backgroundColor(this.isCached(moon)
      ? 0x1F000000 + (this.successColor & 0xFFFFFF) // 成功绿 0.12（0x1F alpha 加法重组）
      : this.quaternary())
  }

  /** 徽标字色（iOS foregroundStyle(cached ? success : secondary) 直译） */
  private badgeColor(moon: MoonEntry): number {
    return this.isCached(moon) ? this.successColor
      : DesignTokens.textSecondary(this.cm.dark);
  }

  /** 中性 0.12 底（iOS Color.secondary.opacity(0.12) 直译） */
  private quaternary(): number {
    return this.cm.dark ? 0x1FEBEBF5 : 0x1F3C3C43;
  }

  /** 主题 accent（themeSignal.accent '#AARRGGBB' → 渲染域 number） */
  private accent(): number {
    return parseInt(this.theme.accent.slice(2), 16) + 0xFF000000;
  }

  /** 左滑删除钮（iOS destructive swipe button 直译）：红底 + trash 白符号 */
  @Builder
  swipeDeleteBtn(moon: MoonEntry) {
    Row() {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(20)
          .fontColor([0xFFFFFFFF])
        Text(this.loc('moon.deleteOrbit'))
          .fontSize(FS_CAPTION2)
          .fontColor(0xFFFFFFFF)
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width(SWIPE_BTN_WIDTH)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(DesignTokens.danger(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .margin({ right: CARD_MARGIN_H, top: CARD_MARGIN_V, bottom: CARD_MARGIN_V })
  }

  /** 长按菜单（iOS contextMenu 直译）：删除入轨 / 复制地址 / 删缓存（仅
   *  文件导入行）；破坏性项按 iOS role: .destructive 落红 */
  @Builder
  moonMenu(moon: MoonEntry) {
    Menu() {
      MenuItem({
        content: this.loc('moon.deleteOrbit'),
        symbolStartIcon: this.menuSymbol('trash', DesignTokens.danger(this.cm.dark)),
      })
        .contentFontColor(DesignTokens.danger(this.cm.dark))
        .onClick((): void => {
          void this.deleteOrbit(moon);
        })
      MenuItem({
        content: this.loc('moon.copyAddress'),
        symbolStartIcon: this.menuSymbol('doc_filled_on_doc',
          DesignTokens.textPrimary(this.cm.dark)),
      })
        .contentFontColor(DesignTokens.textPrimary(this.cm.dark))
        .onClick((): void => {
          this.copyAddress(moon);
        })
      if (moon.fromFile) {
        MenuItem({
          content: this.loc('moon.deleteCache'),
          symbolStartIcon: this.menuSymbol('clean', DesignTokens.danger(this.cm.dark)),
        })
          .contentFontColor(DesignTokens.danger(this.cm.dark))
          .onClick((): void => {
            void this.deleteCache(moon);
          })
      }
    }
  }

  /** 菜单符号载体（MenuItemOptions.symbolStartIcon @API12 直译） */
  private menuSymbol(name: string, color: number): SymbolGlyphModifier {
    return new SymbolGlyphModifier($r('sys.symbol.' + name))
      .fontSize('16vp')
      .fontColor([color]);
  }

  /** 添加 sheet（iOS AddMoonSheet 直译）：文件导入段 + 手动 orbit 表单段 */
  @Builder
  addMoonSheet() {
    Column() {
      // 导航行（iOS NavigationStack cancellationAction 直译）
      Row() {
        Text(this.loc('common.cancel'))
          .fontSize(FS_BODY)
          .fontColor(this.accent())
          .onClick((): void => {
            this.showAdd = false;
          })
          .padding({ left: 16, top: 12, bottom: 12, right: 4 })
        Text(this.loc('moon.addTitle'))
          .fontSize(FS_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        Row().width(72)
      }
      .width('100%')
      .height(48)
      .margin({ top: 12 })

      Scroll() {
        Column({ space: 20 }) {
          // 文件导入段（iOS Section("moon.importFileHeader") + Label(doc) 直译）
          Column() {
            Text(this.loc('moon.importFileHeader'))
              .fontSize(FS_FOOTNOTE)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
              .padding({ left: 20, right: 20, bottom: 4 })
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.doc'))
                .fontSize(20)
                .fontColor([this.accent()])
              Text(this.loc('moon.chooseFile'))
                .fontSize(FS_BODY)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
            }
            .width('100%')
            .height(44)
            .padding({ left: 16, right: 16 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: 20, right: 20 })
            .onClick((): void => {
              this.startFileImport();
            })
            .accessibilityText(this.loc('moon.chooseFile'))
          }
          .width('100%')

          // 手动 orbit 段（iOS Section("moon.manualHeader") 直译）
          Column() {
            Text(this.loc('moon.manualHeader'))
              .fontSize(FS_FOOTNOTE)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
              .padding({ left: 20, right: 20, bottom: 4 })
            Column() {
              TextInput({ text: this.worldIdText,
                placeholder: this.loc('moon.worldIdPlaceholder') })
                .fontSize(FS_BODY)
                .fontFamily(DesignTokens.FONT_MONO)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
                .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
                .backgroundColor(Color.Transparent)
                .height(44)
                .inputFilter('[0-9a-fA-F]') // iOS .characters 大写引导的最近似等价
                .onChange((v: string) => {
                  this.worldIdText = v;
                })
              TextInput({ text: this.seedText,
                placeholder: this.loc('moon.seedPlaceholder') })
                .fontSize(FS_BODY)
                .fontFamily(DesignTokens.FONT_MONO)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
                .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
                .backgroundColor(Color.Transparent)
                .height(44)
                .inputFilter('[0-9a-fA-F]')
                .onChange((v: string) => {
                  this.seedText = v;
                })
              Text(this.loc('moon.orbit'))
                .fontSize(FS_BODY)
                .fontWeight(600)
                .fontColor(this.manualOrbitEnabled()
                  ? this.accent() : DesignTokens.textTertiary(this.cm.dark))
                .textAlign(TextAlign.Center)
                .width('100%')
                .height(44)
                .opacity(this.manualOrbitEnabled() ? 1 : 0.35)
                .onClick((): void => {
                  if (this.manualOrbitEnabled()) {
                    this.manualOrbit();
                  }
                })
                .accessibilityText(this.loc('moon.orbit'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            .backgroundColor(DesignTokens.cardBg(this.cm.dark))
            .borderRadius(DesignTokens.RADIUS_SM)
            .margin({ left: 20, right: 20 })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ top: 8, bottom: 40 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
  }

  /** 手动 orbit 可点（iOS .disabled(!hex16Valid...) 直译） */
  private manualOrbitEnabled(): boolean {
    return MoonView.hex16Valid(this.worldIdText) && MoonView.hex16Valid(this.seedText);
  }
}
