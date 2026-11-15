// AppConfigStore.ets — 四份 JSON 域 API + 变更信号（直译 store/AppConfigStore.kt）
//
// 两路信号语义（订阅方 level-triggered 全量重读，不保证逐次送达）：
//   configChanged：networks/moons 写删、deletePlanet → 隧道热重配 + UI 刷新；
//     进程内 listener 之外追加 commonEvent CONFIG_CHANGED 唤醒 VpnExt 重读（D5）。
//     deletePlanet 同时经 writePlanetsLocked 发 planetsChanged（Kotlin 双发）。
//   planetsChanged：行星表字段变更 + notifyIdentityChanged → 仅 UI 刷新，
//     不触发隧道；首启 bootstrap 直写文件不经信号（无杂散发射）。
//   writePrefs/selectPlanet/activatePlanet/resetAllNetworkActivation：完全静默，
//   热生效由调用方显式编排（TunnelController.restartIfRunning）。
import { commonEventManager } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import { IpcEvents } from '../common/IpcEvents';
import { PlanetProfile, PlanetKind, NetworkEntry, MoonEntry, AppPrefs } from './Models';
import { StorePaths } from './StorePaths';
import { JsonFileStore } from './JsonFileStore';

type ChangeCb = () => void;

export class AppConfigStore {
  readonly paths: StorePaths;
  private files: JsonFileStore = new JsonFileStore();
  private configListeners: Set<ChangeCb> = new Set();
  private planetsListeners: Set<ChangeCb> = new Set();
  private bootstrapped = false;

  constructor(paths: StorePaths) { this.paths = paths; }

  // ---- 信号 ----

  onConfigChanged(cb: ChangeCb): () => void {
    this.configListeners.add(cb);
    return () => this.configListeners.delete(cb);
  }

  onPlanetsChanged(cb: ChangeCb): () => void {
    this.planetsListeners.add(cb);
    return () => this.planetsListeners.delete(cb);
  }

  // ---- 域锁内复合读改写（Kotlin mutate { } 直译） ----

  async mutate<T>(block: () => Promise<T>): Promise<T> {
    return this.files.mutate(block);
  }

  // ---- planets ----

  async readPlanets(): Promise<PlanetProfile[]> {
    await this.bootstrap();
    const list = await this.readListFile(this.paths.planetsFile, PlanetProfile.fromJson);
    return list === null || list.length === 0 ? [PlanetProfile.OFFICIAL] : list;
  }

  async writePlanets(profiles: PlanetProfile[]): Promise<void> {
    await this.mutate(() => this.writePlanetsLocked(profiles));
  }

  /** official 永在最前；档案本体以既有条目为准（缺失才用固定 OFFICIAL 兜底） */
  private async writePlanetsLocked(profiles: PlanetProfile[]): Promise<void> {
    const existing = await this.readPlanets();
    const merged: PlanetProfile[] = [];
    const official = profiles.find(p => p.id === PlanetProfile.OFFICIAL_ID)
      ?? existing.find(p => p.id === PlanetProfile.OFFICIAL_ID)
      ?? PlanetProfile.OFFICIAL;
    merged.push(official);
    for (const p of profiles) {
      if (p.id !== PlanetProfile.OFFICIAL_ID) merged.push(p);
    }
    await this.writeListFile(this.paths.planetsFile, merged.map(p => p.toJson()));
    this.firePlanets();
  }

  /** 身份相关行星字段变更（非 suspend，对齐 notifyIdentityChanged） */
  notifyIdentityChanged(): void { this.firePlanets(); }

  // ---- 行星指针 ----

  async selectedPlanetId(): Promise<string> {
    const prefs = await this.readPrefs();
    const planets = await this.readPlanets();
    return planets.some(p => p.id === prefs.selectedPlanetId)
      ? prefs.selectedPlanetId : PlanetProfile.OFFICIAL_ID;
  }

  async activePlanetId(): Promise<string> {
    const prefs = await this.readPrefs();
    if (prefs.activePlanetId === null) return PlanetProfile.OFFICIAL_ID;
    const planets = await this.readPlanets();
    return planets.some(p => p.id === prefs.activePlanetId)
      ? prefs.activePlanetId as string : PlanetProfile.OFFICIAL_ID;
  }

  async hasActivatedPlanet(): Promise<boolean> {
    return (await this.readPrefs()).activePlanetId !== null;
  }

  /** id 不存在 no-op；只写 selected，不发任何信号 */
  async selectPlanet(id: string): Promise<void> {
    const planets = await this.readPlanets();
    if (!planets.some(p => p.id === id)) return;
    await this.writePrefs(p => { p.selectedPlanetId = id; return p; });
  }

  /** 返回 changed（写前比对）；不发 configChanges（重启编排归调用方） */
  async activatePlanet(id: string): Promise<boolean> {
    const planets = await this.readPlanets();
    if (!planets.some(p => p.id === id)) return false;
    const changed = await this.activePlanetId() !== id;
    await this.writePrefs(p => { p.activePlanetId = id; return p; });
    return changed;
  }

