import AppKit
import SwiftUI

// MARK: - The real weather

struct WeatherDay: Identifiable {
    let id: String        // the date, yyyy-MM-dd
    let label: String     // "Today", "Sun", "Mon"…
    let code: Int         // WMO weather code
    let high: Int
    let low: Int
    let rain: Int         // chance of rain or snow, 0...100
    let wind: Int         // strongest wind of the day
}

/// What the rest of the app may read without touching the weather service:
/// how hard the cloud should rain, and the forecast in words for the forecaster's brain.
enum SkyState {
    static var rain: CGFloat = 0.15
    static var briefing = ""
}

/// Five days of weather for the person's area, from Open-Meteo (free, no key).
/// The place comes from what they told the forecaster (place.txt in its folder), or WEATHER_PLACE in .env.
/// Only the place name and its coordinates leave this Mac.
@MainActor
final class WeatherService: ObservableObject {
    @Published var days: [WeatherDay] = []
    @Published var place = ""
    @Published var note = ""      // shown instead of the days when there is nothing to show
    @Published var now = 0        // the temperature right now
    @Published var feels = 0
    @Published var nowCode = 3
    @Published var isDay = true
    @Published var windNow = 0
    @Published var metric = false

    private let placeFile: URL
    private var fetchedAt = Date.distantPast
    private var fetchedFor = ""
    private var loading = false

    private static var shared: [String: WeatherService] = [:]

    static func of(_ id: String) -> WeatherService {
        if let existing = shared[id] { return existing }
        let service = WeatherService(id: id)
        shared[id] = service
        return service
    }

    private init(id: String) {
        placeFile = Harness.forecastFolder(for: id).appendingPathComponent("place.txt")
    }

    var wantedPlace: String {
        let told = (try? String(contentsOf: placeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !told.isEmpty { return told }
        return Config.key("WEATHER_PLACE") ?? ""
    }

    /// Remembers a new town and looks it up straight away.
    func setPlace(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        try? FileManager.default.createDirectory(at: placeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? clean.write(to: placeFile, atomically: true, encoding: .utf8)
        refresh(force: true)
    }

    /// Fetches if there is nothing yet, the place changed, or the last fetch is over half an hour old.
    func refresh(force: Bool = false) {
        let wanted = wantedPlace
        if wanted.isEmpty {
            days = []
            note = "Tell me your city and I'll read your sky."
            SkyState.briefing = ""
            SkyState.rain = 0.15
            return
        }
        if loading { return }
        if !force && wanted == fetchedFor && !days.isEmpty && Date().timeIntervalSince(fetchedAt) < 1800 { return }
        loading = true
        if days.isEmpty { note = "Looking up…" }
        Task { @MainActor in
            defer { loading = false }
            do {
                let (lat, lon, name) = try await Self.locate(wanted)
                try await load(lat: lat, lon: lon)
                place = name
                note = ""
                fetchedFor = wanted
                fetchedAt = Date()
                publish()
            } catch {
                if days.isEmpty { note = "Couldn't reach the sky for \(wanted)." }
            }
        }
    }

    private static func locate(_ name: String) async throws -> (Double, Double, String) {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "format", value: "json")]
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double
        else { throw URLError(.cannotFindHost) }
        return (lat, lon, first["name"] as? String ?? name)
    }

    private static func number(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }

    private func load(lat: Double, lon: Double) async throws {
        let us = Locale.current.measurementSystem == .us
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", lon)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "5"),
        ]
        if us {
            items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
            items.append(URLQueryItem(name: "wind_speed_unit", value: "mph"))
        }
        parts.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Any],
              let highs = daily["temperature_2m_max"] as? [Any],
              let lows = daily["temperature_2m_min"] as? [Any]
        else { throw URLError(.cannotParseResponse) }
        let rains = daily["precipitation_probability_max"] as? [Any] ?? []
        let winds = daily["wind_speed_10m_max"] as? [Any] ?? []

