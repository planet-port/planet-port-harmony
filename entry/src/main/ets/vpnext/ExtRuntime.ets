// ExtRuntime.ets — NAPI 隧道函数族的扩展进程包装（D14 隔离面）
//
// 职责：config 组装（store → TunnelConfig JSON）、回调接线（onEstablish →
// VpnConfig 组装 → create → protectProcessNet → swapFd；onTeardown → destroy）、
// 重建/换代编排。start/applyConfig 入参 JSON 字段名即 native ParseTunnelConfig
// 契约（planetport_napi.cpp 头注释同源，禁改）。
//
// 身份直传（D11 裁决）：A2 否决设计文档的 runtime.json 中转——identity 不经
// 文件下发，core 构造参数（planetDir + identityPerPlanet）直传 + 独立模式切行
// 星时把共享身份 seed 到该行星目录（IdentityStore.seedSharedIdentity），对齐
// NodeRuntime 构造。
//
// 停机守卫（硬契约②的壳侧落地）：native 不拦截停机排空窗口内迟到的 onEstablish，
// 由本类 stopped/stopRequested 双标志收口——stopped 拦截迟到回调不再建 VPN；
// stopRequested 保证 CMD_STOP 收口后，在途的 CMD_RESTART 不复活隧道。
import { vpnExtension, VpnExtensionContext } from '@kit.NetworkKit';
import { TunnelNapi, EstablishRequest } from '../common/CoreRuntime';
import { StoreRepo } from '../store/StoreRepo';
import { IdentityStore } from '../store/IdentityStore';
import { ExtStateBus } from './ExtStateBus';

// start/applyConfig 入参 JSON 形态（ArkTS 字面量须显式类型承载；键名禁改）
interface TunnelConfigNetJson {
  nwid: string; // 16 位 hex 字符串（NAPI 侧 strtoull base16）
  routeViaZeroTier: boolean;
}

interface TunnelConfigMoonJson {
  worldId: number;
  seed: number;
}

interface TunnelConfigJson {
  dataStoreRoot: string;
  planetDir: string;
  planetFile: string; // 空 = 官方行星（无档案文件）
  identityPerPlanet: boolean;
  disableIpv6: boolean;
  networks: TunnelConfigNetJson[];
  moons: TunnelConfigMoonJson[];
}

export class ExtRuntime {
  private conn: vpnExtension.VpnConnection | null = null;
  private prefsDisableIpv6 = false; // start() 读 prefs 后快照（VpnConfig 组装用）
  /** 迟到回调守卫：停机/换代窗口内置 true——停机排空后送达的 onEstablish 在此
   * 拦截（硬契约②：native 不代为拦截，容忍语义由壳落地） */
  private stopped = true;
  /** CMD_STOP 粘滞标志：restartFromConfig 的 await 窗口内被 shutdown 收口时，
   * 换代重启放弃（停后不复活）；start() 时清除 */
  private stopRequested = false;
  private readonly ctx: VpnExtensionContext;
  private readonly bus: ExtStateBus;

  constructor(ctx: VpnExtensionContext, bus: ExtStateBus) {
    this.ctx = ctx; // ArkTS 禁构造器参数属性（arkts-no-ctor-prop-decls）
    this.bus = bus;
    // 回调一次性注册（硬契约④：进程生命周期内复用；评审 M1——原在 start() 内
    // 每轮 restart 重复注册，违背契约「一次性」且与停机守卫窗口交叠）。
    // 已知代价（NAPI 固有成本，非启动失败）：start() 在 JS 线程执行，首个
    // protect 同步段等满 2s 超时放行——tsfn 回调上不了被阻塞的 JS 线程
    TunnelNapi.setCallbacks({
      onEstablish: (req: EstablishRequest): void => { void this.establish(req); },
      onTeardown: (): void => { void this.teardownVpn(); },
      onStateChanged: (): void => { void this.bus.flush(); },
    });
  }

  /** 冷启动/重建：读 store → 身份 seed → NAPI start（幂等由 NAPI 保证） */
  async start(): Promise<void> {
    // 停后不复活（评审 F1）：两查 stopRequested——入口拦上轮已收口的 stop；
    // buildConfigJson 挂起窗口内 CMD_STOP 完成收口（shutdown 置位）时，本处
    // 恢复后丢弃启动，防 Stopped 终态被随后的 flush 覆盖为运行态
    if (this.stopRequested) return;
    const config = await this.buildConfigJson();
    if (this.stopRequested) return;
    // 守卫解除与核心装载同点：核心未起时放行的迟到 establish 只会在 swapFd
    // 拒绝上白建一条系统 VPN 连接，收口在守卫
    this.stopRequested = false;
    this.stopped = false;
    TunnelNapi.start(config);
  }

