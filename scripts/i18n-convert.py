#!/usr/bin/env python3
"""xcstrings → 鸿蒙 rawfile 三语查表 JSON（A5 Task 1 资产管线，macOS host 跑）。

源（iOS 仓库，可用 PLANET_PORT_IOS 指定）：
  Shared/Localization/Localizable.xcstrings   356 键
  Modules/QRTransfer/Resources/QRTransfer.xcstrings  20 键（键自带 qrtransfer. 前缀）

产出（入库）：
  entry/src/main/resources/rawfile/i18n/{en,zh-Hans,zh-Hant}.json  扁平 {"键":"值"}

规则：
  - 取 strings.<key>.localizations.<lang>.stringUnit.value（state 全为 translated）。
  - 键某语言缺失 → 回退 en 值；连 en 都缺（无 localizations 的字面键，如 "-"、"%@"）
    → 值 = 键本身（iOS 渲染字面键即如此）。
  - 两表合并，键冲突视为致命错误（当前无冲突）。

用法：
  ./scripts/i18n-convert.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IOS = os.environ.get("PLANET_PORT_IOS", os.path.join(ROOT, "..", "planet-port-ios"))
OUT = os.path.join(ROOT, "entry", "src", "main", "resources", "rawfile", "i18n")

SOURCES = [
    os.path.join(IOS, "Shared", "Localization", "Localizable.xcstrings"),
    os.path.join(IOS, "Modules", "QRTransfer", "Resources", "QRTransfer.xcstrings"),
]
LANGS = ("en", "zh-Hans", "zh-Hant")

# 鸿蒙侧自有键（iOS xcstrings 无源——T12 root 查重降级告警文案）。脚本全量
# 再生成会冲掉手改，故合并在此处随管线持久化；三语键数一致性校验自动覆盖。
HARMONY_EXTRA = {
    "addplanet.rootConflictTitle": {
        "en": "Root Server Shared",
        "zh-Hans": "根服务器重叠",
        "zh-Hant": "根伺服器重疊",
    },
    "addplanet.rootConflictMessage %@": {
        "en": "This planet shares its root server with the existing planet “%@”. "
              "The import will continue.",
        "zh-Hans": "该行星与已有行星「%@」共享根服务器，将继续导入。",
        "zh-Hant": "該行星與已有行星「%@」共享根伺服器，將繼續匯入。",
    },
}


def unit_value(entry: dict, lang: str):
    """取 stringUnit.value；无该语言或结构不符返回 None。"""
    loc = entry.get("localizations", {}).get(lang)
    if not isinstance(loc, dict):
        return None
    unit = loc.get("stringUnit")
    if isinstance(unit, dict):
        return unit.get("value")
    return None


def main() -> int:
    merged: dict = {}
    conflicts = []
    stats = {}
    for path in SOURCES:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        strings = data.get("strings", {})
        stats[os.path.basename(path)] = len(strings)
        for key, entry in strings.items():
            if key in merged:
                conflicts.append(key)
                continue
            merged[key] = entry
    if conflicts:
        print(f"错误：跨表键冲突 {len(conflicts)} 个：{conflicts}", file=sys.stderr)
        return 1

    # 鸿蒙自有键合并（与 xcstrings 冲突同样视为致命错误）；归一成 xcstrings 的
    # localizations.stringUnit 形态，走同一条取值/校验管线
    for key, per_lang in HARMONY_EXTRA.items():
        if key in merged:
            print(f"错误：HARMONY_EXTRA 键与源表冲突：{key}", file=sys.stderr)
            return 1
        merged[key] = {
            "localizations": {
                lang: {"stringUnit": {"state": "translated", "value": v}}
                for lang, v in per_lang.items()
            }
        }

    total = len(merged)
    tables: dict = {lang: {} for lang in LANGS}
    fallback = {lang: 0 for lang in LANGS}
    literal = []
    for key, entry in merged.items():
        en = unit_value(entry, "en")
        for lang in LANGS:
            v = unit_value(entry, lang)
            if v is None:
                # 缺语 → 回退 en；en 也缺（字面键）→ 值 = 键本身
                v = en if en is not None else key
                fallback[lang] += 1
            tables[lang][key] = v
        if en is None:
            literal.append(key)

    os.makedirs(OUT, exist_ok=True)
    for lang in LANGS:
        out_path = os.path.join(OUT, f"{lang}.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(tables[lang], f, ensure_ascii=False, indent=2)
            f.write("\n")

    print(f"源键数：{stats}")
    print(f"合并键数：{total}")
    print(f"字面键（无任何语言，值=键本身）：{len(literal)} 个 {literal}")
    for lang in LANGS:
        print(f"{lang}: {len(tables[lang])} 键，回退填充 {fallback[lang]}")
    ok = all(len(tables[lang]) == total for lang in LANGS)
    print("三语键数一致：" + ("是" if ok else "否（异常）"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