        let reader = DateFormatter()
        reader.dateFormat = "yyyy-MM-dd"
        let writer = DateFormatter()
        writer.dateFormat = "EEE"
        var out: [WeatherDay] = []
        let count = min(5, dates.count, codes.count, highs.count, lows.count)
        var i = 0
        while i < count {
            let label = i == 0 ? "Today" : (reader.date(from: dates[i]).map { writer.string(from: $0) } ?? dates[i])
            out.append(WeatherDay(id: dates[i], label: label,
                                  code: Int(Self.number(codes[i])),
                                  high: Int(Self.number(highs[i]).rounded()),
                                  low: Int(Self.number(lows[i]).rounded()),
                                  rain: i < rains.count ? Int(Self.number(rains[i]).rounded()) : 0,
                                  wind: i < winds.count ? Int(Self.number(winds[i]).rounded()) : 0))
            i += 1
        }
        days = out
        metric = !us
        if let current = json["current"] as? [String: Any] {
            now = Int(Self.number(current["temperature_2m"]).rounded())
            feels = Int(Self.number(current["apparent_temperature"]).rounded())
            nowCode = Int(Self.number(current["weather_code"]))
            isDay = Self.number(current["is_day"]) > 0.5
            windNow = Int(Self.number(current["wind_speed_10m"]).rounded())
        }
    }

    /// Passes the forecast on: the cloud rains as hard as today's chance of rain, and the brain gets it in words.
    private func publish() {
        guard let today = days.first else { return }
        SkyState.rain = 0.05 + 0.85 * CGFloat(today.rain) / 100
        let degrees = metric ? "°C" : "°F"
        let speed = metric ? "km/h" : "mph"
        var text = "Place: \(place). Units: \(degrees), wind in \(speed)."
        text += "\nRight now: \(now)\(degrees), feels like \(feels)\(degrees), \(Self.words(nowCode).lowercased()), wind \(windNow) \(speed)."
        for day in days {
            text += "\n\(day.label) (\(day.id)): \(Self.words(day.code).lowercased()), high \(day.high), low \(day.low), chance of rain \(day.rain)%, wind up to \(day.wind) \(speed)."
        }
        SkyState.briefing = text
    }

    /// The icon for a WMO weather code.
    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0, 1: return day ? "sun.max.fill" : "moon.stars.fill"
        case 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 61, 63, 66, 67, 80, 81: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// The same code in a word or two.
    static func words(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 66, 67, 80, 81: return "Rain"
        case 65, 82: return "Heavy rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }

    /// The colours of the sky for a code, top to bottom.
    static func sky(_ code: Int, day: Bool) -> [Color] {
        if !day {
            return [Color(red: 0.05, green: 0.07, blue: 0.18), Color(red: 0.16, green: 0.17, blue: 0.36)]
        }
        switch code {
        case 0, 1:
            return [Color(red: 0.16, green: 0.47, blue: 0.92), Color(red: 0.50, green: 0.76, blue: 0.98)]
        case 2:
            return [Color(red: 0.26, green: 0.48, blue: 0.80), Color(red: 0.58, green: 0.72, blue: 0.88)]
        case 71, 73, 75, 77, 85, 86:
            return [Color(red: 0.45, green: 0.53, blue: 0.64), Color(red: 0.72, green: 0.78, blue: 0.86)]
        case 95, 96, 99:
            return [Color(red: 0.14, green: 0.12, blue: 0.24), Color(red: 0.32, green: 0.28, blue: 0.44)]
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82:
            return [Color(red: 0.18, green: 0.24, blue: 0.34), Color(red: 0.36, green: 0.44, blue: 0.55)]
        default:
            return [Color(red: 0.30, green: 0.36, blue: 0.46), Color(red: 0.52, green: 0.58, blue: 0.67)]
        }
    }
}

// MARK: - The ribbon: five days as one band of temperature

/// Five days drawn as a single ribbon. The top edge is each day's high, the bottom edge its low,
/// so the shape of the week is visible at a glance: where it warms, where it cools, how wide each day swings.
/// Icons ride above the ribbon and the chance of rain hangs below it.
struct SkyRibbon: View {
    let days: [WeatherDay]
    var compact = false

