import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { describe, expect, it } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import {
  appendEvidenceCheck,
  appendEvidenceFailure,
  appendEvidenceTrace,
  flushEvidence,
  TASK14_PRODUCTION_ABILITY_NAME,
  TASK14_PRODUCTION_BUNDLE_NAME,
  TASK14_PRODUCTION_MODULE_NAME,
  setEvidenceStatus
} from '../testability/TestAbility';

const SUITE_NAME: string = 'Phase3UiFlow';
const HTTP_WARNING_CANCEL_TEXT: string = '取消';
const PROFILES_EMPTY_TITLE_TEXT: string = '还没有配置';

export default function Phase3UiFlowTestsuite(): void {
  describe(SUITE_NAME, () => {
    it('launches the production EntryAbility and cancels the plain-http warning without creating a request', 0, async () => {
      appendEvidenceTrace(`${SUITE_NAME}.start`);
      try {
        const abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
        const want: Want = {
          bundleName: TASK14_PRODUCTION_BUNDLE_NAME,
          moduleName: TASK14_PRODUCTION_MODULE_NAME,
          abilityName: TASK14_PRODUCTION_ABILITY_NAME
        };
        await abilityDelegator.startAbility(want);
        const driver = Driver.create();
        await driver.waitForComponent(ON.id('home.profile.manage'), 5000);
        await driver.assertComponentExist(ON.id('home.runtime.primary'));

        const manage = await driver.findComponent(ON.id('home.profile.manage'));
        expect(await manage.getId()).assertEqual('home.profile.manage');
        await manage.click();

        await driver.waitForComponent(ON.id('profiles.add'), 5000);
        await driver.assertComponentExist(ON.text(PROFILES_EMPTY_TITLE_TEXT));
        const addButton = await driver.findComponent(ON.id('profiles.add'));
        await addButton.click();

        await driver.waitForComponent(ON.id('import.file'), 5000);
        const urlInput = await driver.findComponent(ON.id('import.url'));
        await urlInput.inputText('http://plain.example.com/subscription.yaml?token=cancelled');
        const submit = await driver.findComponent(ON.id('import.submit'));
        await submit.click();

        const cancel = await driver.waitForComponent(ON.text(HTTP_WARNING_CANCEL_TEXT), 3000);
        await cancel.click();
        await driver.pressBack();

        await driver.waitForComponent(ON.id('profiles.add'), 5000);
        await driver.assertComponentExist(ON.text(PROFILES_EMPTY_TITLE_TEXT));
        appendEvidenceCheck(`${SUITE_NAME}: navigation/http-cancel pass`);
      } catch (error) {
        setEvidenceStatus('FAIL');
        appendEvidenceFailure(SUITE_NAME, `${error}`);
        throw toError(error);
      } finally {
        await flushEvidence();
      }
    });
  });
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
