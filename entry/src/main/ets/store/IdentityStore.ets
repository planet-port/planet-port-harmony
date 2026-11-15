// IdentityStore.ets — 节点身份文件操作（直译 store/IdentityStore.kt）
//
// 平台差异：@ohos.file.fs 无 chmod/open 权限位，Kotlin 对 identity.secret 的
// 0600 收紧在此退化为应用沙盒默认隔离（其他应用不可读）；核心自写路径的
// 0600 已由 C++ putFileAtomic(secure) 落实（A2）。
// 生命周期约束：核心只在 ZT_Node_new 时读/生成身份、退出不回写——
// seedSharedIdentity/adoptSharedIdentity 必须先于新核心启动执行。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StorePaths } from './StorePaths';
import { PlanetProfile } from './Models';

const TAG = 'IdentityStore';

export class IdentityStore {
  static readonly IDENTITY_PUBLIC: string = 'identity.public';
  static readonly IDENTITY_SECRET: string = 'identity.secret';

  // 修正①：brief 原稿直接 `return fs.access(...)`——但 fs.access 在路径不存在时
  // 是 reject 而非 resolve(false)（brief 自己的 copyIdentity 就以
  // `catch → continue // src 不存在` 依赖这一行为），Promise<boolean> 契约在
  // 「身份不存在」这一主路径上断裂：seedSharedIdentity 内无 catch 地 await 它，
  // 播种主路径（无独立身份、共享存在）会抛异常而非复制，seed 永不生效。
  // 改为 access→true / reject→false，恢复 Kotlin File.exists() 的语义。
  static hasPlanetIdentity(paths: StorePaths, planetId: string): Promise<boolean> {
    return fs.access(`${paths.planetStateDir(planetId)}/${IdentityStore.IDENTITY_SECRET}`)
      .then(() => true).catch(() => false);
  }

  /** 读 planetStateDir/identity.public 的节点地址；缺失/损坏返回 null */
  static async planetIdentityAddress(paths: StorePaths, planetId: string): Promise<string | null> {
    return IdentityStore.addressOf(
      `${paths.planetStateDir(planetId)}/${IdentityStore.IDENTITY_PUBLIC}`);
  }

  static async sharedIdentityAddress(paths: StorePaths): Promise<string | null> {
    return IdentityStore.addressOf(`${paths.dataStoreRoot}/${IdentityStore.IDENTITY_PUBLIC}`);
  }

  /** perPlanet=false → 全行星同一共享地址；true → 各读各的，未生成的剔除 */
  static async planetNodeIds(paths: StorePaths, planets: PlanetProfile[],
    perPlanet: boolean): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    if (!perPlanet) {
      const addr = await IdentityStore.sharedIdentityAddress(paths);
      if (addr === null) return map;
      for (const p of planets) map.set(p.id, addr);
      return map;
    }
    for (const p of planets) {
      const addr = await IdentityStore.planetIdentityAddress(paths, p.id);
      if (addr !== null) map.set(p.id, addr);
    }
    return map;
  }

  /** 共享 → 行星：已有独立身份时不动作；共享存在性交由 copyIdentity 的 src 守卫
   * 兜底——Kotlin 金标只查 hasPlanetIdentity，identity.public 损坏而 secret 完好
   * 时仍须播种以保住节点地址连续（评审 Minor-1：原稿门槛挂在 addressOf 的
   * 显示格式启发式上，该场景不动作会导致核心生成全新身份、节点地址永久变更） */
  static async seedSharedIdentity(paths: StorePaths, planetId: string): Promise<void> {
    const hasOwn = await IdentityStore.hasPlanetIdentity(paths, planetId);
    if (hasOwn) return;
    await IdentityStore.copyIdentity(`${paths.dataStoreRoot}`,
      `${paths.planetStateDir(planetId)}`);
  }

  /** 行星 → 共享（覆盖） */
  static async adoptSharedIdentity(paths: StorePaths, planetId: string): Promise<void> {
    await IdentityStore.copyIdentity(`${paths.planetStateDir(planetId)}`,
      `${paths.dataStoreRoot}`);
  }

  /** readText → split(':')[0] → 长度 10 才是节点地址 */
  private static async addressOf(file: string): Promise<string | null> {
    try {
      const text = await fs.readText(file);
      const first = text.split(':')[0] ?? '';
      return first.length === 10 ? first : null;
    } catch (_e) {
      return null;
    }
  }

  /** 依次复制 PUBLIC/SECRET；src 缺失跳过；dst 存在先删；失败告警不抛（尽力而为） */
  private static async copyIdentity(fromDir: string, toDir: string): Promise<void> {
    for (const name of [IdentityStore.IDENTITY_PUBLIC, IdentityStore.IDENTITY_SECRET]) {
      const src = `${fromDir}/${name}`;
      const dst = `${toDir}/${name}`;
      try {
        await fs.access(src);
      } catch (_e) {
        continue; // src 不存在
      }
      try {
        await fs.mkdir(toDir, true); // 递归对齐 Kotlin mkdirs()（评审 Minor-2；recursion 幂等，已存在不抛）
      } catch (_e) { /* 已存在 */ }
      try {
        try { await fs.unlink(dst); } catch (_e) { /* 不存在 */ }
        await fs.copyFile(src, dst);
      } catch (e) {
        hilog.warn(0x0000, TAG, `身份文件复制失败 ${name}: ${JSON.stringify(e)}`);
      }
    }
  }
}