    private let warm = Color(red: 1.0, green: 0.62, blue: 0.22)
    private let cool = Color(red: 0.36, green: 0.66, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let top: CGFloat = compact ? 54 : 78           // room for the day name and icon
            let bottom: CGFloat = compact ? 30 : 50        // room for the rain
            let plot = CGRect(x: 0, y: top + 18, width: size.width, height: max(20, size.height - top - bottom - 36))
            let highs = points(for: days.map { $0.high }, in: plot)
            let lows = points(for: days.map { $0.low }, in: plot)
            ZStack(alignment: .topLeading) {
                // Today's column, picked out softly.
                if !days.isEmpty {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: size.width / CGFloat(days.count) - 6, height: size.height)
                        .offset(x: 3, y: 0)
                }
                band(highs: highs, lows: lows, width: size.width)
                    .fill(LinearGradient(colors: [warm.opacity(0.85), cool.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                curve(through: highs, width: size.width)
                    .stroke(warm, style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                curve(through: lows, width: size.width)
                    .stroke(cool, style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    column(day, high: highs[index], low: lows[index], size: size, top: top, bottom: bottom)
                }
            }
        }
    }

    /// Where each temperature sits: evenly spaced across, and scaled between the week's coldest and warmest.
    private func points(for values: [Int], in plot: CGRect) -> [CGPoint] {
        let all = days.map { $0.high } + days.map { $0.low }
        let lowest = CGFloat(all.min() ?? 0) - 1
        let highest = CGFloat(all.max() ?? 1) + 1
        let span = max(1, highest - lowest)
        var out: [CGPoint] = []
        for (index, value) in values.enumerated() {
            let x = plot.minX + (CGFloat(index) + 0.5) * plot.width / CGFloat(max(1, values.count))
            let y = plot.maxY - (CGFloat(value) - lowest) / span * plot.height
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }

    /// The points with one added at each edge, so the ribbon runs the full width.
    private func extended(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        return [CGPoint(x: 0, y: first.y)] + points + [CGPoint(x: width, y: last.y)]
    }

    /// Adds a smooth line through the points to a path that is already at the first one.
    private func addSmooth(_ points: [CGPoint], to path: inout Path) {
        var i = 1
        while i < points.count {
            let a = points[i - 1]
            let b = points[i]
            let mid = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
            i += 1
        }
    }

    private func curve(through points: [CGPoint], width: CGFloat) -> Path {
        var path = Path()
        let all = extended(points, width: width)
        guard let first = all.first else { return path }
        path.move(to: first)
        addSmooth(all, to: &path)
        return path
    }

    private func band(highs: [CGPoint], lows: [CGPoint], width: CGFloat) -> Path {
        var path = Path()
        let upper = extended(highs, width: width)
        let lower = Array(extended(lows, width: width).reversed())
        guard let first = upper.first, let turn = lower.first else { return path }
        path.move(to: first)
        addSmooth(upper, to: &path)
        path.addLine(to: turn)
        addSmooth(lower, to: &path)
        path.closeSubpath()
        return path
    }

    /// Everything that belongs to one day: its name and icon above, its high and low on the ribbon, its rain below.
    private func column(_ day: WeatherDay, high: CGPoint, low: CGPoint, size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
        let width = size.width / CGFloat(max(1, days.count))
        return ZStack(alignment: .topLeading) {
            VStack(spacing: compact ? 2 : 5) {
                Text(day.label)
                    .font(.system(size: compact ? 11 : 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Image(systemName: WeatherService.symbol(day.code))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: compact ? 22 : 32))
                    .frame(height: compact ? 26 : 38)
            }
            .frame(width: width)
            .offset(x: high.x - width / 2, y: compact ? 6 : 10)

            Text("\(day.high)°")
                .font(.system(size: compact ? 13 : 17, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .frame(width: width)
                .offset(x: high.x - width / 2, y: high.y - (compact ? 19 : 25))
            Circle().fill(Color.white).frame(width: 7, height: 7)
                .offset(x: high.x - 3.5, y: high.y - 3.5)

            Text("\(day.low)°")
                .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: width)
                .offset(x: low.x - width / 2, y: low.y + 6)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 6)
                .offset(x: low.x - 3, y: low.y - 3)

            HStack(spacing: 3) {
                Image(systemName: day.rain >= 50 ? "drop.fill" : "drop")
                    .font(.system(size: compact ? 9 : 11))
                Text("\(day.rain)%")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(day.rain >= 50 ? cool : Color.white.opacity(0.55))
            .frame(width: width)
            .offset(x: high.x - width / 2, y: size.height - bottom + (compact ? 8 : 16))
        }
    }
}

// MARK: - The drop-down under the cloud

/// Click the cloud and the week falls out of it.
struct WeatherDropView: View {
    @ObservedObject var service: WeatherService

    var body: some View {
        VStack(spacing: 6) {
            if service.days.isEmpty {
                Text(service.note)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(service.now)°")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text(WeatherService.words(service.nowCode))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(service.place)
                        .font(.system(size: 11, design: .rounded))
                        .opacity(0.7)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                SkyRibbon(days: service.days, compact: true)
                    .frame(width: 330, height: 190)
            }
        }
        .padding(.vertical, 10)
        .frame(width: service.days.isEmpty ? 240 : 330)
        .background(LinearGradient(colors: WeatherService.sky(service.nowCode, day: service.isDay), startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .fixedSize()
    }
}

/// A small floating panel that drops down under the cloud on a click, and goes away on the next.
@MainActor
final class WeatherDropController {
    private let panel: NSPanel
    private let host: NSHostingView<WeatherDropView>
    private let service: WeatherService

    init(id: String) {
        service = WeatherService.of(id)
        let rect = NSRect(x: 0, y: 0, width: 330, height: 250)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: WeatherDropView(service: service))
        host.frame = rect
        panel.contentView = host
        service.refresh()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    /// Keeps the forecast fresh through the day, so the cloud's own rain follows the real sky.
    func keepFresh() {
        service.refresh()
    }

    func show() {
        service.refresh()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Keeps the panel under the cloud as it drifts, or above it when there's no room below.
    func tick(anchor: CGRect, screen: CGRect) {
        if !panel.isVisible { return }
        let size = host.fittingSize
        if panel.frame.size != size { panel.setContentSize(size) }
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - 6
        if y < screen.minY + 8 { y = anchor.maxY + 8 }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
