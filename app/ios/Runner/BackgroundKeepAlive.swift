// 后台保活 —— iOS 沙盒环境下维持 dsh-go 引擎存活
//
// 两条独立通道，可单独开关：
//   1. audio   ：循环播放极低幅度静音音频。依赖 Info.plist 的 UIBackgroundModes=audio
//                （工程里已有），App 进入后台后不会被立刻挂起。
//   2. location：CLLocationManager 持续定位。需要 UIBackgroundModes 追加 location，
//                且权限为「始终允许」。定位精度调到最低、距离过滤拉大，尽量省电。
//
// 注意：这只是「延缓挂起」，不是真常驻。iOS 仍可能在极端情况下回收进程；
// 做到长期稳定必须越狱 + launchd daemon。

import Foundation
import AVFoundation
import CoreLocation

@objc(BackgroundKeepAlive)
final class BackgroundKeepAlive: NSObject {

    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var audioActive = false
    private var locationActive = false

    private override init() { super.init() }

    // MARK: - 音频通道

    /// 生成一段 1 秒的极低幅度正弦波（-60 dBFS），循环播放。
    /// 不用全零 PCM：部分 iOS 版本会把它当作静音流回落到低优先级。
    private func makeNearSilentWAV(seconds: Double = 1.0, sampleRate: Double = 8000) -> Data? {
        let frames = Int(seconds * sampleRate)
        let amplitude: Int16 = 6           // ≈ -62 dBFS，人耳不可闻
        let freq = 220.0
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = Int16(Double(amplitude) * sin(2.0 * .pi * freq * t))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + pcm.count))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1)             // PCM, mono
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2))
        le16(2); le16(16)
        wav.append("data".data(using: .ascii)!)
        le32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

    @discardableResult
    func setAudioKeepAlive(_ on: Bool) -> Bool {
        if on == audioActive { return audioActive }
        guard on else {
            player?.stop(); player = nil
            audioActive = false
            try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + .mixWithOthers：不打断别的 App 的音乐，也不被电话打断后彻底停掉
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers])
            try session.setActive(true)
            guard let wav = makeNearSilentWAV() else { return false }
            let p = try AVAudioPlayer(data: wav)
            p.numberOfLoops = -1          // 无限循环
            p.volume = 0.0                // 输出音量归零，双保险
            p.prepareToPlay()
            p.play()
            player = p
            audioActive = true
            return true
        } catch {
            NSLog("[dshgo] 音频保活启动失败: \(error)")
            audioActive = false
            return false
        }
    }

    // MARK: - 定位通道

    @discardableResult
    func setLocationKeepAlive(_ on: Bool) -> Bool {
        if on == locationActive { return locationActive }
        guard on else {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            locationActive = false
            return false
        }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // 最省电
        m.distanceFilter = 3000                                   // 3km 才回调一次
        m.pausesLocationUpdatesAutomatically = false
        m.allowsBackgroundLocationUpdates = true                  // 需要 location background mode
        let status = m.authorizationStatus
        if status == .notDetermined {
            m.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            m.startUpdatingLocation()
            locationActive = true
        } else {
            return false
        }
        locationManager = m
        return true
    }

    // MARK: - 状态查询

    func status() -> [String: Any] {
        let s = CLLocationManager().authorizationStatus
        let locAuth: String
        switch s {
        case .authorizedAlways: locAuth = "always"
        case .authorizedWhenInUse: locAuth = "whenInUse"
        case .denied: locAuth = "denied"
        case .restricted: locAuth = "restricted"
        case .notDetermined: locAuth = "notDetermined"
        @unknown default: locAuth = "unknown"
        }
        return [
            "audio": audioActive,
            "location": locationActive,
            "locationAuthorization": locAuth,
        ]
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 只要回调就算续命成功，不消费坐标
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[dshgo] 定位回调错误: \(error.localizedDescription)")
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            locationActive = true
        }
    }
}
