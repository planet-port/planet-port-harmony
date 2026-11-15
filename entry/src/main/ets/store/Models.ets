// Models.ets — 持久化数据模型 + 手写 JSON 编解码
//
// 直译源：store/Models.kt（kotlinx-serialization @Serializable）。ArkTS 无
// 反射序列化：编解码手写，逐字段对照。序列化语义三条硬约束：
//   ① 读：缺字段取默认值（对齐 kotlinx 默认值语义）；
//   ② 读：未知键忽略（ignoreUnknownKeys）；
//   ③ 写：全部字段总是写出（encodeDefaults）——键名与 Android JSON 逐字一致
//      （camelCase；枚举为名字符串；ULong 为 JSON 数字）。
// language 值域差异（有意）：Android "zh"|"zh-rTW"|"en"|null，鸿蒙取 iOS 形态
// "system"|"zh-Hans"|"zh-Hant"|"en"（默认 "system"，无 null 分支）——两平台
// 沙盒互不相通，无兼容负担，LanguageManager 直接消费。

export enum DnsMode { None = 'none', Network = 'network', Custom = 'custom' }
export enum PlanetKind { Official = 'official', Custom = 'custom' }

export class PlanetProfile {
  id: string; // UUID 小写 / "official"
  name: string;
  kind: PlanetKind;
  fileName: string | null; // planets/ 下文件名
  icon: string | null; // 动物图标 key
  iconColor: string | null; // "#RRGGBB"

  constructor(id: string, name: string, kind: PlanetKind,
    fileName: string | null = null, icon: string | null = null,
    iconColor: string | null = null) {
    this.id = id; this.name = name; this.kind = kind;
    this.fileName = fileName; this.icon = icon; this.iconColor = iconColor;
  }

  static readonly OFFICIAL_ID: string = 'official';
  static readonly OFFICIAL: PlanetProfile =
    new PlanetProfile('official', 'ZeroTier 官方', PlanetKind.Official);

  static fromJson(o: Record<string, Object>): PlanetProfile {
    // 修正②：字符串枚举没有数字枚举那样的反向索引表（PlanetKind[name] 运行时
    // 返回 undefined，'custom' 会错落到 Official——brief 原稿实为语义 bug），改
    // 显式映射。未知名回落默认值保持 brief 原稿的容错取向（kotlinx 严格模式对
    // 非法枚举名抛错→整文件隔离，此处放宽为字段级回落，垃圾输入不放大）。
    const kindName = (o['kind'] ?? 'official') as string;
    const kind = kindName === 'custom' ? PlanetKind.Custom : PlanetKind.Official;
    return new PlanetProfile(
      (o['id'] ?? 'official') as string,
      (o['name'] ?? '') as string,
      kind,
      // 修正③：统一走 nullOrString（null 字面量→null、''→null、缺键→null
      // 三分支收窄）——'' 分支防手编/历史文件，写侧已统一 null 字面量。
      Models.nullOrString(o['fileName']),
      Models.nullOrString(o['icon']),
      Models.nullOrString(o['iconColor']),
    );
  }

  toJson(): Record<string, Object> {
    // null 字段写出 null 字面量（kotlinx encodeDefaults 字节级对齐，评审统一）；
    // Object|null 联合构建再收窄 cast（null as Object 被 ArkTS 拒绝，同 AppPrefs）
    const o: Record<string, Object | null> = {
      'id': this.id, 'name': this.name, 'kind': this.kind as string,
      'fileName': this.fileName,
      'icon': this.icon,
      'iconColor': this.iconColor,
    };
    return o as Record<string, Object>;
  }
}

export class NetworkEntry {
  networkId: string; // 16 位小写十六进制
  networkName: string;
  lastActivated: boolean;
  routeViaZeroTier: boolean;
  dnsMode: DnsMode;
  customDns: string[];
  planetId: string | null;
  lastConflict: string | null; // "address"|"subnet"|"timeout"；null=无

