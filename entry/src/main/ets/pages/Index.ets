import { CoreRuntime } from '../common/CoreRuntime';

@Entry
@Component
struct Index {
  private version: string = '未加载';

  aboutToAppear(): void {
    this.version = CoreRuntime.getCoreVersion();
  }

  build() {
    Column({ space: 12 }) {
      Text('Planet Port')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text(`ZeroTier 核心 ${this.version}`)
        .fontSize(14)
        .fontColor('#666666')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
