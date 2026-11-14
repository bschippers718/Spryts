import AppKit
import SwiftUI

// MARK: - The real weather, for the forecaster's drop-down

struct WeatherDay: Identifiable {
    let id: String        // the date, yyyy-MM-dd
    let label: String     // "Today", "Sun", "Mon"…
    let code: Int         // WMO weather code
    let high: Int
    let low: Int
}

/// The next four days for the person's area, from Open-Meteo (free, no key).
/// The place comes from what they told the forecaster (place.txt in its folder), or WEATHER_PLACE in .env.
/// Only the place name and its coordinates leave this Mac.
@MainActor
final class WeatherService: ObservableObject {
    @Published var days: [WeatherDay] = []
    @Published var place = ""
    @Published var note = ""      // shown instead of the days when there is nothing to show

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

    private var wantedPlace: String {
        let told = (try? String(contentsOf: placeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !told.isEmpty { return told }
        return Config.key("WEATHER_PLACE") ?? ""
    }

    /// Fetches if there is nothing yet, the place changed, or the last fetch is over half an hour old.
    func refresh() {
        let wanted = wantedPlace
        if wanted.isEmpty {
            days = []
            note = "Tell me your city and I'll read your sky."
            return
        }
        if loading { return }
        if wanted == fetchedFor && !days.isEmpty && Date().timeIntervalSince(fetchedAt) < 1800 { return }
        loading = true
        if days.isEmpty { note = "Looking up…" }
        Task { @MainActor in
            defer { loading = false }
            do {
                let (lat, lon, name) = try await Self.locate(wanted)
                days = try await Self.forecast(lat: lat, lon: lon)
                place = name
                note = ""
                fetchedFor = wanted
                fetchedAt = Date()
            } catch {
                days = []
                note = "Couldn't reach the sky for \(wanted)."
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

    private static func forecast(lat: Double, lon: Double) async throws -> [WeatherDay] {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", lon)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
        ]
        if Locale.current.measurementSystem == .us {
            items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
        }
        parts.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Int],
              let highs = daily["temperature_2m_max"] as? [Double],
              let lows = daily["temperature_2m_min"] as? [Double]
        else { throw URLError(.cannotParseResponse) }

        let reader = DateFormatter()
        reader.dateFormat = "yyyy-MM-dd"
        let writer = DateFormatter()
        writer.dateFormat = "EEE"
        var out: [WeatherDay] = []
        for i in 0..<min(4, dates.count, codes.count, highs.count, lows.count) {
            let label = i == 0 ? "Today" : (reader.date(from: dates[i]).map { writer.string(from: $0) } ?? dates[i])
            out.append(WeatherDay(id: dates[i], label: label, code: codes[i],
                                  high: Int(highs[i].rounded()), low: Int(lows[i].rounded())))
        }
        return out
    }

    /// The icon for a WMO weather code.
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0, 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
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
}

// MARK: - The drop-down under the cloud

struct WeatherDropView: View {
    @ObservedObject var service: WeatherService

    var body: some View {
        VStack(spacing: 8) {
            if service.days.isEmpty {
                Text(service.note)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6)
            } else {
                HStack(spacing: 14) {
                    ForEach(service.days) { day in
                        VStack(spacing: 5) {
                            Text(day.label)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.75))
                            Image(systemName: WeatherService.symbol(day.code))
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 24))
                                .frame(height: 28)
                            Text("\(day.high)°")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("\(day.low)°")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(minWidth: 40)
                    }
                }
                if !service.place.isEmpty {
                    Text(service.place)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(red: 0.12, green: 0.14, blue: 0.20).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        let rect = NSRect(x: 0, y: 0, width: 260, height: 110)
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
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
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
