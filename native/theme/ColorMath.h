// ColorMath.h — iOS ThemeManager 色彩数学直译（D13：host 金标单测覆盖）
//
// 直译源：PlanetPort/ThemeManager.swift（hsl:123-141 / hslToRgb:143-158 /
// accent:58-64 / success:66-74 / planetTints:76-90 / presets:9-18）。
// 只落纯数学（hex↔HSL↔派生 hex）；明暗双色由浅深两函数分别给出，
// ArkUI 动态明暗适配留 ArkTS 侧。
#pragma once
#include <cstdint>

namespace pp {

struct Hsl {
    double h; // [0,360)
    double s; // [0,1]
    double l; // [0,1]
};

// 通道四舍五入量化（Swift channel(): (v*255).rounded() 夹 [0,255]）
uint32_t rgbOfHsl(const Hsl &hsl);
Hsl hslOf(uint32_t hex);

// 预设主色板：默认红 + 7 国画经典色（ThemeManager.swift:9-18 逐值）
inline constexpr uint32_t THEME_PRESETS[8] = {
    0xD44037u, // 默认红
    0xFFB61Eu, // 藤黄
    0x789262u, // 竹青
    0x57C3C2u, // 石绿
    0x4C8DAEu, // 群青
    0x003472u, // 花青
    0x4A4266u, // 黛
    0x9D2933u, // 胭脂
};

// accent：浅色原色；深色提亮度增饱和（s+0.2 clamp 1、l+0.14 clamp 0.72）
uint32_t accentLight(uint32_t mainHex);
uint32_t accentDark(uint32_t mainHex);

// success：主色 +120° 三角派生；浅 s=max(0.6,s) l=0.32；深 s=max(0.5,s*0.8) l=0.45
uint32_t successLight(uint32_t mainHex);
uint32_t successDark(uint32_t mainHex);

// 行星装饰盘 8 色：hue{h,h+120,h+240} × (s.65 l.52 / s.55 l.68) + hue[1]/hue[2] (s.7 l.32)
void planetTints(uint32_t mainHex, uint32_t out[8]);

} // namespace pp
