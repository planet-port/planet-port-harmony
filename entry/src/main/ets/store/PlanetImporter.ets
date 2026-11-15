// PlanetImporter.ets — 多 Planet 文件导入编排（iOS PlanetImporter.swift 直译）
//
// 每份私有 Planet 独立保存（UUID 小写 → planets/<id>.planet，tmp+rename 原子
// 写），不覆盖其它配置；行星表经 AppConfigStore 现有公开 API upsert
// （readPlanets + push + writePlanets——writePlanetsLocked 保证 official 永在
// 最前并发 planetsChanged，即 iOS writePlanets 的鸿蒙对应物，AppConfigStore
// 本体零改动）。下载走 requestInStream 流式边收边报（iOS URLSession delegate
// 直译：非 200 失败 / Content-Length 超限 / 累计超限双段 8MiB 防护 /
// Content-Length 未知进度报 null）。
//
// planet 二进制字节布局（Core/node/World.hpp serialize Buffer 版直译，
// planet 非 forSign 分支）：
//   [0]      type = 0x01（TYPE_PLANET）
//   [1..8]   worldId   u64 大端
//   [9..16]  timestamp u64 大端
//   [17..80] updatesMustBeSignedBy 公钥（ZT_ECC_PUBLIC_KEY_SET_LEN = 64）
//   [81..176]signature（ZT_ECC_SIGNATURE_LEN = 96）
//   [177]    roots 数量（u8）
//   [178..]  每 root：identity.serialize(false) = 5B 节点地址（ZT_ADDRESS_LENGTH）
//            + 1B 类型(0) + 64B 公钥 + 1B 私钥长度(0)……首 root 地址在 178..182，
//            10 位小写 hex（ZT_ADDRESS_LENGTH_HEX = 10）。
// u64 精度：worldId 可超 2^53（双精度整数安全上界），统一以 16 位小写 hex
// 字符串承载（查重键 + addplanet.duplicate %@ 展示双用途）；timestamp 是
// Unix 秒量级（≪ 2^53）按 number 解。
//
// 双查重（计划 #8 扩展，iOS 只有 World ID 查重——顺序仍直译 iOS add()）：
// ①World ID（阻断，iOS 直译）②planet 首 root 节点地址（10 hex）vs 既有行星
// .planet 文件解析出的 root 地址集合。设计意图：与官方地球共享根服务器但换了
// World ID 的「套壳」planet，单查 World ID 挡不住；#8 原文「节点身份段解析」
// 即此语义（identity.secret 是本机身份文件，与行星查重无关，不消费）。
// T8 评审挂账 I-1 降级（A5-T12 收口）：②命中不再拦截导入（iOS/Android 均放行
// ——同 provider 多 worldId 的合法行星会被误杀），降级为告警可继续：仅提示、
// 无取消路径，提示文案参数取冲突既有行星的展示名（原取 World ID hex）。
// 查重编排与告警 UI 在 AddPlanetPage.add()（页面领地），本文件只出集合。
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { PayloadContainer } from '../qrtransfer/PayloadContainer';
import { AppConfigStore } from './AppConfigStore';
import { PlanetProfile, PlanetKind } from './Models';

/** planet 二进制类型字节（World.hpp TYPE_PLANET；iOS data.first == 0x01） */
export const PLANET_TYPE_BYTE: number = 0x01;
/** 下载/导入体积上限（iOS maxBytes = 8 * 1024 * 1024；误指大文件/恶意超大
 *  响应防护，合法 planet 文件远小于此） */
export const MAX_PLANET_BYTES: number = 8 * 1024 * 1024;
/** 官方地球行星 World ID（iOS ZT_WORLD_ID_EARTH 直译；官方行星在鸿蒙无
 *  .planet 文件实体——由 ZT 核心内置，查重集合以常量种子覆盖） */
export const ZT_WORLD_ID_EARTH: number = 149604618;
/** 连接超时 ms（iOS timeoutIntervalForRequest = 5；请求空闲间隔语义） */
const CONNECT_TIMEOUT_MS: number = 5000;
/** 读取超时 ms（iOS timeoutIntervalForResource = 10 的最近似档） */
const READ_TIMEOUT_MS: number = 10000;
/** ZTP KV 容器 key 约定（iOS PlanetPayload.swift:5-9 直译） */
const KEY_PLANET: number = 1;
const KEY_NAME: number = 2;
const KEY_ICON: number = 3;
const KEY_ICON_COLOR: number = 4;

/** 小写 hex 数字表（beBytesHex 输出域） */
const HEX_DIGITS: string[] =
  ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

