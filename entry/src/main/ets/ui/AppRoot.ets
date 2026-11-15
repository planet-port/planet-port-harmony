// AppRoot.ets — A5 路由状态层（Android ui/AppRoot.kt 直译映射）
//
// 形态裁决（控制器）：Android 的 AppRoot Composable 渲染职责并入 Index.ets
// （唯一 @Entry 宿主，负责 when(page) 分发渲染 + 转场 + 系统返回拦截），本文件
// 只承载路由状态与导航 API。逐项映射：
//   sealed interface Page    → Page 判别联合（接口族 + kind 字面量判别）
//   NavStackViewModel(stack) → @ObservedV2 NavHost（@Trace stack，进程内存活；
//     Android 借 ViewModel 挡 Activity recreate，ArkUI 无该回收路径，等价成立）
//   LocalNavigator 注入      → AppNav 单例直引（页内 import 即等价 provides；
//     本文件不 import 任何页面，依赖图无环：pages → AppRoot ← Index → pages）
//   BackHandler(size>1)      → Index.onBackPress 统一拦截（栈深 > 1 pop 返回 true）
// 渲染与转场契约（Index.ets 实现）：栈深 1 渲染 HomeView（无转场），>1 全栈
// 叠加渲染（ForEach 保活真下层页，pop 揭示正确底层）；push 右滑入 / pop 反向
// 300ms Curve.Friction（iOS NavigationStack push 等价；TransitionEffect 自带
// animation，无需 animateTo 包裹）。

// ---- Page 判别联合（Android AppRoot.kt:22 sealed interface 直译）----

export interface PageHome {
  kind: 'home';
}

/** 单字段裁决（计划 brief 有意简化，Android 源为 planetId+nwid 双字段）：行星
 * 归属由消费方经 AppState（activePlanetId/pagerSelection）推断；Android 源警告
 * 的「跨行星同 nwid 串显」风险由 T9 消费侧以行星过滤收口。 */
export interface PageNetworkDetail {
  kind: 'networkDetail';
  networkId: string;
}

export interface PagePrefs {
  kind: 'prefs';
}

export interface PagePlanetSettings {
  kind: 'planetSettings';
  planetId: string;
}

export interface PagePeers {
  kind: 'peers';
  planetId: string;
}

export interface PageMoon {
  kind: 'moon';
  planetId: string;
}

export interface PageApplyTrace {
  kind: 'applyTrace';
  planetId: string;
}

export interface PageAddPlanet {
  kind: 'addPlanet';
}

export type Page = PageHome | PageNetworkDetail | PagePrefs | PagePlanetSettings |
  PagePeers | PageMoon | PageApplyTrace | PageAddPlanet;

const HOME_PAGE: PageHome = { kind: 'home' };

/**
 * 页面栈宿主：首页恒在栈底；pop 在栈底（长度 1）时 no-op（Android
 * BackHandler enabled = size > 1 同语义——回首页后再按返回交还系统退出）。
 */
@ObservedV2
export class NavHost {
  @Trace stack: Page[] = [HOME_PAGE];

  push(page: Page): void {
    this.stack.push(page);
  }

  pop(): void {
    if (this.stack.length > 1) {
      this.stack.pop();
    }
  }
}

/** 全局导航单例（CompositionLocal 注入的直引等价；页内统一经此导航） */
export const AppNav: NavHost = new NavHost();
