// IpcEvents.ets — 跨进程 commonEvent 契约（D1/D5）
//
// 两进程共享同一应用沙盒；控制指令与状态通知走 commonEvent（事件名前缀 =
// 包名倒序 + 应用名，防碰撞）。事件只做「唤醒」，负载一律 level-triggered
// 全量重读（对齐 Android configChanges 有损合并契约：订阅方不得假设收到每一次变更）。
//
// code 语义（publish 的 code 字段，data 不用——负载全走文件）：
//   CONFIG_CHANGED: 主进程写配置后唤醒 VpnExt 全量重读（join/leave/orbit 增量）
//   CMD_STOP:       主进程请求优雅停机（终态化快照后自停扩展进程）
//   CMD_RESTART:    主进程请求进程内换代重启（偏好热生效/行星切换，不重启进程）
//   STATE_CHANGED:  VpnExt 快照已更新，主进程 StatusStore 重读

export class IpcEvents {
  static readonly CONFIG_CHANGED: string = 'cn.imgozi.h.planetport.CONFIG_CHANGED';
  static readonly CMD_STOP: string = 'cn.imgozi.h.planetport.CMD_STOP';
  static readonly CMD_RESTART: string = 'cn.imgozi.h.planetport.CMD_RESTART';
  static readonly STATE_CHANGED: string = 'cn.imgozi.h.planetport.STATE_CHANGED';
}