/** .planet 文件尽力解读（iOS inspectPlanetFile 元组直译；ArkTS 承载形态） */
export interface PlanetFileInfo {
  /** 16 位小写 hex（>2^53 精确承载） */
  worldIdHex: string;
  /** Unix 秒（≪ 2^53，number 精确） */
  timestamp: number;
  fileSize: number;
}

/** ZTP 载荷解析结果（iOS PlanetPayload 直译；缺省字段 null） */
export interface PlanetPayloadFields {
  /** key 1：planet 二进制（必备） */
  planet: Uint8Array;
  /** key 2：名称（UTF-8 解码失败按缺省） */
  name: string | null;
  /** key 3：动物图标 key */
  icon: string | null;
  /** key 4：底色 hex */
  iconColor: string | null;
}

// >>> MIRROR-BEGIN（镜像切片起点：其后至 MIRROR-END 的逻辑行与 .mjs 全文对应）

/**
 * 大端字节序列 → 小写 hex（count 字节 → 2*count 字符）。worldId/root 地址
 * 等 u64 段的统一直读出口——hex 字符串形态绕开双精度整数精度损失（>2^53
 * 的 worldId 逐字节读不经过 number 合成，天然精确）。
 */
export function beBytesHex(data: Uint8Array, offset: number, count: number): string {
  let s = '';
  for (let i = 0; i < count; i++) {
    const b = data[offset + i];
    s += HEX_DIGITS[Math.floor(b / 16)] + HEX_DIGITS[b % 16];
  }
  return s;
}

/**
 * number → 16 位小写 hex（MoonEntry.formatWorldId 同款 16 次取位法；负数/
 * 非有限值按 0 处理）。仅用于 ZT_WORLD_ID_EARTH 常量种子的 hex 化。
 */
export function hex16FromNumber(v: number): string {
  let n = v < 0 || !Number.isFinite(v) ? 0 : Math.floor(v);
  let s = '';
  for (let i = 0; i < 16; i++) {
    s = HEX_DIGITS[n % 16] + s;
    n = Math.floor(n / 16);
  }
  return s;
}

/** 从 planet 二进制提取 World ID hex（iOS worldId(of:) 直译：count >= 9 且
 *  首字节 0x01 → [1..8] 大端；其余 null） */
export function worldIdOf(data: Uint8Array): string | null {
  if (data.length < 9 || data[0] !== PLANET_TYPE_BYTE) {
    return null;
  }
  return beBytesHex(data, 1, 8);
}

/** 从 planet 二进制提取首 root 节点地址 hex（10 位；#8 扩展查重域，字节
 *  布局依据见文件头。roots 数为 0 或长度不足时 null） */
export function rootAddressOf(data: Uint8Array): string | null {
  if (data.length < 183 || data[0] !== PLANET_TYPE_BYTE || data[177] < 1) {
    return null;
  }
  return beBytesHex(data, 178, 5);
}

/** 大端字节段 → number（count 字节 16 次取位累加；timestamp ≪ 2^53 前提下
 *  精确，调用方仅对 timestamp 段使用） */
export function beBytesNumber(data: Uint8Array, offset: number, count: number): number {
  let v = 0;
  for (let i = 0; i < count; i++) {
    v = v * 256 + data[offset + i];
  }
  return v;
}

/** 从 planet 二进制尽力解读（iOS inspectPlanetFile 直译：需 ≥17B 且首字节
 *  0x01，否则 null） */
export function inspectBytes(data: Uint8Array): PlanetFileInfo | null {
  if (data.length < 17 || data[0] !== PLANET_TYPE_BYTE) {
    return null;
  }
  const info: PlanetFileInfo = {
    worldIdHex: beBytesHex(data, 1, 8),
    timestamp: beBytesNumber(data, 9, 8),
    fileSize: data.length,
  };
  return info;
}

/**
 * ZTP 容器解析（iOS PlanetPayload.parse 直译）：decode 失败或缺 planet 字段
 * （key 1）→ null（旧版裸 planet 载荷同走 null，页面统一「二维码数据无效」
 * 提示）；文本字段 UTF-8 解码失败按缺省 null。
 */
export function parsePlanetPayload(data: Uint8Array): PlanetPayloadFields | null {
  const fields = PayloadContainer.parse(data);
  if (fields === null) {
    return null;
  }
  const planet = fields.get(KEY_PLANET);
  if (planet === undefined) {
    return null;
  }
  const out: PlanetPayloadFields = {
    planet: planet,
    name: utf8OrNull(fields.get(KEY_NAME)),
    icon: utf8OrNull(fields.get(KEY_ICON)),
    iconColor: utf8OrNull(fields.get(KEY_ICON_COLOR)),
  };
  return out;
}

