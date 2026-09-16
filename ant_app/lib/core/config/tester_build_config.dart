/// Whether this build is one handed to testers rather than to the public.
///
/// ## Why this exists
///
/// Item 61: "skip button to dashboard gone."
///
/// The ⏩ shortcut past onboarding is wrapped in `kDebugMode`, which is
/// exactly right for a store build — the tree never contains it and the
/// tree shaker drops the branch — and exactly wrong for the people who
/// actually need it. Testers are given **release** builds through Firebase
/// App Distribution, so for them the button does not exist, and
/// `devSkipOnboarding` would refuse to run even if it did. Every testing
/// pack except A begins by skipping onboarding, so all of them were blocked
/// on a control nobody could reach.
///
/// `kDebugMode` was answering the wrong question. The question is not "was
/// this compiled in debug mode" but "is this build going to a tester or to
/// the public", and those are different things that happened to coincide
/// until the app started being distributed.
///
/// ## What it does not do
///
/// It does not weaken anything on a public build. The default is false, so
/// a build made without the flag behaves exactly as before — the shortcut
/// is absent from the tree and the controller refuses it. Only a build
/// deliberately made with `--dart-define=TESTER_BUILD=true` carries it, and
/// `release_google_build.sh` — which only ever distributes to the tester
/// group — is the one place that passes it.
///
/// It is deliberately separate from `EmergencyConfig.liveDispatch`. That
/// flag decides whether real messages reach somebody's family, and must
/// stay an explicit, isolated decision rather than something that rides
/// along with a general "this is a tester build" switch.
class TesterBuildConfig {
  const TesterBuildConfig._();

  static const bool isTesterBuild = bool.fromEnvironment('TESTER_BUILD', defaultValue: false);
}
