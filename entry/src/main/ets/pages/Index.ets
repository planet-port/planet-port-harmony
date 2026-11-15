@Entry
@Component
struct Index {
  build() {
    Column({ space: 12 }) {
      Text('Planet Port')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('工程骨架占位页')
        .fontSize(14)
        .fontColor('#666666')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