// UTF-8 解码来源平台适配：HarmonyOS 用 util.TextDecoder，node 镜像侧用
// Buffer.from——函数体行两侧各自实现，标记 MIRROR-SKIP 跳过骨架比对。
function utf8OrNull(bytes: Uint8Array | undefined): string | null {
  return bytes === undefined ? null
    : util.TextDecoder.create('utf-8').decodeToString(bytes); // MIRROR-SKIP
}

// <<< MIRROR-END

/** 导入错误（iOS ImportError 直译）：携带文案键，页面统一 loc 后进 alert/toast */
export class ImportError extends Error {
  readonly locKey: string;

  constructor(locKey: string) {
    super(locKey);
    this.locKey = locKey;
  }
}

export class PlanetImporter {
  private readonly store: AppConfigStore;

  constructor(store: AppConfigStore) {
    this.store = store;
  }

  /**
   * 已存在 World ID 集合（16 位 hex；iOS existingWorldIds 直译）：地球常量
   * 种子 + 各行星 .planet 文件解析值，用于添加时查重。
   */
  async existingWorldIds(): Promise<Set<string>> {
    const ids = new Set<string>();
    ids.add(hex16FromNumber(ZT_WORLD_ID_EARTH));
    const planets = await this.store.readPlanets();
    for (const p of planets) {
      const info = await this.inspectPlanetFile(p);
      if (info !== null) {
        ids.add(info.worldIdHex);
      }
    }
    return ids;
  }

  /**
   * 既有行星首 root 节点地址 → 所属行星档案（#8 扩展查重域，依据见文件头；
   * T8 挂账 I-1 降级后命中方消费档案展示名做告警参数，不再阻断导入）。
   */
  async existingRootAddresses(): Promise<Map<string, PlanetProfile>> {
    const map = new Map<string, PlanetProfile>();
    const planets = await this.store.readPlanets();
    for (const p of planets) {
      const bytes = p.fileName === null ? null
        : await this.readPlanetBytes(`${this.store.paths.planetsDir}/${p.fileName}`);
      const addr = bytes === null ? null : rootAddressOf(bytes);
      if (addr !== null) {
        map.set(addr, p);
      }
    }
    return map;
  }

  /**
   * 写入 planet 文件 + 行星表 upsert（iOS importPlanetData 直译）：头字节
   * 校验 → 名称 trim 非空 → UUID 小写 → planets/<id>.planet 原子写 →
   * readPlanets + append + writePlanets（经 writePlanetsLocked：official 永
   * 在最前 + 发 planetsChanged）。
   */
  async importPlanetData(data: Uint8Array, name: string,
    icon: string | null = null, iconColor: string | null = null): Promise<PlanetProfile> {
    if (data.length === 0 || data[0] !== PLANET_TYPE_BYTE) {
      throw new ImportError('error.planet.badHeader');
    }
    // iOS trimmingCharacters(.whitespacesAndNewlines)：JS trim 同含空白+行终结符
    const normalizedName = name.trim();
    if (normalizedName.length === 0) {
      throw new ImportError('error.planet.emptyName');
    }
    const id = util.generateRandomUUID(true); // 小写 UUID（iOS uuidString.lowercased()）
    const fileName = `${id}.planet`;
    const dir = this.store.paths.planetsDir;
    await this.mkdirP(dir);
    await this.writePlanetFileAtomic(`${dir}/${fileName}`, data);
    const profile = new PlanetProfile(id, normalizedName, PlanetKind.Custom,
      fileName, icon, iconColor);
    const profiles = await this.store.readPlanets();
    profiles.push(profile);
    await this.store.writePlanets(profiles);
    return profile;
  }

