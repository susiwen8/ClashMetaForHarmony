# Contributing to Clash Meta for HarmonyOS

Open `harmony/` in DevEco Studio. Follow existing ArkTS/ArkUI, C++ and Go patterns
and the pinned toolchain in [harmony/README.md](harmony/README.md).

Keep changes scoped and protect behavior with regression tests. Run relevant
structure tests, native/Go checks and HAP builds. Report known failures and
device-validation gaps explicitly.

Do not commit signing material, device identifiers, subscription credentials,
local configuration, generated packages or diagnostic artifacts. Do not
reintroduce Android modules or Gradle workflows into this branch.

Preserve [LICENSE](LICENSE), [NOTICE](NOTICE) and
[third-party notices](harmony/THIRD_PARTY_NOTICES.md).

## Historical upstream contribution terms

The original notice is retained below; this cleanup does not change existing
licensing terms:

> Contributing to Clash for Android that assumes you allow code to be merged into closed-source branch of Clash for Android. Other terms follow the [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)
