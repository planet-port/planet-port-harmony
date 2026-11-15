// LanguageManager.ets — 应用语言（iOS LanguageManager 直译；查表机制换内嵌表）
//
// iOS 以 .environment(\.locale) 覆盖 SwiftUI 文案；鸿蒙 getStringSync 不支持
// 指定 locale（Global Constraints），应用内切换走 loc(key) 内嵌三语表。
// 表内容 A5 全量填充；本任务落机制 + 种子键。nativeName 以自身语言显示
// （不随界面语言变化），对齐 iOS nativeName。
import { i18n } from '@kit.LocalizationKit';
import { StoreRepo } from './StoreRepo';

export enum AppLanguage {
  System = 'system',
  ZhHans = 'zh-Hans',
  ZhHant = 'zh-Hant',
  En = 'en',
}

/** 各语言选项以自身名称显示；null = 走「跟随系统」文案键 */
export function nativeName(l: AppLanguage): string | null {
  switch (l) {
    case AppLanguage.System: return null;
    case AppLanguage.ZhHans: return '简体中文';
    case AppLanguage.ZhHant: return '繁體中文';
    case AppLanguage.En: return 'English';
  }
}

// 种子键（机制验证用；A5 按 iOS Localizable.xcstrings 356 键全量扩表）。
// 键名必须取金标键集内的真实键（评审 Important：brief 自拟的 app.name/
// lang.followSystem 不在 xcstrings 键集，沿用会使 A5 扩表整体改名、
// iOS↔harmony 键对应断裂）——「跟随系统」金标键为 prefs.language.system
// （iOS PrefsView.swift:76），app 名不走 loc 表
const TABLE_ZH_HANS: Record<string, string> = {
  'prefs.language.system': '跟随系统',
};
const TABLE_ZH_HANT: Record<string, string> = {
  'prefs.language.system': '跟隨系統',
};
const TABLE_EN: Record<string, string> = {
  'prefs.language.system': 'Follow system',
};

export class LanguageManager {
  private static currentLang: AppLanguage = AppLanguage.System;

  /** 启动时调一次（读 AppPrefs.language） */
  static async init(): Promise<void> {
    const prefs = await StoreRepo.store.readPrefs();
    const v = prefs.language;
    LanguageManager.currentLang = v === 'zh-Hans' || v === 'zh-Hant' || v === 'en'
      ? v as AppLanguage : AppLanguage.System;
  }

  static current(): AppLanguage { return LanguageManager.currentLang; }

  static async set(l: AppLanguage): Promise<void> {
    LanguageManager.currentLang = l;
    await StoreRepo.store.writePrefs(p => {
      p.language = l as string;
      return p;
    });
  }

  /** 按当前应用语言查表（未指定时回退系统语言）；缺键回退 zh-Hans 再回退 key */
  static loc(key: string): string {
    const sys = LanguageManager.systemLanguage();
    const lang = LanguageManager.currentLang === AppLanguage.System
      ? sys : LanguageManager.currentLang;
    const table = LanguageManager.tableFor(lang);
    return table[key] ?? TABLE_ZH_HANS[key] ?? key;
  }

  private static tableFor(l: AppLanguage): Record<string, string> {
    switch (l) {
      case AppLanguage.ZhHant: return TABLE_ZH_HANT;
      case AppLanguage.En: return TABLE_EN;
      default: return TABLE_ZH_HANS;
    }
  }

  /** 系统语言推断（zh-Hant/zh-HK/zh-TW → 繁体；zh* → 简体；其余 → en） */
  private static systemLanguage(): AppLanguage {
    const tag = LanguageManager.systemTag();
    if (tag.startsWith('zh')) {
      // script 子标签优先（评审：zh-Hans-HK 是简体+香港地区，按区域子串会
      // 误判繁体；iOS 经 script 子标签解析）；无 script 时才按 HK/TW/MO
      // 区域回退（兼容 zh-HK 等无 script 形态）
      if (tag.includes('Hant')) return AppLanguage.ZhHant;
      if (tag.includes('Hans')) return AppLanguage.ZhHans;
      return /HK|TW|MO/.test(tag) ? AppLanguage.ZhHant : AppLanguage.ZhHans;
    }
    return AppLanguage.En;
  }

  private static systemTag(): string {
    // @ohos.i18n System.getAppPreferredLanguage（同步、无权限）；
    // 取值形如 "zh-Hans-CN"。包一层便于单测替换。
    return I18nTags.preferred();
  }
}

/** 系统语言标签取值隔离点（ArkTS 无法注入，集中一处便于 A5 换资源方案） */
export class I18nTags {
  static preferred(): string {
    return i18n.System.getAppPreferredLanguage();
  }
}