  /**
   * 仅下载 planet 文件内容，不校验、不落库（iOS downloadPlanetFile 直译）。
   * requestInStream 流式收体：headersReceive 读 Content-Length（超限立即
   * 失败并断连 = iOS didReceive 分支）；dataReceive 累计超限失败 + 边收边报
   * 进度（expected > 0 → min(1, received/expected)，未知 → null）；非 200 /
   * URL 非法 / 网络栈异常 → downloadFailed（iOS statusCode 判定 / URL(string:)
   * nil / session error 直译）。
   * 注：compatibleSdkVersion API 12 下 requestInStream 单响应收体上限 5MB
   * （API 23 起放宽到 50MB）——合法 planet 文件 KB 量级，8MiB 防护先于该上限
   * 生效，超限大响应按 tooLarge/downloadFailed 归因，无行为差异。
   */
  downloadPlanetFile(url: string,
    progress: (fraction: number | null) => void): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve: (v: Uint8Array) => void,
      reject: (e: ImportError) => void) => {
      const req = http.createHttp();
      const chunks: ArrayBuffer[] = [];
      let received = 0;
      let expected = -1; // -1 = Content-Length 未知（iOS expectedContentLength 初值直译）
      let finished = false;

      const finishOk = (): void => {
        if (finished) {
          return;
        }
        finished = true;
        req.destroy();
        const out = new Uint8Array(received);
        let p = 0;
        for (const chunk of chunks) {
          const part = new Uint8Array(chunk);
          out.set(part, p);
          p += part.length;
        }
        resolve(out);
      };
      const fail = (err: ImportError): void => {
        if (finished) {
          return;
        }
        finished = true;
        req.destroy();
        reject(err);
      };

      req.on('headersReceive', (value: Object) => {
        if (finished) {
          return;
        }
        // 头键大小写不敏感扫描（服务端 content-length/Content-Length 均有）
        const headers = value as Record<string, string>;
        const keys = Object.keys(headers);
        for (const k of keys) {
          if (k.toLowerCase() !== 'content-length') {
            continue;
          }
          const parsed = parseInt(headers[k], 10);
          if (Number.isNaN(parsed)) {
            continue;
          }
          if (parsed > MAX_PLANET_BYTES) {
            fail(new ImportError('error.planet.tooLarge'));
            return;
          }
          if (parsed >= 0) {
            expected = parsed;
          }
        }
      });
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        if (finished) {
          return;
        }
        chunks.push(chunk);
        received += chunk.byteLength;
        if (received > MAX_PLANET_BYTES) {
          fail(new ImportError('error.planet.tooLarge'));
          return;
        }
        progress(expected > 0 ? Math.min(1, received / expected) : null);
      });
      req.on('dataEnd', () => finishOk());
      req.requestInStream(url, {
        method: http.RequestMethod.GET,
        usingCache: false,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
      }).then((code: number) => {
        if (code !== 200) {
          fail(new ImportError('error.downloadFailed')); // iOS statusCode == 200 判定直译
        }
      }).catch(() => {
        fail(new ImportError('error.downloadFailed')); // URL 非法/网络栈异常归并下载失败
      });
    });
  }

  /** 从 .planet 文件尽力解读（iOS inspectPlanetFile 直译：fileName 缺失/读
   *  失败按 null——iOS try? Data(contentsOf:) 同语义） */
  async inspectPlanetFile(profile: PlanetProfile): Promise<PlanetFileInfo | null> {
    if (profile.fileName === null) {
      return null;
    }
    const bytes = await this.readPlanetBytes(
      `${this.store.paths.planetsDir}/${profile.fileName}`);
    return bytes === null ? null : inspectBytes(bytes);
  }

  // ---- 私有工具 ----

  /** 沙盒整文件读（字节级）→ 恰长 Uint8Array；失败按 null（不放大） */
  private async readPlanetBytes(path: string): Promise<Uint8Array | null> {
    let fd = -1;
    try {
      const f = await fs.open(path, fs.OpenMode.READ_ONLY);
      fd = f.fd;
      const st = await fs.stat(fd);
      const size = st.size;
      if (size <= 0) {
        return null;
      }
      const ab = new ArrayBuffer(size);
      const n = await fs.read(fd, ab, { offset: 0, length: size });
      return new Uint8Array(ab.slice(0, n));
    } catch (_e) {
      return null;
    } finally {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
    }
  }

  /** 原子写：tmp 落盘 → rename 替换（JsonFileStore.writeLocked 同款范式；
   *  失败删 tmp 抛——半截文件绝不出现） */
  private async writePlanetFileAtomic(path: string, data: Uint8Array): Promise<void> {
    const tmp = `${path}.tmp`;
    let fd = -1;
    try {
      const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      fd = f.fd;
      // 恰长 ArrayBuffer（data 可能是带偏移的视图；write 按 buffer 整体落盘）
      const ab = data.buffer.slice(data.byteOffset,
        data.byteOffset + data.byteLength) as ArrayBuffer;
      await fs.write(fd, ab);
      await fs.close(fd);
      fd = -1;
      await fs.rename(tmp, path);
    } catch (e) {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
      try { await fs.unlink(tmp); } catch (_ignored) { /* 无 tmp 可清 */ }
      throw new Error(`planet write failed (rename): ${path}: ${JSON.stringify(e)}`);
    }
  }

  /** 逐级建目录（JsonFileStore.mkdirP 同款；已存在吞错） */
  private async mkdirP(dir: string): Promise<void> {
    const parts = dir.split('/');
    let cur = '';
    for (const part of parts) {
      if (part === '') {
        if (cur === '') {
          cur = '/';
        }
        continue;
      }
      cur = cur === '/' ? `/${part}` : cur === '' ? part : `${cur}/${part}`;
      try { await fs.mkdir(cur); } catch (_e) { /* 已存在 */ }
    }
  }
}
