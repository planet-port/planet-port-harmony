// StorePaths.ets — 沙盒路径布局（直译 store/StorePaths.kt）
//
// 两进程 filesDir 同路径（应用沙盒按 bundle 划分）——主进程与 VpnExt 各自
// new StorePaths(filesDir) 得到同一布局。快照文件为本计划新增（D1），挂
// filesDir 根（运行时状态，不入 config/ 配置目录）。
import { Context } from '@kit.AbilityKit';

export class StorePaths {
  readonly filesRoot: string;

  constructor(filesRoot: string) { this.filesRoot = filesRoot; }

  static of(ctx: Context): StorePaths { return new StorePaths(ctx.filesDir); }

  get configDir(): string { return `${this.filesRoot}/config`; }
  get planetsDir(): string { return `${this.filesRoot}/planets`; }
  get planetsFile(): string { return `${this.configDir}/planets.json`; }
  get networksFile(): string { return `${this.configDir}/networks.json`; }
  get moonsFile(): string { return `${this.configDir}/moons.json`; }
  get prefsFile(): string { return `${this.configDir}/prefs.json`; }
  planetStateDir(planetId: string): string { return `${this.filesRoot}/zt/${planetId}`; }
  get dataStoreRoot(): string { return `${this.filesRoot}/zt`; }
  get snapshotFile(): string { return `${this.filesRoot}/tunnel-snapshot.json`; }
}
