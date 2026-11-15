// BackgroundImageStore.ets — 首页自定义背景图存储（iOS BackgroundImageStore.swift /
// Android BackgroundImageStore.kt 同构直译）
//
// 文件落沙盒 filesDir 根（brief 定值 files/background.jpg），单文件整存整取；
// 内存态经文件尾 backgroundImageSignal（AppStorageV2 键 'background'）发布——
// 首页视差层（HomeView 接线 HomeParallaxBackground）与设置页缩略图同源消费。
//
// 校验口径（iOS maxBytes 20MB + 可解码校验直译；Android 有界读取同值）：
//   ≤ 20MB 且能解码出合法图片，否则返回 tooLarge/notImage 错误码，文案由 UI
//   层映射（store 层不依赖 L10n，与 Android「VM 层本地化」同一分层）。
//   DESIGN.md:83-94 的六条规则是「换图必读、六条全过才可上架」的资产上架规则
//   （规则 5 自身写明「命名入 imageset」；题材/构图/色调/明度/授权五条为人工
//   判断维度，机器不可校验）——iOS/Android 金标的用户选图路径均只做 ≤20MB +
//   可解码校验，按金标实现（偏差记录见 .superpowers/sdd/task-10-report.md）。
//
// 解码降采样：Android decodeBytes 的 inSampleSize 直译（SDK
// image.DecodingOptions.sampleSize 同语义），全尺寸照片位图在低端机易 OOM，
// 解码上限 ≈ 一屏 ARGB。串行化：Android Mutex 直译为 promise 链队列（ArkTS
// 单线程事件循环，then 链即天然互斥）——相册/下载连点的 save/clear/refresh
// 竞态不交错；refresh 幂等。
import { image } from '@kit.ImageKit';
import { AppStorageV2 } from '@kit.ArkUI';
import display from '@ohos.display';
import fs from '@ohos.file.fs';
import { StoreRepo } from './StoreRepo';

/** 图片字节数上限（iOS maxBytes / Android MAX_BYTES 同值） */
const MAX_BYTES: number = 20 * 1024 * 1024;

/** 校验结果码（null = 成功；文案归 UI 层，error.bg.* 键已入三语表） */
export enum BgImageError {
  TooLarge = 'tooLarge',
  NotImage = 'notImage',
}

/** 背景图信号（AppStorageV2 键 'background'）：首页视差层 + 设置页缩略图同源 */
@ObservedV2
export class BackgroundImageSignal {
  /** 背景位图（null = 未设置，首页退化纯页面底色） */
  @Trace pixelMap: image.PixelMap | null = null;
  /** 视差开关（prefs.parallax 内存镜像；toggle 即时同步，落盘归设置页） */
  @Trace parallax: boolean = true;
}

/** 进程单例：模块导入即 connect（AppStorageV2 纯内存域，不依赖 UI 上下文） */
export const backgroundImageSignal: BackgroundImageSignal =
  AppStorageV2.connect(BackgroundImageSignal, 'background', () => new BackgroundImageSignal())!;

export class BackgroundImageStore {
  static readonly MAX_BYTES: number = MAX_BYTES;

  /** 沙盒文件路径（brief 定值 files/background.jpg） */
  static filePath(): string {
    return `${StoreRepo.store.paths.filesRoot}/background.jpg`;
  }

  /** 校验期临时副本（同目录换名原子；正式文件校验通过前不被覆写） */
  static tempPath(): string {
    return `${BackgroundImageStore.filePath()}.tmp`;
  }

  /** 串行队列（Android Mutex 直译：then 链尾追，任务不交错） */
  private static queue: Promise<void> = Promise.resolve();

