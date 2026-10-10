import Foundation

public struct WeatherQuery: Equatable, Sendable {
    /// 0 = today, 1 = tomorrow, 2 = the day after.
    public let dayOffset: Int
    /// A place named in the question, not yet verified by geocoding.
    public let cityCandidate: String?
}

/// Detects weather questions so live data can be attached to the model request.
/// A false positive only costs one cached lookup, so detection is generous.
public enum WeatherIntentDetector {
    private static let keywords = ["天气", "下雨", "下雪", "气温", "温度", "多少度", "几度", "冷不冷", "热不热", "带伞",
                                   "穿什么", "穿多少", "刮风", "风大", "雾霾", "晴天", "阴天", "降温", "升温", "紫外线",
                                   "weather"]

    public static func detect(_ input: String) -> WeatherQuery? {
        let text = input.filter { !$0.isWhitespace }.lowercased()
        guard text.count <= 60, keywords.contains(where: text.contains) else { return nil }
        // Room/device temperature questions are not about the forecast.
        if text.contains("cpu") || text.contains("电脑") || text.contains("室内") || text.contains("体温") { return nil }
        let dayOffset: Int
        if text.contains("大后天") { dayOffset = 2 } // the forecast window ends at 3 days
        else if text.contains("后天") { dayOffset = 2 }
        else if text.contains("明天") || text.contains("明早") || text.contains("明晚") { dayOffset = 1 }
        else { dayOffset = 0 }
        return WeatherQuery(dayOffset: dayOffset, cityCandidate: cityCandidate(in: text))
    }

    private static let stopWords = [
        "大后天", "后天", "明天", "今天", "今晚", "明早", "明晚", "早上", "上午", "中午", "下午", "晚上", "现在", "这周", "周末",
        "天气预报", "天气", "怎么样", "如何", "会不会", "有没有", "下雨", "下雪", "气温", "温度", "多少度", "几度", "冷不冷",
        "热不热", "带伞", "穿什么", "穿多少", "刮风", "风大不大", "风大", "雾霾", "晴天", "阴天", "降温", "升温", "紫外线",
        "查一下", "查查", "帮我", "请问", "看看", "看一下", "一下", "告诉我", "需要", "外面", "我们", "这里", "这边", "那边",
        "那里", "情况", "适合", "出门", "要不要", "需不需要", "是不是", "什么", "多少", "怎样", "还是", "最高", "最低",
        "会", "要", "冷", "热", "吗", "呢", "啊", "吧", "的", "在", "去", "查", "是", "有", "了", "得", "带", "伞", "穿",
        "那", "你", "我", "请", "好", "很", "不", "大", "小", "高", "低", "度"
    ]

