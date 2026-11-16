import Foundation
import CoreLocation

/// 把拍摄坐标反查成短地名（「广州」而不是「广东省广州市天河区…」）。
///
/// 三个设计：按 0.001°（约 100m）做缓存 key，一趟旅行几十张只查一次；
/// 串行执行 —— `CLGeocoder` 并发会抛 `CLError.network`；失败一律静默返回 nil，
/// 界面上就是没有 📍，绝不拖慢轮播。
@MainActor
final class LocationNamer {

    static let shared = LocationNamer()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    private init() {}

    /// 同步查缓存。翻页路径上用这个，命中就立刻显示，不命中再异步补。
    func cachedPlace(latitude: Double?, longitude: Double?) -> String? {
        guard let key = Self.key(latitude: latitude, longitude: longitude) else { return nil }
        return cache[key]
    }

    /// 异步反查（带缓存与去重）。
    func place(latitude: Double?, longitude: Double?) async -> String? {
        guard let key = Self.key(latitude: latitude, longitude: longitude),
              let latitude, let longitude else { return nil }
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return await running.value }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.reverseGeocode(latitude: latitude, longitude: longitude)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            cache[key] = result
            Log.photos.debug("place resolved \(key, privacy: .public) -> \(result, privacy: .public)")
        }
        return result
    }

    // MARK: - 内部

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            return marks.first.flatMap(Self.shortName(from:))
        } catch {
            Log.photos.debug("reverse geocode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 从 placemark 里挑最像「城市」的那一级，并去掉「市」后缀。
    private static func shortName(from mark: CLPlacemark) -> String? {
        let candidates = [mark.locality, mark.subAdministrativeArea, mark.administrativeArea, mark.name]
        for candidate in candidates {
            guard var name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            if name.hasSuffix("市") { name.removeLast() }
            // 「中国」这种国家级结果对照片墙没意义，继续往下找
            if name == "中国" || name == "China" { continue }
            return name
        }
        return nil
    }

    private static func key(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.3f,%.3f", latitude, longitude)
    }
}
