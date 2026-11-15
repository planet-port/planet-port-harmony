// anchor.cpp — hvigor native 任务启用锚点
//
// hvigor 以「模块 src/main/ 下存在 cpp 目录」判定模块含 C++ 源码
// （core-source-set-impl.js initCodeMap 的目录探测），仅配置
// externalNativeOptions 不触发 ConfigureCmake 真正执行。
// 实际 C++ 源码位于仓库顶层 native/（见 entry/build-profile.json5
// 的 externalNativeOptions.path），本文件加入 planetport_core 编译集，
// 同时满足 hvigor 探测与编译完整性（空翻译单元，无符号）。