  /** CONFIG_CHANGED 接收端（主进程 fireConfig 双通道闭环）：重读 store → 序列化
   * → 热重配（join/leave/orbit 增量 + appliedEntries 比对；未启动 native no-op） */
  async applyConfigChange(): Promise<void> {
    const config = await this.buildConfigJson();
    TunnelNapi.applyConfig(config);
  }

  /** onEstablish：VpnConfig 组装（D8）→ create → protectProcessNet → swapFd */
  private async establish(req: EstablishRequest): Promise<void> {
    if (this.stopped) return; // 停机排空窗口迟到回调（硬契约②）
    const cfg = this.buildVpnConfig(req); // 组装提到 try 外：重试分支复用同一 config
    try {
      await this.establishOnce(cfg);
    } catch (_e) {
      // create 失败（含 2203002 已存在）→ 拆净重试一次；再失败保持 Starting，
      // 等下次 netconf 聚合重发（对齐 Android establish 失败不 Failed 语义）
      await this.destroyVpnQuiet();
      if (this.stopped) return;
      try {
        await this.establishOnce(cfg);
      } catch (_e2) { /* 放弃本次，等重发 */ }
    }
  }

  private async establishOnce(cfg: vpnExtension.VpnConfig): Promise<void> {
    if (this.conn !== null) {
      await this.destroyVpnQuiet(); // 换代（D3）：旧连接先拆（destroy + create）
    }
    const conn = vpnExtension.createVpnConnection(this.ctx);
    this.conn = conn;
    const fd = await conn.create(cfg);
    if (this.stopped) {
      // 停机窗口交错：连接已随 shutdown 的 destroy 拆链，这里补拆本次新建
      // （fd 随 vNIC 销毁由系统回收，不经 native 闩锁）
      await this.destroyVpnQuiet();
      return;
    }
    // 进程级 protect（D4/UNVERIFIED-1 最稳路径：一次调用护全进程 socket）；拒绝不阻断
    try { await conn.protectProcessNet(); } catch (_e) { /* 拒绝不阻断 */ }
    // 返回 false = fd 已被 Dataplane 闩锁分支关闭（硬契约①）——本侧一律不得再
    // close，也不据此报错（停机/换代拒绝属预期）
    TunnelNapi.swapFd(fd);
  }

  /** onTeardown：全部网络失效——destroy VPN（路由自动撤销），实例保持可用 */
  private async teardownVpn(): Promise<void> {
    await this.destroyVpnQuiet();
  }

  /** 切网自愈（D9）：destroy VPN → restartCore（C++ 内 stop+start 保配置）→
   * 等 netconf 重聚合 establish */
  async reconnectCore(): Promise<void> {
    await this.destroyVpnQuiet();
    TunnelNapi.restartCore();
  }

  /** CMD_RESTART：重读 store 起核（行星切换/偏好热生效路径） */
  async restartFromConfig(): Promise<void> {
    this.stopped = true; // 换代窗口屏蔽迟到 onEstablish（start() 内解除）
    TunnelNapi.stop();
    await this.destroyVpnQuiet();
    if (this.stopRequested) return; // 窗口内被 CMD_STOP 收口——停后不复活
    await this.start();
  }

  async shutdown(): Promise<void> {
    this.stopped = true;
    this.stopRequested = true;
    TunnelNapi.stop(); // 先停数据面消费线程（native UAF 防护内化于 C++ 析构序）
    await this.destroyVpnQuiet();
  }

  /** UNVERIFIED-2：不依赖系统回收，显式 destroy；置 null 先行（重入幂等） */
  private async destroyVpnQuiet(): Promise<void> {
    const conn = this.conn;
    if (conn !== null) {
      this.conn = null;
      try { await conn.destroy(); } catch (_e) { /* 已销毁 */ }
    }
  }

  // ---- VpnConfig 组装 helper（RouteInfo.interface 填法集中此一处，UNVERIFIED-3） ----

  /** start() 时快照（核心构造参数语义，对齐 NodeRuntime） */
  private disableIpv6Effective(): boolean {
    return this.prefsDisableIpv6;
  }

