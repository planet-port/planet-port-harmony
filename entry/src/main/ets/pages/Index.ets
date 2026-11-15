// Index.ets — 唯一 @Entry：NavHost 渲染宿主（Android ui/AppRoot.kt Composable 直译）
//
// 职责（形态裁决）：①栈底 HomeView 恒挂渲染（无转场）②栈深 > 1 时全栈叠加
// 渲染（ForEach 逐项渲染，真下层页保活——pop 转场揭示正确底层，对齐 iOS
// NavigationStack）③push/pop 自绘转场：右滑入 300ms Curve.Friction、pop 反向
// （TransitionEffect 自带 animation，等价 animateTo 包裹且时序自持）
// ④系统返回统一拦截（Android BackHandler(enabled = size > 1) 直译）。
// 注：版本占位（CoreRuntime 核心版本号）随首页骨架替换退场，构建信息展示归
// T10 关于段（非隐藏式下线——该占位本身是 A1 编译验证脚手架）。
import { AppNav, NavHost, Page, PageNetworkDetail, PagePlanetSettings, PagePeers,
  PageMoon, PageApplyTrace } from '../ui/AppRoot';
import { DesignTokens } from '../components/DesignTokens';
import { HomeView } from './HomeView';
import { NetworkDetailView } from './NetworkDetailView';
import { PrefsView } from './PrefsView';
import { PlanetSettingsView } from './PlanetSettingsView';
import { PeerListView } from './PeerListView';
import { MoonView } from './MoonView';
import { ApplyTraceView } from './ApplyTraceView';
import { AddPlanetPage } from './AddPlanetPage';

/** push/pop 转场效果（iOS push 右滑入 300ms friction 直译；appear/disappear 对称） */
const NAV_PUSH_EFFECT: TransitionEffect = TransitionEffect
  .translate({ x: '100%' })
  .animation({ duration: 300, curve: Curve.Friction });

@Entry
@ComponentV2
struct Index {
  @Local nav: NavHost = AppNav;

  build() {
    Stack() {
      // 栈底恒挂（栈深 1 即本页全屏；上层页转场时作为底层保留）
      HomeView()
      ForEach(this.nav.stack, (page: Page, idx: number) => {
        if (idx > 0) {
          Column() {
            this.pageBody(page)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(DesignTokens.pageBg(DesignTokens.dark()))
          .transition(NAV_PUSH_EFFECT)
        }
      }, (page: Page, idx: number) => `${idx}:${page.kind}`) // key 含 idx：仅尾部 push/pop 语义下稳定（中段移除会全量重建，评审 M-4）
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(DesignTokens.dark()))
  }

  /** 栈顶页按 kind 分发（Android AppRoot.kt when(page) 直译）；
   *  四个带参页按 brief 契约传参。 */
  @Builder
  pageBody(page: Page) {
    if (page.kind === 'networkDetail') {
      NetworkDetailView({ networkId: (page as PageNetworkDetail).networkId })
    } else if (page.kind === 'prefs') {
      PrefsView()
    } else if (page.kind === 'planetSettings') {
      PlanetSettingsView({ planetId: (page as PagePlanetSettings).planetId })
    } else if (page.kind === 'peers') {
      PeerListView({ planetId: (page as PagePeers).planetId })
    } else if (page.kind === 'moon') {
      MoonView({ planetId: (page as PageMoon).planetId })
    } else if (page.kind === 'applyTrace') {
      ApplyTraceView({ planetId: (page as PageApplyTrace).planetId })
    } else if (page.kind === 'addPlanet') {
      AddPlanetPage()
    } else {
      HomeView() // default 兜底（含误 push home——评审 M-5：不静默空白盖屏）
    }
  }

  /** 系统返回：栈深 > 1 时拦截并 pop（返回 true）；已回首页则放行系统退出 */
  onBackPress(): boolean {
    if (this.nav.stack.length > 1) {
      this.nav.pop();
      return true;
    }
    return false;
  }
}
