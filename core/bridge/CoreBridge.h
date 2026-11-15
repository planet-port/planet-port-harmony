// CoreBridge — ZeroTier C API 的 C++ 包装（直译自 iOS ZTBridge.mm 的最小骨架）。
// A2 阶段扩展：节点生命周期、行星状态目录重定向 hook、身份按行星分流。
#pragma once

namespace pp {

// ZeroTier 核心版本号（ZT_version），如 "1.16.2"
const char *coreVersion();

} // namespace pp
