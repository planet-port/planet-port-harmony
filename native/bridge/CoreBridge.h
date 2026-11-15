// CoreBridge — ZeroTier C API 的 C++ 包装（直译自 iOS ZTBridge.mm 的最小骨架）。
// A2 阶段扩展：节点生命周期、行星状态目录重定向 hook、身份按行星分流。
#pragma once

namespace pp {

// ZeroTier 核心版本号（ZT_version），如 "1.16.2"
const char *coreVersion();

// 生成节点身份到 homeDir/identity.secret（已存在则复用）。
// 返回 10 位节点地址（小写十六进制字符串，对齐核心 Address::toString 规范形式）；失败返回空串。
// 注：1.16.2 的 ZT_Node_new 走 ZT_Node_Callbacks 状态回调存取身份；
// 冒烟阶段状态回调为空实现，身份仅存内存（每次运行新生成），
// 真正的 identity.secret 落盘复用在 A2 阶段实现。
const char *smokeIdentityGen(const char *homeDir);

} // namespace pp