    /// Splits the question at known non-place words and keeps the first plausible name.
    static func cityCandidate(in text: String) -> String? {
        var marked = text
        for word in stopWords.sorted(by: { $0.count > $1.count }) {
            marked = marked.replacingOccurrences(of: word, with: "|")
        }
        // Not `isNumber`: CJK characters such as 京 and 兆 carry numeric values.
        let parts = marked.split(whereSeparator: { $0 == "|" || $0.isPunctuation || $0.isASCII && $0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && $0.count <= 8 && $0.allSatisfy { $0.isLetter } }
        return parts.first
    }
}

/// Open-Meteo needs no API key and only receives coordinates and a place name.
public actor WeatherService {
    public static let shared = WeatherService()

    public struct Place: Sendable, Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private let session: URLSession
    private var places: [String: Place?] = [:]
    private var forecasts: [String: (fetchedAt: Date, report: String)] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Background text for the model. Failures become explicit notes so the model
    /// tells the user instead of inventing weather.
    /// Place priority: a city named in the question, then the manual default city,
    /// then the Mac's current location.
    public func context(for query: WeatherQuery, defaultCity: String, located: LocationService.Place? = nil) async -> String {
        do {
            var place: Place?
            if let candidate = query.cityCandidate { place = try await geocode(candidate) }
            let fallback = defaultCity.trimmingCharacters(in: .whitespacesAndNewlines)
            if place == nil, !fallback.isEmpty { place = try await geocode(fallback) }
            if place == nil, fallback.isEmpty, let located {
                place = Place(name: located.city, latitude: located.latitude, longitude: located.longitude)
            }
            guard let place else {
                return fallback.isEmpty
                    ? "【天气】暂时无法确定用户所在城市（没有定位权限或定位失败），问题里也没有城市名。请用户说出城市，或在小喷设置 → 技能里开启定位或填写城市。"
                    : "【天气】找不到城市“\(fallback)”，请让用户确认城市名称。"
            }
            let report = try await forecast(for: place)
            let day = ["今天", "明天", "后天"][min(query.dayOffset, 2)]
            return "【实时天气数据，来源 Open-Meteo，用户问的是\(day)】\n\(report)"
        } catch is CancellationError {
            return ""
        } catch {
            return "【天气】天气数据暂时获取失败（\(error.localizedDescription)）。请如实告诉用户现在查不到天气，不要猜测。"
        }
    }

    /// Starts a lookup while the user is still speaking; `context` reuses its result.
    public func prefetch(_ query: WeatherQuery, defaultCity: String, located: LocationService.Place?) {
        Task { _ = await context(for: query, defaultCity: defaultCity, located: located) }
    }

    func geocode(_ rawName: String) async throws -> Place? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Open-Meteo matches "杭州" but not "杭州市".
        if name.count > 2, let last = name.last, "市县区省".contains(last) { name.removeLast() }
        if let cached = places[name] { return cached }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                                 URLQueryItem(name: "language", value: "zh"), URLQueryItem(name: "format", value: "json")]
        let json = try await fetchJSON(components.url!)
        try Task.checkCancellation()
        let first = (json["results"] as? [[String: Any]])?.first
        var place: Place?
        if let first, let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double {
            let admin = first["admin1"] as? String
            let display = first["name"] as? String ?? name
            place = Place(name: admin.map { $0.hasPrefix(display) ? display : "\($0)\(display)" } ?? display,
                          latitude: latitude, longitude: longitude)
        }
        places[name] = place
        return place
    }

    private func forecast(for place: Place) async throws -> String {
        let key = "\(place.latitude),\(place.longitude)"
        if let cached = forecasts[key], Date().timeIntervalSince(cached.fetchedAt) < 600 { return cached.report }
        if let task = inFlight[key] { return try await task.value }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3")
        ]
        let url = components.url!
        let task = Task { [session] in
            let json = try await Self.fetchJSON(url, session: session)
            return Self.report(from: json, placeName: place.name)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let report = try await task.value
        forecasts[key] = (Date(), report)
        return report
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        try await Self.fetchJSON(url, session: session)
    }

    private static func fetchJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    static func report(from json: [String: Any], placeName: String) -> String {
        var lines: [String] = []
        if let current = json["current"] as? [String: Any] {
            var parts = ["\(placeName)现在"]
            if let code = number(current["weather_code"]) { parts.append(description(forCode: Int(code))) }
            if let temperature = number(current["temperature_2m"]) { parts.append("气温\(format(temperature))°C") }
            if let apparent = number(current["apparent_temperature"]) { parts.append("体感\(format(apparent))°C") }
            if let humidity = number(current["relative_humidity_2m"]) { parts.append("湿度\(format(humidity))%") }
            if let wind = number(current["wind_speed_10m"]) { parts.append("风速\(format(wind))公里每小时") }
            lines.append(parts.joined(separator: "，"))
        }
        if let daily = json["daily"] as? [String: Any], let days = daily["time"] as? [String] {
            func series(_ key: String) -> [Double?] { (daily[key] as? [Any] ?? []).map(number) }
            let codes = series("weather_code"), highs = series("temperature_2m_max"), lows = series("temperature_2m_min")
            let rain = series("precipitation_probability_max"), uv = series("uv_index_max")
            func value(_ values: [Double?], _ index: Int) -> Double? { index < values.count ? values[index] : nil }
            for (index, label) in ["今天", "明天", "后天"].enumerated() where index < days.count {
                var parts = ["\(label)（\(days[index])）"]
                if let code = value(codes, index) { parts.append(description(forCode: Int(code))) }
                if let low = value(lows, index), let high = value(highs, index) { parts.append("\(format(low))到\(format(high))°C") }
                if let chance = value(rain, index) { parts.append("降水概率\(format(chance))%") }
                if let index = value(uv, index) { parts.append("紫外线指数\(format(index))") }
                lines.append(parts.joined(separator: "，"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// JSON numbers arrive as NSNumber; fixtures may use Int or Double.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    private static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// WMO weather interpretation codes.
    static func description(forCode code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "有雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "米雪"
        case 80, 81: return "阵雨"
        case 82: return "强阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷阵雨伴有冰雹"
        default: return "天气代码\(code)"
        }
    }
}