  async deletePlanet(profile: PlanetProfile): Promise<void> {
    if (profile.kind !== PlanetKind.Custom) return; // 直译：仅 custom 生效
    await this.mutate(async () => {
      const planets = (await this.readPlanets())
        .filter(p => p.id !== profile.id);
      const wasSelected = await this.selectedPlanetId() === profile.id;
      const wasActive = await this.activePlanetId() === profile.id;
      // raw 全表读再过滤（评审 Critical：readNetworks(null) 的 null 会解析为
      // selectedPlanetId 并预过滤，拿到的是选中行星的条目而非全表——写回即丢
      // 其他行星数据。对齐 Kotlin readNetworksFile().orEmpty().filterNot）
      const networks = (await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [])
        .filter(n => n.planetId !== profile.id);
      const moons = (await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [])
        .filter(m => m.planetId !== profile.id);
      // 经 writePlanetsLocked（评审 Important：直写绕过它 → 不发 planetsChanges，
      // 行星列表 UI 删除后不刷新；Kotlin 双发 planetsChanges + configChanges。
      // 合并逻辑对已过滤列表幂等：official 兜底在最前 + 过滤后条目）
      await this.writePlanetsLocked(planets);
      await this.writeListFile(this.paths.networksFile, networks.map(n => n.toJson()));
      await this.writeListFile(this.paths.moonsFile, moons.map(m => m.toJson()));
      if (profile.fileName !== null) {
        await this.unlinkQuiet(`${this.paths.planetsDir}/${profile.fileName}`);
      }
      await this.rmdirR(this.paths.planetStateDir(profile.id));
      if (wasSelected) {
        // 等价 Kotlin selectPlanetLocked(OFFICIAL_ID)：读-改字段-写回
        const prefs = await this.readPrefs();
        prefs.selectedPlanetId = PlanetProfile.OFFICIAL_ID;
        await this.writePrefsLocked(prefs);
      }
      if (wasActive) {
        // 对齐 Kotlin activatePlanetLocked(OFFICIAL_ID)：置 OFFICIAL_ID 而非 null
        // （评审 Minor-4：置 null 会让 hasActivatedPlanet 被误重置——Kotlin 置
        // 'official' 保留「用过」语义；activePlanetId() 读侧两者回退一致）
        const prefs = await this.readPrefs();
        prefs.activePlanetId = PlanetProfile.OFFICIAL_ID;
        await this.writePrefsLocked(prefs);
      }
    });
    this.fireConfig(); // 末尾统一通知（对齐 Kotlin：deletePlanet 是唯一发 configChanges 的复合操作）
  }

  // ---- networks ----