  private buildVpnConfig(req: EstablishRequest): vpnExtension.VpnConfig {
    const noIpv6 = this.disableIpv6Effective();
    const addresses: Array<vpnExtension.LinkAddress> = [];
    for (const a of req.v4Addrs) {
      addresses.push(this.linkAddress(a, 1));
    }
    if (!noIpv6) {
      for (const a of req.v6Addrs) {
        addresses.push(this.linkAddress(a, 2));
      }
    }
    const routes: Array<vpnExtension.RouteInfo> = [];
    for (const r of req.routes4) {
      routes.push(this.routeInfo(r, 1));
    }
    if (!noIpv6) {
      for (const r of req.routes6) {
        routes.push(this.routeInfo(r, 2));
      }
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      // VpnConfig 硬性范围 [576,1500] clamp（D8；核心聚合给原始网络声明值）
      mtu: Math.max(576, Math.min(1500, req.mtu)),
      isIPv4Accepted: true,
      isIPv6Accepted: !noIpv6,
      isInternal: false,
      isBlocking: false,
    };
    if (req.dns.length > 0) {
      config.dnsAddresses = req.dns;
    }
    return config;
  }

  /** store → TunnelConfig JSON（start 与 CONFIG_CHANGED 共用一路组装） */
  private async buildConfigJson(): Promise<string> {
    const store = StoreRepo.store;
    const planetId = await store.activePlanetId();
    const planets = await store.readPlanets();
    const planet = planets.find(p => p.id === planetId) ?? null;
    const prefs = await store.readPrefs();
    this.prefsDisableIpv6 = prefs.disableIpv6; // VpnConfig 组装快照接线（brief 收口点）
    const networks = await store.readActiveNetworks();
    const moons = await store.readActiveMoons();
    // 身份分流（D11 裁决）：独立模式切行星须把共享身份 seed 到该行星目录（核心
    // 构造读那里）；独立/共享均经构造参数直传，无 runtime.json 中转。
    // CONFIG_CHANGED 路径此调用为廉价 no-op（已有独立身份即返回；prefs 的
    // identityPerPlanet 变更走静默写 + CMD_RESTART 编排，不经 fireConfig）
    if (prefs.identityPerPlanet) {
      await IdentityStore.seedSharedIdentity(store.paths, planetId);
    }
    const config: TunnelConfigJson = {
      dataStoreRoot: store.paths.dataStoreRoot,
      planetDir: store.paths.planetStateDir(planetId),
      planetFile: planet !== null && planet.fileName !== null
        ? `${store.paths.planetsDir}/${planet.fileName}` : '',
      identityPerPlanet: prefs.identityPerPlanet,
      disableIpv6: prefs.disableIpv6,
      networks: networks.map((n): TunnelConfigNetJson =>
        ({ nwid: n.networkId, routeViaZeroTier: n.routeViaZeroTier })),
      moons: moons.map((m): TunnelConfigMoonJson =>
        ({ worldId: m.worldId, seed: m.seed })),
    };
    return JSON.stringify(config);
  }

  /** "dest/prefix" 前缀段解析（缺省/非数值按 family 缺省：v4/32、v6/64） */
  private prefixLengthOf(cidr: string, slashIdx: number, family: number): number {
    if (slashIdx < 0) {
      return family === 1 ? 32 : 64;
    }
    const text = cidr.substring(slashIdx + 1);
    const parsed = Number(text);
    return text.length > 0 && !Number.isNaN(parsed) ? parsed : (family === 1 ? 32 : 64);
  }

  /** "ip/prefix" → LinkAddress（prefix 缺省按 family 直译 NetworkContextMath 语义） */
  private linkAddress(cidr: string, family: number): vpnExtension.LinkAddress {
    const slash = cidr.indexOf('/');
    const addr = slash >= 0 ? cidr.substring(0, slash) : cidr;
    const la: vpnExtension.LinkAddress = {
      address: { address: addr, family: family },
      prefixLength: this.prefixLengthOf(cidr, slash, family),
    };
    return la;
  }

  /** "dest/prefix [via gw]" → RouteInfo（hasGateway 由 via 段判定；A3 差集输出
   * 无 via，解析保留 brief 形态以兼容核心侧网关表达） */
  private routeInfo(route: string, family: number): vpnExtension.RouteInfo {
    const viaIdx = route.indexOf(' via ');
    const dest = viaIdx >= 0 ? route.substring(0, viaIdx) : route;
    const gw = viaIdx >= 0 ? route.substring(viaIdx + 5) : '';
    const slash = dest.indexOf('/');
    const addr = slash >= 0 ? dest.substring(0, slash) : dest;
    const ri: vpnExtension.RouteInfo = {
      interface: '', // UNVERIFIED-3：先空串（Spike 验证；被拒则改 vNIC 名——集中此一处）
      destination: {
        address: { address: addr, family: family },
        prefixLength: this.prefixLengthOf(dest, slash, family),
      },
      gateway: { address: gw === '' ? '0.0.0.0' : gw, family: family },
      hasGateway: gw !== '',
      isDefaultRoute: false, // ZT 路由皆为具体网段，非默认路由（SDK 必填字段）
    };
    return ri;
  }
}
