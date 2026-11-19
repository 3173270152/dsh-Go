// Flutter 侧通道：把后台保活开关暴露给 Dart
//
// Dart 端调用：
//   MethodChannel('dshgo/keepalive').invokeMethod('status')
//   ... invokeMethod('setAudio', true)
//   ... invokeMethod('setLocation', true)
//   ... invokeMethod('setAll', {'audio': true, 'location': true})
import Flutter
import UIKit

@objc(KeepAliveChannel)
final class KeepAliveChannel: NSObject, FlutterPlugin {

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dshgo/keepalive",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(KeepAliveChannel(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let ka = BackgroundKeepAlive.shared
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "status":
            result(ka.status())
        case "setAudio":
            result(ka.setAudioKeepAlive(args["on"] as? Bool ?? false))
        case "setLocation":
            result(ka.setLocationKeepAlive(args["on"] as? Bool ?? false))
        case "setAll":
            if let audio = args["audio"] as? Bool { _ = ka.setAudioKeepAlive(audio) }
            if let loc = args["location"] as? Bool { _ = ka.setLocationKeepAlive(loc) }
            result(ka.status())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
