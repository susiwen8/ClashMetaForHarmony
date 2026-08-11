@Entry
@Component
struct Index {
  build() {
    Column() {
      Text($r('app.string.testability_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
