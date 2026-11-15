// native 模块 ArkTS 包装（Task 9 完整函数族；D2 粗粒度决策）
//
// 三族导出对应 native/napi/planetport_napi.cpp 的 Init 注册表（键名即契约，禁改）：
//   CoreRuntime — 核心版本号（主进程 + VpnExt 均可用）
//   ColorMath   — 主题色彩数学（pp::ColorMath 直通，纯函数无状态；ThemeManager 消费）
//   TunnelNapi  — 隧道编排（VpnExt 进程专用——native 侧为进程级单例，主进程禁调用）
//
// 硬契约（与 planetport_napi.cpp 头注释同源，T10 壳实现依赖）：
// ① swapFd(fd) 返回 false 时 fd 已被 Dataplane 闩锁关闭，调用方一律不得再 close
//    （double-close 是真实风险）；
// ② setCallbacks 的回调经 threadsafe function 跨线程投递，壳须容忍停机排空窗口内的
//    迟到 onEstablish（按幂等失败处理——壳内 create/swapFd 得到失败返回即可）；
// ③ protect 通道：壳注册处理器（setProtectHandler）后，native 在出口 socket 建立
//    时以 (fd, token) 调处理器；处理器完成后必须调 protectResult(token, ok)——
//    2s 内未应答 native 按放行处理（宁通勿断）。默认不注册 → 恒走 2s 超时放行，
//    壳需另行进程级 protect 一次调用兜底（UNVERIFIED-1 最稳假设）。
// ④ onEstablish 经 tsfn 投递的是 JSON 字符串（跨线程传对象一律字符串化），本层解析
//    后再回调壳——壳只见 EstablishRequest 类型。
import core from 'libplanetport_core.so';

/** establish 聚合请求（native 投递 JSON 串，本层解析；字段即契约，禁改） */
export interface EstablishRequest {
  v4Addrs: string[]; // "ip/prefix"
  v6Addrs: string[];
  routes4: string[]; // "dest/prefix"（A3 无网关表达——Expand 差集输出无 via）
  routes6: string[];
  dns: string[];
  mtu: number; // 网络声明值取最小；壳须 clamp [576,1500]
}

/** 隧道回调（壳一次性注册；native 持 threadsafe function 引用，stop/start 重入复用）。
 * 成员用属性式函数类型（非方法语法）——ArkTS 字面量对接显式接口时属性式最稳。 */
export interface TunnelCallbacks {
  /** 壳组 VpnConfig → create → swapFd（停机排空窗口可能迟到，见硬契约②） */
  onEstablish: (req: EstablishRequest) => void;
  /** 全部网络失效：壳 destroy VPN（runtime 实例保持可用） */
  onTeardown: () => void;
  /** 状态/快照已变化：壳拉 snapshot 落盘 + 发事件（level-triggered） */
  onStateChanged: () => void;
}

/**
 * protect 处理器：调 vpnConnection.protect(fd)（或壳的进程级等价物）。
 * 完成后必须调 TunnelNapi.protectResult(token, ok)：ok=true 放行发包；
 * ok=false → UdpCom 走绑定失败路径（Failed(udpBindFailed, recoverable)）；
 * 2s 内不调用则 native 超时放行。
 */
export type ProtectHandler = (fd: number, token: number) => void;

// native 侧原始回调形态（onEstablish 收 JSON 字符串；本文件内部约定，非导出面）
interface NativeTunnelCallbacks {
  onEstablish: (json: string) => void;
  onTeardown: () => void;
  onStateChanged: () => void;
}

export namespace CoreRuntime {
  export function getCoreVersion(): string {
    return core.getCoreVersion() as string;
  }
}

/** 主题色彩数学（pp::ColorMath 直通） */
export namespace ColorMath {
  /** 浅色 accent：原色（iOS ThemeManager.accent(light) 直译） */
  export function accentLight(mainHex: number): number {
    return core.accentLight(mainHex) as number;
  }

  /** 深色 accent：提亮度增饱和（s+0.2 clamp 1、l+0.14 clamp 0.72） */
  export function accentDark(mainHex: number): number {
    return core.accentDark(mainHex) as number;
  }

  /** 浅色成功色：主色 +120° 三角派生（s=max(0.6,s) l=0.32） */
  export function successLight(mainHex: number): number {
    return core.successLight(mainHex) as number;
  }

  /** 深色成功色：s=max(0.5,s*0.8) l=0.45 */
  export function successDark(mainHex: number): number {
    return core.successDark(mainHex) as number;
  }

  /** 行星装饰盘 8 元素（hue ±120° × 两档 + 两深色） */
  export function planetTints(mainHex: number): number[] {
    return core.planetTints(mainHex) as number[];
  }

  /** 主色 HSL：3 元素 [h, s, l]，h∈[0,360)、s/l∈[0,1]（ArkTS 无元组，定长数组承载） */
  export function hslOf(mainHex: number): number[] {
    return core.hslOf(mainHex) as number[];
  }
}

/** 隧道编排（VpnExt 进程专用） */
export namespace TunnelNapi {
  /** 装配启动：重复启动 false；装配失败 false 且置 Failed 终态（原因码以 snapshot() 为准） */
  export function start(configJson: string): boolean {
    return core.start(configJson) as boolean;
  }

  /** 幂等停机 */
  export function stop(): void {
    core.stop();
  }

  /** 进程内换代（stop+start 保配置；仅存活态生效） */
  export function restartCore(): void {
    core.restartCore();
  }

  /** establish 回应：false 时 fd 已被关闭（硬契约①），调用方不得再 close */
  export function swapFd(fd: number): boolean {
    return core.swapFd(fd) as boolean;
  }

  /** 热重配（join/leave/orbit 增量 + appliedEntries 比对）；未启动 no-op */
  export function applyConfig(configJson: string): void {
    core.applyConfig(configJson);
  }

  /** 壳 NetWatch 透出（写快照；仍发 onStateChanged 供壳落盘） */
  export function setPathSatisfied(ok: boolean): void {
    core.setPathSatisfied(ok);
  }

  /** TunnelSnapshot 契约 JSON（不含 pathSatisfied/writtenAt——写方注入） */
  export function snapshot(): string {
    return core.snapshot() as string;
  }

  /** 回调注册（壳一次性注册，VpnExt 进程生命周期内复用） */
  export function setCallbacks(cbs: TunnelCallbacks): void {
    const nativeCbs: NativeTunnelCallbacks = {
      onEstablish: (json: string): void => {
        const o: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
        const req: EstablishRequest = {
          v4Addrs: o['v4Addrs'] as string[],
          v6Addrs: o['v6Addrs'] as string[],
          routes4: o['routes4'] as string[],
          routes6: o['routes6'] as string[],
          dns: o['dns'] as string[],
          mtu: o['mtu'] as number,
        };
        cbs.onEstablish(req);
      },
      onTeardown: (): void => {
        cbs.onTeardown();
      },
      onStateChanged: (): void => {
        cbs.onStateChanged();
      },
    };
    core.setCallbacks(nativeCbs);
  }

  /** 注册 protect 处理器；null = 取消（回到默认态：2s 超时放行） */
  export function setProtectHandler(handler: ProtectHandler | null): void {
    core.setProtectHandler(handler);
  }

  /** protect 应答（处理器完成后必须调用；native 依此释放同步等待） */
  export function protectResult(token: number, ok: boolean): void {
    core.protectResult(token, ok);
  }
}
