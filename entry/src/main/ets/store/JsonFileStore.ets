// JsonFileStore.ets — JSON 文件读写设施（直译 store/JsonFileStore.kt）
//
// 语义逐条对齐：读（不存在→null；解析失败由调用方隔离 .corrupt 后用内存
// 默认值）；写（父目录逐级创建→写 .tmp→rename 原子替换；失败删 .tmp 抛）；
// 隔离（改名 .corrupt，已存在先删，只留最近一次现场，.corrupt 存在时不自动
// 重建）。Kotlin Mutex（每个操作自持锁）在 ArkTS 退化为 async 串行队列：
// 公开 read/write 一切入队——并发裸写同一文件不再可能 torn-write（评审
// Important 修复）；mutate 块内经 inQueue 标志直通（单线程事件循环下的
// 可重入等价，调用方无死锁心智负担）。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PlanetPortStore';
const READ_CHUNK = 64 * 1024;

export class JsonFileStore {
  // 串行队列：所有配置 IO 排队执行（Kotlin 全局 Mutex 的等价物）
  private queue: Promise<void> = Promise.resolve();
  // mutate 块执行中标志（队列回调内同步置位/复位）——块内 read/write
  // 直通不入队，避免「队列里等自己」死锁；等价 Kotlin Mutex 的同线程
  // 可重入路径（mutate 内 this.write 不再二次拿锁）
  private inQueue = false;

  /** 域锁（AppConfigStore.mutate 用）：块内 read/write 自动串行互斥 */
  async mutate<T>(block: () => Promise<T>): Promise<T> {
    if (this.inQueue) {
      // 重入（mutate 块内再 mutate）：外层已持队列，直接执行
      return block();
    }
    const run = this.queue.then(async () => {
      this.inQueue = true;
      try {
        return await block();
      } finally {
        this.inQueue = false;
      }
    });
    this.queue = run.then(() => {}, () => {}); // 失败不断链
    return run;
  }

  async read(file: string): Promise<string | null> {
    if (!this.inQueue) {
      return this.mutate(() => this.readLocked(file));
    }
    return this.readLocked(file);
  }

  async write(file: string, text: string): Promise<void> {
    if (!this.inQueue) {
      return this.mutate(() => this.writeLocked(file, text));
    }
    return this.writeLocked(file, text);
  }

  private async readLocked(file: string): Promise<string | null> {
    try {
      return await fs.readText(file);
    } catch (e) {
      hilog.warn(0x0000, TAG, `配置读取失败按缺失处理 ${file}: ${JSON.stringify(e)}`);
      return null; // 不存在 / 读失败均按 null（调用方回退默认值）
    }
  }

  private async writeLocked(file: string, text: string): Promise<void> {
    const dir = file.substring(0, file.lastIndexOf('/'));
    await this.mkdirP(dir);
    const tmp = `${file}.tmp`;
    let fd = -1;
    try {
      const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      fd = f.fd;
      await fs.write(fd, text);
      await fs.close(fd);
      fd = -1;
      await fs.rename(tmp, file); // 原子替换
    } catch (e) {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
      try { await fs.unlink(tmp); } catch (_ignored) { /* 无 tmp 可清 */ }
      // 文案对齐 Kotlin（rename 失败语法）；附底层错误便于排障（评审 Minor-3）
      throw new Error(`config write failed (rename): ${file}: ${JSON.stringify(e)}`);
    }
  }

  /** 损坏隔离：改名 .corrupt（已存在先删——只留最近一次现场）；不抛 */
  async quarantine(file: string, cause: string): Promise<void> {
    try {
      const target = `${file}.corrupt`;
      try { await fs.unlink(target); } catch (_e) { /* 不存在即跳过 */ }
      await fs.rename(file, target);
      hilog.warn(0x0000, TAG, `配置损坏已隔离为 ${target} (${cause})`);
    } catch (_e) { /* 隔离失败不放大 */ }
  }

  private async mkdirP(dir: string): Promise<void> {
    const parts = dir.split('/');
    let cur = '';
    for (let i = 0; i < parts.length; i++) {
      // 空段仅两类合法来源：绝对路径首段（置根）与重复斜杠（跳过）；
      // 无条件置根会丢已累积前缀（评审 Minor-1）
      if (parts[i] === '') {
        if (cur === '') cur = '/';
        continue;
      }
      cur = cur === '/' ? `/${parts[i]}` : cur === '' ? parts[i] : `${cur}/${parts[i]}`;
      try { await fs.mkdir(cur); } catch (_e) { /* 已存在 */ }
    }
  }
}

// READ_CHUNK 保留直译常量位（ArkTS readText 整读，64KiB 限额语义由
// BoundedRead 在 A5 落地时复用）；hilog tag 对齐 Kotlin TAG 常量。
export { READ_CHUNK };
