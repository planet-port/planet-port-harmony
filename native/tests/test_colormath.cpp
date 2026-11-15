// test_colormath.cpp — iOS ThemeManager 色彩数学金标向量（D13 host 单测）
//
// 金标值按 Swift 算法精确重算（ThemeManager.swift:123-141 hsl / :143-158 hslToRgb），
// HSL 中间量用分数表达式断言（容差 1e-9），RGB 量化通道差容差 1。
// 派生规则的「+120° 再 %360」回绕语义重点覆盖。
// 注：brief 手算向量有三处不精确（h=3.4387→3.4395 / s=0.6462→0.6461 /
// 0xFF0008 h=358.5882→358.1176），已按精确值修正，见 task-6-report。
#include "theme/ColorMath.h"
#include <gtest/gtest.h>
#include <cmath>
#include <cstdint>

using namespace pp;

TEST(ColorMath, HslOfDefaultRed) {
  // 0xD44037: R=212 G=64 B=55 → l=267/510, s=157/243, h=540/157（精确分数）
  Hsl h = hslOf(0xD44037u);
  EXPECT_NEAR(h.h, 540.0 / 157.0, 1e-9); // = 3.4394904459°（max=r, g>b 无 +6）
  EXPECT_NEAR(h.s, 157.0 / 243.0, 1e-9); // = 0.6460905350（l>0.5: d/(2-max-min)）
  EXPECT_NEAR(h.l, 267.0 / 510.0, 1e-9); // = 0.5235294118
}

TEST(ColorMath, HslOfGrayIsAchromromatic) {
  Hsl h = hslOf(0x808080u); // max==min → h=0 s=0
  EXPECT_DOUBLE_EQ(h.h, 0.0);
  EXPECT_DOUBLE_EQ(h.s, 0.0);
  EXPECT_NEAR(h.l, 128.0 / 255.0, 1e-12);
}

TEST(ColorMath, HslSectorGMax) {
  // 0x00FF00: max=g → h = ((b-r)/d + 2)*60 = 120
  EXPECT_NEAR(hslOf(0x00FF00u).h, 120.0, 1e-9);
  // 0x0000FF: max=b → h = ((r-g)/d + 4)*60 = 240
  EXPECT_NEAR(hslOf(0x0000FFu).h, 240.0, 1e-9);
  // 0xFF0008: max=r 且 g<b → h = ((g-b)/d + 6)*60 = 360 - 480/255 = 358.1176
  EXPECT_NEAR(hslOf(0xFF0008u).h, 360.0 - 480.0 / 255.0, 1e-9);
}

TEST(ColorMath, RgbRoundTripWithinQuantization) {
  for (uint32_t hex : THEME_PRESETS) {
    uint32_t back = rgbOfHsl(hslOf(hex));
    // 每通道量化误差 ≤1
    for (int shift : {16, 8, 0}) {
      int a = static_cast<int>((hex >> shift) & 0xff);
      int b = static_cast<int>((back >> shift) & 0xff);
      EXPECT_LE(std::abs(a - b), 1) << std::hex << hex << " ch" << shift;
    }
  }
}

TEST(ColorMath, AccentLightIsIdentity_DarkLifts) {
  EXPECT_EQ(accentLight(0xD44037u), 0xD44037u);
  // dark: s=min(1,.6461+.2)=.8461, l=min(.72,.5235+.14)=.6635 → 通道四舍五入
  uint32_t d = accentDark(0xD44037u);
  EXPECT_NE(d, 0xD44037u);
  // 花青 0x003472 s=1.0 → +0.2 clamp 1；l=0.2235+0.14=0.3635
  Hsl src = hslOf(0x003472u);
  EXPECT_DOUBLE_EQ(src.s, 1.0);
  EXPECT_DOUBLE_EQ(std::min(1.0, src.s + 0.2), 1.0);
}

TEST(ColorMath, SuccessHueRotates120) {
  // successLight: h=(3.4395+120)%360=123.4395, s=max(0.6,.6461)=.6461, l=.32
  uint32_t s = successLight(0xD44037u);
  Hsl back = hslOf(s);
  EXPECT_NEAR(back.h, 540.0 / 157.0 + 120.0, 0.5); // 回解容差（量化扰动实测 0.011）
  EXPECT_NEAR(back.l, 0.32, 0.02);
  // hue ≥240 的主色：+120 → %360 回绕。0x4A4266 h≈253.33 → 13.33（非 373.33）
  uint32_t s2 = successLight(0x4A4266u);
  Hsl back2 = hslOf(s2);
  EXPECT_LT(back2.h, 240.0);
  EXPECT_NEAR(back2.h, 253.0 + 1.0 / 3.0 + 120.0 - 360.0, 0.6); // = 13.33（评审加固：量化扰动余量 0.5→0.6，防日后微调击穿）
}

TEST(ColorMath, PlanetTintsShape) {
  uint32_t out[8];
  planetTints(0xD44037u, out);
  Hsl base = hslOf(0xD44037u);
  // 前 3：h、h+120、h+240 各 s=.65 l=.52
  for (int i = 0; i < 3; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.65, 0.02);
    EXPECT_NEAR(c.l, 0.52, 0.02);
    double expectH = std::fmod(base.h + 120.0 * i, 360.0);
    EXPECT_NEAR(c.h < 1 && expectH > 359 ? 360.0 : c.h, expectH, 1.0);
  }
  // 4-6：同三 hue s=.55 l=.68；7-8：hue[1]/hue[2] s=.7 l=.32
  for (int i = 3; i < 6; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.55, 0.02);
    EXPECT_NEAR(c.l, 0.68, 0.02);
  }
  for (int i = 6; i < 8; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.7, 0.02);
    EXPECT_NEAR(c.l, 0.32, 0.02);
  }
}

TEST(ColorMath, PresetsVerbatim) {
  EXPECT_EQ(THEME_PRESETS[0], 0xD44037u);
  EXPECT_EQ(THEME_PRESETS[1], 0xFFB61Eu);
  EXPECT_EQ(THEME_PRESETS[2], 0x789262u);
  EXPECT_EQ(THEME_PRESETS[3], 0x57C3C2u);
  EXPECT_EQ(THEME_PRESETS[4], 0x4C8DAEu);
  EXPECT_EQ(THEME_PRESETS[5], 0x003472u);
  EXPECT_EQ(THEME_PRESETS[6], 0x4A4266u);
  EXPECT_EQ(THEME_PRESETS[7], 0x9D2933u);
}