  constructor(networkId: string, networkName: string, lastActivated: boolean,
    routeViaZeroTier: boolean, dnsMode: DnsMode, customDns: string[],
    planetId: string | null = null, lastConflict: string | null = null) {
    this.networkId = networkId; this.networkName = networkName;
    this.lastActivated = lastActivated; this.routeViaZeroTier = routeViaZeroTier;
    this.dnsMode = dnsMode; this.customDns = customDns;
    this.planetId = planetId; this.lastConflict = lastConflict;
  }

  get id(): string { return this.networkId; } // 计算属性对齐 Kotlin val id get()

  static fromJson(o: Record<string, Object>): NetworkEntry {
    const dns = o['customDns'] as string[] ?? [];
    // 修正②（同 PlanetProfile）：字符串枚举反向索引不可用，改显式映射。
    const dnsName = (o['dnsMode'] ?? 'none') as string;
    const dnsMode = dnsName === 'network' ? DnsMode.Network
      : dnsName === 'custom' ? DnsMode.Custom : DnsMode.None;
    return new NetworkEntry(
      (o['networkId'] ?? '') as string,
      (o['networkName'] ?? '') as string,
      (o['lastActivated'] ?? false) as boolean,
      (o['routeViaZeroTier'] ?? false) as boolean,
      dnsMode,
      dns,
      Models.nullOrString(o['planetId']),
      Models.nullOrString(o['lastConflict']),
    );
  }

  toJson(): Record<string, Object> {
    const o: Record<string, Object | null> = {
      'networkId': this.networkId, 'networkName': this.networkName,
      'lastActivated': this.lastActivated, 'routeViaZeroTier': this.routeViaZeroTier,
      'dnsMode': this.dnsMode as string, 'customDns': this.customDns,
      'planetId': Models.stringOrNull(this.planetId),
      'lastConflict': Models.stringOrNull(this.lastConflict),
    };
    return o as Record<string, Object>;
  }
}

export class MoonEntry {
  worldId: number; // JSON 数字（JS number 双精度安全：moon worldId ≪ 2^53）
  seed: number;
  fromFile: boolean;
  planetId: string | null;

  constructor(worldId: number, seed: number, fromFile: boolean,
    planetId: string | null = null) {
    this.worldId = worldId; this.seed = seed; this.fromFile = fromFile;
    this.planetId = planetId;
  }

  get id(): string { return MoonEntry.formatWorldId(this.worldId); }

  /**
   * 16 位小写十六进制（Kotlin "%016x".format(worldId.toLong()) 直译）。
   * 修正⑤：brief 原稿 `>>> 0` + 8 次 nibble 循环只会输出 8 位 hex，且把
   * >2^32 的 worldId 截断——真实 moon worldId 是 40 位地址量级（可到
   * 0x93da719a7c = 635025070716），截断会静默错数据。改为 16 次
   * 「%16 + floor(/16)」取位，双精度下 <2^53 精确，
   * 覆盖 ULong 的小于 2^53 子集（与类注释「moon worldId ≪ 2^53」同一前提）。
   * 负数/NaN/Infinity（垃圾输入）按 0 处理，输出恒为 16 位（评审加固：
   * Math.floor(NaN)=NaN 会产出 48 字符 "NaN" 垃圾串）。
   */
  static formatWorldId(worldId: number): string {
    let v = worldId < 0 || !Number.isFinite(worldId) ? 0 : Math.floor(worldId);
    let s = '';
    for (let i = 0; i < 16; i++) {
      s = (v % 16).toString(16) + s;
      v = Math.floor(v / 16);
    }
    return s;
  }

  static fromJson(o: Record<string, Object>): MoonEntry {
    return new MoonEntry(
      (o['worldId'] ?? 0) as number,
      (o['seed'] ?? 0) as number,
      (o['fromFile'] ?? false) as boolean,
      Models.nullOrString(o['planetId']),
    );
  }

  toJson(): Record<string, Object> {
    // 修正⑥：worldId/seed 原样写 JSON 数字（kotlinx 对 ULong 即写数值）；
    // `>>> 0` 的 32 位截断对 >2^32 的真实 worldId 是数据破坏，删除。
    const o: Record<string, Object | null> = {
      'worldId': this.worldId, 'seed': this.seed,
      'fromFile': this.fromFile,
      'planetId': Models.stringOrNull(this.planetId),
    };
    return o as Record<string, Object>;
  }
}

