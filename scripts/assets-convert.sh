#!/bin/sh
# A5 资产管线：92 动物图标 + 三语查表（macOS host 一次性工具，产物入库）。
#
# 用法：./scripts/assets-convert.sh
# iOS 源仓库默认 ../planet-port-ios，可用 PLANET_PORT_IOS=<路径> 覆盖。
#
# 图标：iOS Assets.xcassets 的 animal-<key>.imageset/<key>.pdf（白色烧入矢量）
#   → entry/src/main/resources/base/media/animal_<key>.png（256×256，透明底白 glyph）。
#   资源名只允许 [a-zA-Z0-9_]（restool 约束，animal-ant 连字符报错 11211116），
#   key 中 '-' 归一为 '_'（animal-dinosaur-rex → animal_dinosaur_rex），与 Android
#   drawable 命名同构；消费侧 PlanetIcon.ets 同规则 replace('-','_') 还原。
#   glyph 形状存于 alpha 通道（UI 经 colorFilter 按 tintHex 染色，Android VectorDrawable
#   + tint 同构）。不用 qlmanage：其缩略把整图压成不透明纯白块，alpha 形状丢失。
#   用 ImageMagick 透明渲染（矢量栅格化密度 16 倍基准）后居中缩放进 256×256 画布
#   （8 个源 PDF 非正方形，需补画布保持 glyph 等比）。
#   依赖：brew install imagemagick ghostscript
#
# 文案：scripts/i18n-convert.py（xcstrings → rawfile/i18n/{en,zh-Hans,zh-Hant}.json）。
set -eu

cd "$(git rev-parse --show-toplevel)"
IOS="${PLANET_PORT_IOS:-$PWD/../planet-port-ios}"
XCAT="$IOS/PlanetPort/Assets.xcassets"
MEDIA="entry/src/main/resources/base/media"

command -v magick >/dev/null 2>&1 ||
  { echo "缺 ImageMagick：brew install imagemagick ghostscript" >&2; exit 1; }

mkdir -p "$MEDIA"
# 清掉旧命名（连字符版本，资源名校验不过）
rm -f "$MEDIA"/animal-*.png
count=0
fail=0
for set_dir in "$XCAT"/animal-*.imageset; do
  name="$(basename "$set_dir" .imageset)"
  key="${name#animal-}"
  res_key="$(printf '%s' "$key" | tr '-' '_')"
  pdf="$set_dir/$name.pdf"
  [ -f "$pdf" ] || pdf="$(find "$set_dir" -name '*.pdf' | head -n 1)"
  out="$MEDIA/animal_${res_key}.png"
  magick -background none -density 1152 "$pdf" \
    -resize 256x256 -gravity center -extent 256x256 "$out"
  # 逐个确认 256×256、非零字节
  size="$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null |
    awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
  bytes="$(wc -c < "$out" | tr -d ' ')"
  if [ "$size" != "256x256" ] || [ "$bytes" = "0" ]; then
    echo "FAIL $(basename "$out") size=$size bytes=$bytes" >&2
    fail=$((fail + 1))
  fi
  count=$((count + 1))
done
echo "icons: ${count}（异常 ${fail}）"

python3 scripts/i18n-convert.py