  private static enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run: Promise<T> = BackgroundImageStore.queue.then(task);
    BackgroundImageStore.queue = run.then((): void => { }, (): void => { });
    return run;
  }

  /** 视差开关内存态同步（Android syncParallax 直译：toggle 即时生效不重解码） */
  static syncParallax(on: boolean): void {
    backgroundImageSignal.parallax = on;
  }

  /** 重读磁盘 → 刷新内存态（首页/设置页进入时调用；幂等；文件缺失 → null） */
  static refresh(): Promise<void> {
    return BackgroundImageStore.enqueue(() => BackgroundImageStore.refreshLocked());
  }

  /** 相册选图（photoUri）→ 拷贝沙盒 + 校验 + 换名 + 刷新（Android save(uri) 同构） */
  static saveFromUri(uri: string): Promise<BgImageError | null> {
    return BackgroundImageStore.enqueue(async (): Promise<BgImageError | null> => {
      // uri fd 只做一次顺序读（I-1：原「先解码后拷贝」共用同一 fd，ImageSource
      // 解码可能移动共享 fd 偏移致拷出截断文件；对调后偏移问题与双重读取一并消除）
      let fd = -1;
      try {
        const f = await fs.open(uri, fs.OpenMode.READ_ONLY);
        fd = f.fd;
        const st = await fs.stat(fd);
        if (st.size > MAX_BYTES) {
          return BgImageError.TooLarge; // 读前即限（Android readBounded 同语义）
        }
        // 先落临时副本而非直接覆写正式文件：校验不过不换名，旧背景图保留
        //（iOS UIImage(data:) 校验失败不落盘同语义）
        await fs.copyFile(fd, BackgroundImageStore.tempPath());
      } catch (_e) {
        return BgImageError.NotImage;
      } finally {
        if (fd >= 0) {
          try { fs.closeSync(fd); } catch (_e) { /* 已关闭 */ }
        }
      }
      // 可解码校验（iOS UIImage(data:) / Android decodeBounds 直译）：对沙盒
      // 副本独立句柄只读头信息不产位图；打开/读取失败并入 notImage（Android
      // getOrElse 同语义），失败删副本按原错误路径返回
      const tmp = BackgroundImageStore.tempPath();
      let src: image.ImageSource | null = null;
      let ok = false;
      try {
        src = image.createImageSource(tmp);
        const info = await src.getImageInfo();
        ok = info.size.width > 0 && info.size.height > 0;
      } catch (_e) {
        ok = false;
      } finally {
        if (src !== null) {
          try { await src.release(); } catch (_e) { /* 释放失败不放大 */ }
        }
      }
      if (!ok) {
        await BackgroundImageStore.removeQuiet(tmp);
        return BgImageError.NotImage;
      }
      try {
        await fs.rename(tmp, BackgroundImageStore.filePath());
      } catch (_e) {
        await BackgroundImageStore.removeQuiet(tmp);
        return BgImageError.NotImage; // 换名失败按无效内容（saveData 落盘失败同语义）
      }
      await BackgroundImageStore.refreshLocked();
      return null;
    });
  }

  /** URL 下载字节 → 校验 + 落文件 + 刷新（iOS applyBackgroundImage(Data) 直译） */
  static saveData(data: ArrayBuffer): Promise<BgImageError | null> {
    return BackgroundImageStore.enqueue(async (): Promise<BgImageError | null> => {
      if (data.byteLength > MAX_BYTES) {
        return BgImageError.TooLarge;
      }
      if (data.byteLength === 0) {
        return BgImageError.NotImage; // 空内容由调用方（下载路径）先行拦截为 emptyContent
      }
      const src = image.createImageSource(data);
      try {
        const info = await src.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0) {
          return BgImageError.NotImage;
        }
      } catch (_e) {
        return BgImageError.NotImage;
      } finally {
        try { await src.release(); } catch (_e) { /* 释放失败不放大 */ }
      }
      try {
        const f = await fs.open(BackgroundImageStore.filePath(),
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          await fs.write(f.fd, data);
        } finally {
          try { fs.closeSync(f.fd); } catch (_e) { /* 已关闭 */ }
        }
      } catch (_e) {
        return BgImageError.NotImage; // 落盘失败按无效内容（校验已过，重试可恢复）
      }
      await BackgroundImageStore.refreshLocked();
      return null;
    });
  }

  /** 清除（无文件时静默成功，iOS try? removeItem 同语义） */
  static clear(): Promise<void> {
    return BackgroundImageStore.enqueue(async (): Promise<void> => {
      await BackgroundImageStore.removeQuiet(BackgroundImageStore.filePath());
      BackgroundImageStore.swapPixelMap(null);
    });
  }

  // ---- 内部（队列锁内调用） ----

  /** 静默删除（clear / 校验失败清临时副本共用；不存在/失败均吞掉） */
  private static async removeQuiet(file: string): Promise<void> {
    try {
      await fs.unlink(file);
    } catch (_e) { /* 已不存在 */ }
  }

  private static async refreshLocked(): Promise<void> {
    const file = BackgroundImageStore.filePath();
    let exists = false;
    try {
      exists = (await fs.stat(file)).size > 0;
    } catch (_e) {
      exists = false; // 不存在 / 不可 stat 均按缺失（AppConfigStore.fileExists 同语义）
    }
    // 损坏文件按未设置（iOS UIImage?(data:) nil 同语义），下次设置即覆盖修复
    BackgroundImageStore.swapPixelMap(exists
      ? await BackgroundImageStore.decodeFile(file) : null);
    try {
      const prefs = await StoreRepo.store.readPrefs();
      backgroundImageSignal.parallax = prefs.parallax;
    } catch (_e) { /* prefs 读失败保持现值 */ }
  }

  /** 文件 → 降采样位图（Android inSampleSize 两趟直译：先读尺寸，再按 2 的幂
   *  降到「不超过一屏」的最小倍率，解码上限 ≈ 一屏 ARGB） */
  private static async decodeFile(file: string): Promise<image.PixelMap | null> {
    let src: image.ImageSource | null = null;
    try {
      src = image.createImageSource(file);
      const info = await src.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return null;
      }
      const d = display.getDefaultDisplaySync();
      const tw = Math.max(d.width, 1); // Display.width/height 为屏幕物理像素（px）
      const th = Math.max(d.height, 1);
      let sample = 1;
      while (info.size.width / (sample * 2) >= tw || info.size.height / (sample * 2) >= th) {
        sample *= 2;
      }
      const opt: image.DecodingOptions = { sampleSize: sample };
      return await src.createPixelMap(opt);
    } catch (_e) {
      return null;
    } finally {
      if (src !== null) {
        try { await src.release(); } catch (_e) { /* 释放失败不放大 */ }
      }
    }
  }

  /** 旧位图释放（PixelMap 持有原生内存，替换前显式释放，失败静默） */
  private static swapPixelMap(next: image.PixelMap | null): void {
    const old = backgroundImageSignal.pixelMap;
    backgroundImageSignal.pixelMap = next;
    if (old !== null) {
      old.release().catch((): void => { });
    }
  }
}