  async readNetworks(planetId: string | null = null): Promise<NetworkEntry[]> {
    const id = planetId ?? await this.selectedPlanetId();
    const list = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson);
    return (list ?? []).filter(n => n.planetId === id);
  }

  async readNetworksByPlanet(): Promise<Map<string, NetworkEntry[]>> {
    const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
    const map = new Map<string, NetworkEntry[]>();
    for (const n of all) {
      if (n.planetId === null) continue;
      const arr = map.get(n.planetId) ?? [];
      arr.push(n);
      map.set(n.planetId, arr);
    }
    return map;
  }

  async readActiveNetworks(): Promise<NetworkEntry[]> {
    return this.readNetworks(await this.activePlanetId());
  }

  /** 整组替换：旧表中该行星条目全删 + 新表打 planetId 写回 */
  async writeNetworks(values: NetworkEntry[], planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const old = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      const kept = old.filter(n => n.planetId !== id);
      for (const v of values) v.planetId = id;
      await this.writeListFile(this.paths.networksFile,
        [...kept, ...values].map(n => n.toJson()));
    });
    this.fireConfig();
  }

  async deleteNetwork(networkId: string, planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      const kept = all.filter(n => !(n.planetId === id && n.networkId === networkId));
      await this.writeListFile(this.paths.networksFile, kept.map(n => n.toJson()));
    });
    this.fireConfig();
  }

  /** 若无任何 lastActivated=true 直接 return（不写盘）；全量置 false 写回；静默 */
  async resetAllNetworkActivation(): Promise<void> {
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      if (!all.some(n => n.lastActivated)) return;
      for (const n of all) n.lastActivated = false;
      await this.writeListFile(this.paths.networksFile, all.map(n => n.toJson()));
    });
  }

  // ---- moons ----

  async readMoons(planetId: string | null = null): Promise<MoonEntry[]> {
    const id = planetId ?? await this.selectedPlanetId();
    const list = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson);
    return (list ?? []).filter(m => m.planetId === id);
  }

  async readAllMoons(): Promise<MoonEntry[]> {
    return await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
  }

  async readActiveMoons(): Promise<MoonEntry[]> {
    return this.readMoons(await this.activePlanetId());
  }

  async writeMoons(values: MoonEntry[], planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const old = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
      const kept = old.filter(m => m.planetId !== id);
      for (const v of values) v.planetId = id;
      await this.writeListFile(this.paths.moonsFile,
        [...kept, ...values].map(m => m.toJson()));
    });
    this.fireConfig();
  }

  async deleteMoon(worldId: number, planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
      const kept = all.filter(m => !(m.planetId === id && m.worldId === worldId));
      await this.writeListFile(this.paths.moonsFile, kept.map(m => m.toJson()));
    });
    this.fireConfig();
  }

  // ---- prefs ----

  async readPrefs(): Promise<AppPrefs> {
    const text = await this.files.read(this.paths.prefsFile);
    if (text === null) return new AppPrefs(); // 文件缺失 → 内存默认（不引导落盘）
    try {
      return AppPrefs.fromJson(JSON.parse(text) as Record<string, Object>);
    } catch (_e) {
      await this.files.quarantine(this.paths.prefsFile, 'parse');
      return new AppPrefs();
    }
  }

  /** 静默写（writePrefs 直译）：opMutex 内读改写 */
  async writePrefs(mutate: (p: AppPrefs) => AppPrefs): Promise<void> {
    await this.mutate(async () => {
      await this.writePrefsLocked(mutate(await this.readPrefs()));
    });
  }

  private async writePrefsLocked(prefs: AppPrefs): Promise<void> {
    await this.files.write(this.paths.prefsFile, JSON.stringify(prefs.toJson()));
  }

  async disableIpv6(): Promise<boolean> { return (await this.readPrefs()).disableIpv6; }
  async connectOnDemand(): Promise<boolean> { return (await this.readPrefs()).connectOnDemand; }

  // ---- 基础设施 ----

  private async readListFile<T>(file: string,
    fromJson: (o: Record<string, Object>) => T): Promise<T[] | null> {
    const text = await this.files.read(file);
    if (text === null) return null;
    try {
      const arr = JSON.parse(text) as Object[];
      return arr.map(it => fromJson(it as Record<string, Object>));
    } catch (_e) {
      await this.files.quarantine(file, 'parse');
      return null;
    }
  }

  private async writeListFile(file: string, items: Record<string, Object>[]): Promise<void> {
    await this.files.write(file, JSON.stringify(items));
  }

  /** 首启 bootstrap：planets.json 不存在且无 .corrupt → 写 [OFFICIAL]；不防火信号 */
  private async bootstrap(): Promise<void> {
    if (this.bootstrapped) return;
    this.bootstrapped = true; // 先置位防重入（bootstrap 内无信号发射）
    // 用 stat 判存在而非 read-null（评审 Important：JsonFileStore.read 把 IO 读
    // 失败并入 null，文件存在但读失败时会把用户行星表覆盖写 [OFFICIAL]，
    // 不可逆丢数据；Kotlin 是 !exists()，stat 语义才是金标）
    if (await this.fileExists(this.paths.planetsFile)) return;
    if (await this.fileExists(`${this.paths.planetsFile}.corrupt`)) {
      return; // .corrupt 存在 = 不自动重建
    }
    await this.writeListFile(this.paths.planetsFile, [PlanetProfile.OFFICIAL.toJson()]);
  }

  private fireConfig(): void {
    this.configListeners.forEach(cb => cb());
    this.publishQuiet(IpcEvents.CONFIG_CHANGED); // D5：唤醒 VpnExt 全量重读
  }

  private firePlanets(): void {
    this.planetsListeners.forEach(cb => cb());
  }

  /** commonEvent 发布失败静默（配置已落盘，VpnExt 重启后自会重读） */
  private publishQuiet(event: string): void {
    commonEventManager.publish(event, () => { /* 结果不敏感 */ });
  }

  // 文件内私有 helper（brief 示意名 fs_stat/unlink_file/rmdir_recursive 的落地形态）

  private async fileExists(target: string): Promise<boolean> {
    try {
      await fs.stat(target);
      return true;
    } catch (_e) {
      return false; // 不存在 / 不可 stat 均按缺失
    }
  }

  private async unlinkQuiet(target: string): Promise<void> {
    try { await fs.unlink(target); } catch (_e) { /* 已不存在 */ }
  }

  /** 递归删除目录（fs.rmdir 对非空目录不保证递归，brief 指定 listFile + 深度遍历） */
  private async rmdirR(dir: string): Promise<void> {
    let entries: string[] = [];
    try {
      entries = await fs.listFile(dir);
    } catch (_e) {
      return; // 目录不存在 / 不可列，按已删除
    }
    for (const name of entries) {
      const full = `${dir}/${name}`;
      let isDir = false;
      try {
        isDir = (await fs.stat(full)).isDirectory();
      } catch (_e) {
        continue; // 条目已消失，跳过
      }
      if (isDir) {
        await this.rmdirR(full);
      } else {
        try { await fs.unlink(full); } catch (_ignored) { /* 不放大 */ }
      }
    }
    try { await fs.rmdir(dir); } catch (_ignored) { /* 已不存在 */ }
  }
}
