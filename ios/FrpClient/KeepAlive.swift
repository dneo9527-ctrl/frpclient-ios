import CoreLocation
import Foundation

/// Best-effort background assistance. Location content is deliberately ignored.
/// Permission, a requested location session, and observed activity are distinct.
final class KeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationText = "定位权限：尚未授权"
    @Published private(set) var activityText = "定位活动：未启动"
    @Published private(set) var isKeepingAlive = false
    @Published private(set) var canRequestAlways = false

    private let manager = CLLocationManager()
    private var wantsActivity = false
    private var requestedUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        refreshStatus()
    }

    /// Called only by an explicit user action, never by start or auth callbacks.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        refreshStatus()
    }

    /// Optional upgrade, also requires a separate explicit user action.
    func requestAlways() {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        refreshStatus()
    }

    func start() {
        wantsActivity = true
        refreshStatus()
    }

    func stop() {
        wantsActivity = false
        endUpdates()
        activityText = "定位活动：未启动"
    }

    func refreshStatus() {
        let status = manager.authorizationStatus
        canRequestAlways = status == .authorizedWhenInUse
        switch status {
        case .notDetermined:
            authorizationText = "定位权限：尚未授权"
        case .restricted:
            authorizationText = "定位权限：受系统限制"
        case .denied:
            authorizationText = "定位权限：未允许，可在系统设置中修改"
        case .authorizedWhenInUse:
            authorizationText = "定位权限：使用期间允许"
        case .authorizedAlways:
            authorizationText = "定位权限：始终允许"
        @unknown default:
            authorizationText = "定位权限：系统状态未知"
        }

        guard wantsActivity else {
            endUpdates()
            activityText = "定位活动：未启动"
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            endUpdates()
            activityText = "定位活动：系统定位服务已关闭；前台连接仍可使用"
            return
        }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            endUpdates()
            activityText = "定位活动：等待授权；前台连接仍可使用"
            return
        }
        if !requestedUpdates {
            requestedUpdates = true
            manager.startUpdatingLocation()
            activityText = "定位活动：已请求，等待系统反馈"
        } else if isKeepingAlive {
            activityText = "定位活动：运行中；后台连接仍受系统调度影响"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshStatus()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsActivity, requestedUpdates, !locations.isEmpty else { return }
        // Neither coordinates nor timestamps are retained, logged, or sent.
        isKeepingAlive = true
        activityText = "定位活动：运行中；后台连接仍受系统调度影响"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wantsActivity else { return }
        isKeepingAlive = false
        if let locationError = error as? CLError, locationError.code == .denied {
            endUpdates()
            refreshStatus()
        } else {
            // A later successful callback can restore activity without promising
            // that the tunnel remains alive in the meantime.
            activityText = "定位活动：暂时不可用，等待系统恢复；前台连接仍可使用"
        }
    }

    private func endUpdates() {
        if requestedUpdates { manager.stopUpdatingLocation() }
        requestedUpdates = false
        isKeepingAlive = false
    }
}
