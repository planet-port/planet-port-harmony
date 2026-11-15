// native 模块 ArkTS 包装（A2 扩展为完整函数族）
import core from 'libplanetport_core.so';

export namespace CoreRuntime {
  export function getCoreVersion(): string {
    return core.getCoreVersion() as string;
  }
}
