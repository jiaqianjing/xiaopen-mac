import Foundation
import CoreLocation
import Observation
import AppKit
import OSLog

/// City-level location from macOS Location Services (on a Mac this is mostly
/// Wi-Fi positioning). Only the city name and rounded coordinates leave this
/// class; nothing is stored on disk.
@Observable
@MainActor
public final class LocationService: NSObject, CLLocationManagerDelegate {
    public static let shared = LocationService()

    public struct Place: Sendable, Equatable {
        public let city: String
        public let latitude: Double
        public let longitude: Double
    }

    public private(set) var place: Place?
    public private(set) var status = "尚未定位"
    public private(set) var isDenied = false
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiters: [CheckedContinuation<Place?, Never>] = []
    @ObservationIgnored private var updatedAt: Date?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "location")

    private override init() {
        super.init()
        manager.delegate = self
        // City level is enough for weather and is the fastest fix to obtain.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// A cached place, refreshed in the background when older than 30 minutes.
    /// Never waits longer than `timeout`, so a slow fix cannot delay a reply.
    public func currentPlace(timeout: TimeInterval = 3) async -> Place? {
        if let place, let updatedAt, Date().timeIntervalSince(updatedAt) < 1800 { return place }
        guard CLLocationManager.locationServicesEnabled() else {
            status = "系统定位服务已关闭"
            return place
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            isDenied = true
            status = "未获得定位权限"
            return place
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        status = "正在定位..."
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 {
                manager.requestLocation()
                timeoutTask?.cancel()
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled, !self.waiters.isEmpty else { return }
                    if self.place == nil { self.status = "定位超时，稍后会再试" }
                    self.finish(with: self.place)
                }
            }
        }
    }

    /// Asks for permission early, e.g. at launch, so the first weather question is not delayed by a dialog.
    public func prepare() {
        Task { _ = await currentPlace(timeout: 15) }
    }

    public func refresh() {
        updatedAt = nil
        prepare()
    }

    public func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func finish(with place: Place?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: place) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in
            self.isDenied = authorization == .denied || authorization == .restricted
            if self.isDenied {
                self.status = "未获得定位权限"
                self.finish(with: self.place)
            } else if authorization != .notDetermined, !self.waiters.isEmpty {
                self.manager.requestLocation()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.resolve(location) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.logger.error("定位失败：\(message, privacy: .public)")
            if self.place == nil { self.status = "定位失败：\(message)" }
            self.finish(with: self.place)
        }
    }

    private func resolve(_ location: CLLocation) async {
        let latitude = (location.coordinate.latitude * 100).rounded() / 100
        let longitude = (location.coordinate.longitude * 100).rounded() / 100
        var city = place?.city ?? ""
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN"))
            if let mark = marks.first {
                // Municipalities such as 北京 have no locality on some marks.
                city = Self.cityName(locality: mark.locality, subAdministrativeArea: mark.subAdministrativeArea,
                                     administrativeArea: mark.administrativeArea) ?? city
            }
        } catch {
            logger.error("城市名解析失败：\(error.localizedDescription, privacy: .public)")
        }
        let resolved = Place(city: city.isEmpty ? "当前位置" : city, latitude: latitude, longitude: longitude)
        place = resolved
        updatedAt = Date()
        status = "已定位：\(resolved.city)"
        finish(with: resolved)
    }

    static func cityName(locality: String?, subAdministrativeArea: String?, administrativeArea: String?) -> String? {
        let name = [locality, subAdministrativeArea, administrativeArea]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard var name else { return nil }
        if name.count > 2, let last = name.last, last == "市" { name.removeLast() }
        return name
    }
}
