// AlbumQrPicker.ets — 相册选图识别二维码
// （iOS AlbumQRPicker.swift / Android ui/components/AlbumQr.kt 等价）
//
// PhotoViewPicker 多选（按选择顺序，系统选择器无需相册权限）→ ScanKit
// detectBarcode 逐张识别（一张图可能多个码）→ 汇总返回全部识别文本。
// 相机流识别吃不了静态图片，静态图走 detectBarcode 是鸿蒙标准做法；两条路径
// 在调用方汇合后，识别文本交各自的聚合/提取逻辑（与相机扫到完全同构）。
//
// 多选串行限流（Android AlbumQr.kt 直译）：一张图解码期间同时驻留原始字节 +
// 位图像素（峰值数十 MB），全并发多选直接击穿默认堆，逐张 await 即天然限流；
// 顺序汇总与用户选择顺序一致（分片聚合按帧 index 进行，顺序其实无关，保持
// 稳定只为用户预期一致）。
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { detectBarcode, scanBarcode, scanCore } from '@kit.ScanKit';

/** 多选上限：iOS selectionLimit = 0（不限）等价取系统量级上限 */
const MAX_SELECT: number = 500;

export class AlbumQrPicker {
  /** 相册选图 + 串行识别，返回全部识别文本（按选择顺序拼接）。
   *  取消选择返回空数组（Android 优化语义：取消与无码不区分）。 */
  static async pickTexts(ctx: common.Context, multiple: boolean): Promise<string[]> {
    const opts: photoAccessHelper.PhotoSelectOptions = {
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: multiple ? MAX_SELECT : 1,
    };
    const picker = new photoAccessHelper.PhotoViewPicker();
    try {
      const result = await picker.select(opts);
      const uris = result.photoUris;
      const texts: string[] = [];
      // 逐张串行（限流见文件头）；单张失败整体兜底空（Android runCatching 直译）
      for (const uri of uris) {
        const found = await AlbumQrPicker.decodeImage(ctx, uri);
        for (const t of found) {
          texts.push(t);
        }
      }
      return texts;
    } catch (err) {
      // 取消选择 / 选择器异常统一返回空（取消与无码不区分，Android 同款语义）
      return [];
    }
  }

  /** 单张静态图识别全部二维码文本；任何一环失败返回空列表，不上抛
   *  （超大图被报成无码属可接受的语义损失，Android 同款兜底）。 */
  static async decodeImage(_ctx: common.Context, uri: string): Promise<string[]> {
    const input: detectBarcode.InputImage = { uri: uri };
    const opts: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE] };
    try {
      const results = await detectBarcode.decode(input, opts);
      const texts: string[] = [];
      for (const r of results) {
        texts.push(r.originalValue);
      }
      return texts;
    } catch (err) {
      return [];
    }
  }
}
