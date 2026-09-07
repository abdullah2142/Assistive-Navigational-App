import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // This key is restricted to the Android package + signing certificate,
    // so it will be refused here. iOS is not a shipping platform for ANT; if
    // it becomes one, mint a separate key restricted to the iOS bundle id.
    GMSServices.provideAPIKey("AIzaSyDhDkodAQPeZBisTKq5E3ZC_TOMoIzGPhM")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
