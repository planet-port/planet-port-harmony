// StoreRepo.ets — store 层进程单例门面（直译 store/StoreRepo.kt）
//
// 幂等 double-checked（ArkTS 单线程，check 即足）；以首次 filesDir 为准。
// VpnExt 进程与主进程各自 init——两实例指向同一沙盒路径。
// 未初始化即访问是编程错误：直接抛出（fail fast，对齐 Kotlin checkNotNull）。
import { Context } from '@kit.AbilityKit';
import { AppConfigStore } from './AppConfigStore';
import { StorePaths } from './StorePaths';

export class StoreRepo {
  private static storeRef: AppConfigStore | null = null;

  static init(ctx: Context): void {
    if (StoreRepo.storeRef !== null) return;
    StoreRepo.storeRef = new AppConfigStore(StorePaths.of(ctx));
  }

  static get store(): AppConfigStore {
    const ref = StoreRepo.storeRef; // 局部变量承载，保证 null 收窄可靠
    if (ref === null) {
      throw new Error('StoreRepo 未初始化：须先调用 StoreRepo.init(context)');
    }
    return ref;
  }
}