export class AppPrefs {
  selectedPlanetId: string = PlanetProfile.OFFICIAL_ID;
  activePlanetId: string | null = null;
  disableIpv6: boolean = false;
  themeColor: number | null = null; // RGB（iOS UInt32 0xRRGGBB；非 ARGB——鸿蒙消费侧统一 RGB）
  themeColorCustom: number | null = null; // 非 null 时优先于 themeColor
  successDerived: boolean = false;
  language: string = 'system'; // "system"|"zh-Hans"|"zh-Hant"|"en"
  backgroundImage: boolean = false;
  parallax: boolean = true;
  maxNetworks: number = 2; // 2..6
  connectOnDemand: boolean = false; // 平台无 On Demand（降级①），字段保留直译
  identityPerPlanet: boolean = false;
  /** #28 开 App 自动恢复（A5-T12；iOS On Demand 无等价物的替代门控，默认开） */
  autoRestore: boolean = true;

  static fromJson(o: Record<string, Object>): AppPrefs {
    const p = new AppPrefs();
    p.selectedPlanetId = (o['selectedPlanetId'] ?? PlanetProfile.OFFICIAL_ID) as string;
    p.activePlanetId = Models.nullOrString(o['activePlanetId']);
    p.disableIpv6 = (o['disableIpv6'] ?? false) as boolean;
    p.themeColor = Models.nullOrNumber(o['themeColor']);
    p.themeColorCustom = Models.nullOrNumber(o['themeColorCustom']);
    p.successDerived = (o['successDerived'] ?? false) as boolean;
    p.language = (o['language'] ?? 'system') as string;
    p.backgroundImage = (o['backgroundImage'] ?? false) as boolean;
    p.parallax = (o['parallax'] ?? true) as boolean;
    p.maxNetworks = (o['maxNetworks'] ?? 2) as number;
    p.connectOnDemand = (o['connectOnDemand'] ?? false) as boolean;
    p.identityPerPlanet = (o['identityPerPlanet'] ?? false) as boolean;
    p.autoRestore = (o['autoRestore'] ?? true) as boolean;
    return p;
  }

  toJson(): Record<string, Object> {
    // 修正④：themeColor/themeColorCustom 为 null 时必须写出 JSON null 字面量
    // （kotlinx encodeDefaults 语义，Android 侧读回 null 缺省）。ArkTS 禁止
    // `null as Object` 与 any/unknown，故先按 Object|null 联合构建再收窄 cast；
    // 返回签名保持 Record<string, Object>，Task 4 writeListFile 契约不变。
    const o: Record<string, Object | null> = {
      'selectedPlanetId': this.selectedPlanetId,
      'activePlanetId': Models.stringOrNull(this.activePlanetId),
      'disableIpv6': this.disableIpv6,
      'themeColor': Models.numberOrNull(this.themeColor),
      'themeColorCustom': Models.numberOrNull(this.themeColorCustom),
      'successDerived': this.successDerived,
      'language': this.language,
      'backgroundImage': this.backgroundImage,
      'parallax': this.parallax,
      'maxNetworks': this.maxNetworks,
      'connectOnDemand': this.connectOnDemand,
      'identityPerPlanet': this.identityPerPlanet,
      'autoRestore': this.autoRestore,
    };
    return o as Record<string, Object>;
  }
}

/** 可空字段 JSON 编解码收口：写出 null 字面量（kotlinx encodeDefaults 字节级对齐）；读回三分支收窄 */
export class Models {
  static nullOrString(v: Object | undefined): string | null {
    if (v === undefined || v === null) return null;
    // '' 分支防手编/历史文件（写侧已统一 null 字面量，不再产生 ''）
    const s = v as string;
    return s === '' ? null : s;
  }
  static stringOrNull(v: string | null): Object | null {
    return v; // 运行时真 null，JSON.stringify 输出 null 字面量（评审统一：与 numberOrNull 同构）
  }
  static nullOrNumber(v: Object | undefined): number | null {
    if (v === undefined || v === null) return null;
    return v as number;
  }
  static numberOrNull(v: number | null): Object | null {
    return v;
  }
}
