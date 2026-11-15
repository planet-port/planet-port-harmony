// ColorMath.cpp — 实现体（公式逐行对照 ThemeManager.swift）
#include "theme/ColorMath.h"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pp {

// channel(): (v*255).rounded() 夹 [0,255]；Swift .rounded() 默认
// toNearestOrAwayFromZero，与 std::lround 语义一致
static uint32_t quant(double v) {
    long x = std::lround(v * 255.0);
    if (x < 0) x = 0;
    if (x > 255) x = 255;
    return uint32_t(x);
}

// hslToRgb（ThemeManager.swift:143-158）：switch 区间 ..<1..<5/default 直译为 if 链
uint32_t rgbOfHsl(const Hsl &hsl) {
    double h = hsl.h / 60.0;
    double c = (1.0 - std::fabs(2.0 * hsl.l - 1.0)) * hsl.s;
    double x = c * (1.0 - std::fabs(std::fmod(h, 2.0) - 1.0));
    double m = hsl.l - c / 2.0;
    double r, g, b;
    if (h < 1) { r = c; g = x; b = 0; }
    else if (h < 2) { r = x; g = c; b = 0; }
    else if (h < 3) { r = 0; g = c; b = x; }
    else if (h < 4) { r = 0; g = x; b = c; }
    else if (h < 5) { r = x; g = 0; b = c; }
    else { r = c; g = 0; b = x; }
    return (quant(r + m) << 16) | (quant(g + m) << 8) | quant(b + m);
}

// hsl（ThemeManager.swift:123-141）
Hsl hslOf(uint32_t hex) {
    double r = ((hex >> 16) & 0xff) / 255.0;
    double g = ((hex >> 8) & 0xff) / 255.0;
    double b = (hex & 0xff) / 255.0;
    double maxC = std::max({r, g, b}), minC = std::min({r, g, b});
    double l = (maxC + minC) / 2.0;
    if (maxC == minC) return Hsl{0.0, 0.0, l};
    double d = maxC - minC;
    double s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
    double h;
    if (maxC == r) h = ((g - b) / d + (g < b ? 6.0 : 0.0)) * 60.0;
    else if (maxC == g) h = ((b - r) / d + 2.0) * 60.0;
    else h = ((r - g) / d + 4.0) * 60.0;
    return Hsl{h, s, l};
}

uint32_t accentLight(uint32_t mainHex) { return mainHex; }

// accent dark（ThemeManager.swift:63）
uint32_t accentDark(uint32_t mainHex) {
    Hsl b = hslOf(mainHex);
    return rgbOfHsl(Hsl{b.h, std::min(1.0, b.s + 0.2), std::min(0.72, b.l + 0.14)});
}

// truncatingRemainder(dividingBy:) 对正数即 fmod（h+120 可达 480，需先 %360）
static double huePlus(double base, double deg) {
    return std::fmod(base + deg, 360.0);
}

// success（ThemeManager.swift:67-74）
uint32_t successLight(uint32_t mainHex) {
    Hsl b = hslOf(mainHex);
    return rgbOfHsl(Hsl{huePlus(b.h, 120.0), std::max(0.6, b.s), 0.32});
}

uint32_t successDark(uint32_t mainHex) {
    Hsl b = hslOf(mainHex);
    return rgbOfHsl(Hsl{huePlus(b.h, 120.0), std::max(0.5, b.s * 0.8), 0.45});
}

// planetTints（ThemeManager.swift:77-90）
void planetTints(uint32_t mainHex, uint32_t out[8]) {
    Hsl base = hslOf(mainHex);
    double hues[3] = {base.h, huePlus(base.h, 120.0), huePlus(base.h, 240.0)};
    for (int i = 0; i < 3; i++) out[i] = rgbOfHsl(Hsl{hues[i], 0.65, 0.52});
    for (int i = 0; i < 3; i++) out[3 + i] = rgbOfHsl(Hsl{hues[i], 0.55, 0.68});
    out[6] = rgbOfHsl(Hsl{hues[1], 0.7, 0.32});
    out[7] = rgbOfHsl(Hsl{hues[2], 0.7, 0.32});
}

} // namespace pp
