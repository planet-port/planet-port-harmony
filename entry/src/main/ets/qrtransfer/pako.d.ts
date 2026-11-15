/**
 * pako（ohpm，MIT AND Zlib）的最小类型垫片。
 * ohpm 包内不带 .d.ts（files 仅 index.js/dist/lib），此垫片只为 ArkTS 编译器服务。
 * 本项目只消费 raw deflate 两个入口（直译 iOS COMPRESSION_ZLIB 语义）。
 */
declare module 'pako' {
  export function deflateRaw(data: Uint8Array): Uint8Array;
  export function inflateRaw(data: Uint8Array): Uint8Array;
}
