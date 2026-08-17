import { ProbePageState, ProbePageStepState, formatTerminalOutcome } from '../probe/ProbeModels';

const probePageStorage: LocalStorage = new LocalStorage();
probePageStorage.setOrCreate('probePageState', new ProbePageState());

@Entry(probePageStorage)
@Component
struct ProbePage {
  @LocalStorageLink('probePageState') pageState: ProbePageState = new ProbePageState();

  build() {
    Column({ space: 12 }) {
      Text('Traffic Probe')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      if (formatTerminalOutcome(this.pageState.overallOutcome).length > 0) {
        Text(formatTerminalOutcome(this.pageState.overallOutcome))
          .fontSize(18)
      }
      ForEach(this.pageState.steps, (step: ProbePageStepState) => {
        if (formatTerminalOutcome(step.outcome).length > 0) {
          Row({ space: 12 }) {
            Text(step.label)
              .layoutWeight(1)
            Text(formatTerminalOutcome(step.outcome))
          }
          .width('100%')
        }
      })
    }
    .padding(24)
    .width('100%')
    .height('100%')
  }
}
