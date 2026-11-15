// L10n.ets — A5 三语查表运行时 + 92 动物图标目录
//
// 鸿蒙 getStringSync 不支持指定 locale（Global Constraints），文案走应用内查表：
// rawfile/i18n/{en,zh-Hans,zh-Hant}.json 由 scripts/assets-convert.sh 从 iOS
// Localizable.xcstrings（356 键）+ QRTransfer.xcstrings（20 键）生成，启动读一次入静态表。
// 当前语言取 LanguageManager（prefs.language；'system' 按系统 locale 解析，复用不重写）。
// 语言切换广播经文件尾 l10nSignal.rev 自增（AppStorageV2 域；A5-T6 迁移，全项目
// 禁用 @StorageProp——V1 装饰器与 @ComponentV2 互斥）；@ComponentV2 build 内读
// l10nSignal.rev 即被 @Trace 追踪，切换语言自动重渲染。
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AppStorageV2 } from '@kit.ArkUI';
import { AppLanguage, LanguageManager } from '../store/LanguageManager';

/** 92 动物图标目录 + 24 预设底色（iOS PlanetIcon.catalog / IconPickerSheet.palette 直译） */
export class IconCatalog {
  /** 全部动物 key，顺序 = iOS PlanetIcon.swift catalog 数组。
   *  资源名映射：media/animal_<key.replace('-','_')>.png（restool 资源名只允许
   *  [a-zA-Z0-9_]，与 Android drawable 同构），如 dinosaur-rex → animal_dinosaur_rex。 */
  static readonly keys: string[] = [
    'ant', 'anteater', 'armadillo', 'badger', 'bat', 'beaver', 'bee', 'bird',
    'bison', 'boar', 'bug', 'bull', 'butterfly', 'camel', 'cat', 'cobra',
    'cow', 'crab', 'crow', 'deer', 'dinosaur-rex', 'dodo', 'dog', 'dolphin',
    'donkey', 'dove', 'dragon', 'dragonfly', 'duck', 'eel', 'elephant', 'fish',
    'flamingo', 'fox', 'frog', 'gecko', 'goat', 'goose', 'gorilla', 'hedgehog',
    'heron', 'hippo', 'horse', 'hummingbird', 'ibis', 'jellyfish', 'kangaroo',
    'kiwi-bird', 'koala', 'ladybug', 'lion', 'locust', 'mammoth', 'mole', 'monkey',
    'mosquito', 'octopus', 'ostrich', 'otter', 'owl', 'panda', 'penguin', 'pig',
    'piranha', 'polar-bear', 'rabbit', 'rattlesnake', 'raven', 'rodent', 'rooster',
    'scorpion', 'seahorse', 'seal', 'shark', 'sheep', 'shrimp', 'sloth', 'snail',
    'snake', 'sperm-whale', 'spider', 'squid', 'squirrel', 'swallow', 'swan', 'tiger',
    'tortoise', 'turkey', 'turtle', 'unicorn', 'vulture', 'worm',
  ];

  /** 预设底色 24 色（600/700 明度域按色相排列 + 三档中性灰），图标选择器染色用 */
  static readonly palette: string[] = [
    '#dc2626', '#e11d48', '#db2777', '#9f1239',
    '#ea580c', '#c2410c', '#d97706', '#ca8a04',
    '#65a30d', '#4d7c0f', '#16a34a', '#059669',
    '#0d9488', '#0891b2', '#0284c7', '#2563eb',
    '#1e40af', '#4f46e5', '#7c3aed', '#9333ea',
    '#c026d3', '#6b7280', '#475569', '#334155',
  ];
}

/** 语言码 → rawfile 路径 */
const LANG_FILES: Record<string, string> = {
  'en': 'i18n/en.json',
  'zh-Hans': 'i18n/zh-Hans.json',
  'zh-Hant': 'i18n/zh-Hant.json',
};

/** 语言切换信号（AppStorageV2 键 'l10n'；UI 侧 build 内读 rev 触发重算） */
@ObservedV2
export class L10nSignal {
  @Trace rev: number = 0;
}

/** 进程单例：模块导入即 connect（AppStorageV2 纯内存域，不依赖 UI 上下文） */
export const l10nSignal: L10nSignal =
  AppStorageV2.connect(L10nSignal, 'l10n', () => new L10nSignal())!;

export class L10n {
  private static tables: Record<string, Record<string, string>> = {};
  private static inited: boolean = false;

  /** 启动时调一次：rawfile 三语 JSON 入静态表（幂等） */
  static async init(ctx: common.Context): Promise<void> {
    if (L10n.inited) {
      return;
    }
    const rm = ctx.resourceManager;
    const codes: string[] = Object.keys(LANG_FILES);
    for (const code of codes) {
      const bytes = await rm.getRawFileContent(LANG_FILES[code]);
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      L10n.tables[code] = JSON.parse(text) as Record<string, string>;
    }
    L10n.inited = true;
    // init 异步完成晚于首帧时，裸 key 文案的组件依赖 rev 变更重算——
    // 落表即广播一次（评审 I1：确定性时序缺口，非真机项）
    L10n.notify();
  }

  /** 查表：当前语言 → en → 键本身（未 init/缺键逐级兜底） */
  static get(key: string): string {
    const code = LanguageManager.resolved() as string;
    const table = L10n.tables[code];
    if (table !== undefined && table[key] !== undefined) {
      return table[key];
    }
    const en = L10n.tables['en'];
    if (en !== undefined && en[key] !== undefined) {
      return en[key];
    }
    return key;
  }

  /** 语言切换广播：rev 自增触发依赖方重算 */
  static notify(): void {
    l10nSignal.rev += 1;
  }

  /**
   * 查表 + 占位符替换（iOS `loc("key \(arg)")` 直译）：表键含 iOS 格式符
   * （'home.network.header %lld' 等），按序把 %lld / %@ 替换为参数文本。
   * 未 init/缺键时 get() 回退裸键，替换循环找不到占位符即原样返回。
   */
  static format(key: string, args: (string | number)[]): string {
    let text = L10n.get(key);
    for (const a of args) {
      const num = text.indexOf('%lld');
      if (num >= 0) {
        text = text.slice(0, num) + String(a) + text.slice(num + 4);
        continue;
      }
      const any = text.indexOf('%@');
      if (any >= 0) {
        text = text.slice(0, any) + String(a) + text.slice(any + 2);
      }
    }
    return text;
  }

  /** 切语言：落 prefs（LanguageManager.set）+ 广播重渲染 */
  static async setLang(code: AppLanguage): Promise<void> {
    await LanguageManager.set(code);
    L10n.notify();
  }
}
