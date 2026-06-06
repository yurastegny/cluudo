import SwiftUI
import Combine
import UserNotifications

@MainActor
class WeatherManager: ObservableObject {
    @Published var forecast: ForecastResponse?
    @Published var isLoading = false
    @Published var error: String?
    @Published var locationSuggestions: [SearchLocation] = []

    @AppStorage("location")            var location            = ""
    @AppStorage("locationDisplayName") var locationDisplayName = ""
    @AppStorage("useCelsius")          var useCelsius          = true
    @AppStorage("useKmhWind")          var useKmhWind          = false
    @AppStorage("showMenuBarIcon")     var showMenuBarIcon      = false
    @AppStorage("useMonochromeWeatherIcons") var useMonochromeWeatherIcons = true
    @AppStorage("precipNotifications") var precipNotifications  = false
    @AppStorage("autoLocation")        var autoLocation         = false
    @AppStorage("ipLocLat")            var ipLocLat             = 0.0
    @AppStorage("ipLocLon")            var ipLocLon             = 0.0
    @AppStorage("ipLocCity")           var ipLocCity            = ""
    @AppStorage("ipLocDate")           var ipLocDate            = 0.0

    let settingsController = SettingsWindowController()

    var onUpdate: (() -> Void)?

    private var refreshTimer: Timer?
    private var settingsRefreshTask: Task<Void, Never>?
    private var locationSearchTask: Task<Void, Never>?
    private var lastHasPrecip: Bool?
    private var refreshGeneration = 0

    init() {
        if location == "auto:ip" {
            location = ""
        }
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func updateAutoLocation(_ enabled: Bool) {
        autoLocation = enabled
        if enabled {
            forecast = nil
            error = nil
            onUpdate?()
            Task { await refresh() }
        } else {
            onUpdate?()
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var requestLocation = location
        var requestDisplayName: String? = locationDisplayName.isEmpty ? nil : locationDisplayName

        if autoLocation {
            do {
                let ipLoc = try await fetchIPLocation()
                requestLocation = "\(ipLoc.lat),\(ipLoc.lon)"
                requestDisplayName = ipLoc.city
            } catch {
                self.error = error.localizedDescription
                isLoading = false
                onUpdate?()
                return
            }
        }

        isLoading = true
        error = nil
        do {
            let response = try await WeatherService.shared.fetch(
                location: requestLocation,
                displayNameOverride: requestDisplayName ?? locationDisplayName
            )
            guard generation == refreshGeneration else { return }
            forecast = response
        } catch {
            guard generation == refreshGeneration else { return }
            self.error = error.localizedDescription
            forecast = nil
        }
        isLoading = false
        checkPrecipChange()
        onUpdate?()
    }

    func settingsChanged() {
        forecast = nil
        error = nil
        lastHasPrecip = nil
        refreshGeneration += 1
        settingsRefreshTask?.cancel()
        Task { await refresh() }
    }

    func updateLocationInput(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location != normalized else { return }
        location = normalized
        locationDisplayName = ""
        scheduleLocationSearch(for: value)
        scheduleSettingsRefresh()
    }

    func chooseLocationSuggestion(_ suggestion: SearchLocation) {
        locationSearchTask?.cancel()
        locationSuggestions = []
        location = suggestion.queryValue
        locationDisplayName = suggestion.name
        scheduleSettingsRefresh()
    }

    func updateUseCelsius(_ value: Bool) {
        guard useCelsius != value else { return }
        useCelsius = value
        onUpdate?()
    }

    func updateUseKmhWind(_ value: Bool) {
        guard useKmhWind != value else { return }
        useKmhWind = value
        onUpdate?()
    }

    func updateShowMenuBarIcon(_ value: Bool) {
        guard showMenuBarIcon != value else { return }
        showMenuBarIcon = value
        onUpdate?()
    }

    func updateUseMonochromeWeatherIcons(_ value: Bool) {
        guard useMonochromeWeatherIcons != value else { return }
        useMonochromeWeatherIcons = value
        onUpdate?()
    }

    private func scheduleSettingsRefresh() {
        forecast = nil
        error = nil
        lastHasPrecip = nil
        refreshGeneration += 1
        onUpdate?()

        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func scheduleLocationSearch(for value: String) {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        locationSearchTask?.cancel()

        guard query.count >= 2,
              query.range(of: #"^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$"#, options: .regularExpression) == nil
        else {
            locationSuggestions = []
            return
        }

        locationSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            do {
                let results = try await WeatherService.shared.searchLocations(query: query)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.locationSuggestions = Array(results.prefix(5))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.locationSuggestions = []
                }
            }
        }
    }

    // MARK: - Precipitation notifications

    func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private func checkPrecipChange() {
        guard precipNotifications, let c = forecast?.current else {
            lastHasPrecip = nil
            return
        }
        let nowHasPrecip = isPrecipitation(code: c.condition.code)
        if let prev = lastHasPrecip {
            if !prev && nowHasPrecip {
                sendNotification(title: "Precipitation started", body: c.condition.text)
            } else if prev && !nowHasPrecip {
                sendNotification(title: "Precipitation stopped", body: c.condition.text)
            }
        }
        lastHasPrecip = nowHasPrecip
    }

    private func isPrecipitation(code: Int) -> Bool {
        switch code {
        case 200...299, 300...399, 500...599, 600...699:
            return true
        default:
            return false
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Formatted values

    var displayTemp: String {
        guard let c = forecast?.current else { return "—°" }
        return formatTemp(useCelsius ? c.tempC : c.tempF)
    }

    var displayFeelsLike: String {
        guard let c = forecast?.current else { return "—°" }
        return formatTemp(useCelsius ? c.feelslikeC : c.feelslikeF)
    }

    var displayWind: String {
        guard let c = forecast?.current else { return "—" }
        return useKmhWind
            ? "\(Int(c.windKph.rounded())) km/h"
            : "\(Int((c.windKph / 3.6).rounded())) m/s"
    }

    var menuBarTitle: String {
        guard let c = forecast?.current else { return "—°" }
        let t = Int((useCelsius ? c.tempC : c.tempF).rounded())
        return t < 0 ? "−\(abs(t))°" : "\(t)°"
    }

    var conditionSFSymbol: String {
        guard let c = forecast?.current else { return "cloud" }
        return sfSymbol(code: c.condition.code, isDay: c.isDay == 1)
    }

    func dailyRows(dropFirst: Bool = true) -> [(label: String, dayNum: Int, slug: String, maxT: String, minT: String)] {
        guard let days = forecast?.forecast.forecastday else { return [] }
        let week = Array(days.prefix(8))
        let source = dropFirst ? Array(week.dropFirst()) : week

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEE"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")

        return source.compactMap { day in
            guard let date = dateFmt.date(from: day.date) else { return nil }
            let raw = fmt.string(from: date)
            let label = raw.prefix(1).uppercased() + raw.dropFirst()
            let dayNum = cal.component(.day, from: date)
            let slug = meteoconSlug(from: day.day.condition.icon, isDay: true)
            let maxT = formatTemp(useCelsius ? day.day.maxtempC : day.day.maxtempF)
            let minT = formatTemp(useCelsius ? day.day.mintempC : day.day.mintempF)
            return (label, dayNum, slug, maxT, minT)
        }
    }

    func hourlyRows() -> [(time: String, slug: String, temp: String)] {
        guard let forecast else { return [] }
        let days = forecast.forecast.forecastday
        let locationNow = forecast.location.localtime
        var result: [(time: String, slug: String, temp: String)] = []

        for day in days {
            for hour in day.hour {
                guard hour.time > locationNow else { continue }
                let temp = formatTemp(useCelsius ? hour.tempC : hour.tempF)
                let slug = meteoconSlug(from: hour.condition.icon, isDay: hour.isDay == 1)
                let raw = hour.time.split(separator: " ").last.map(String.init) ?? hour.time
                let timeStr = raw.hasSuffix(":00") ? String(raw.dropLast(3)) : raw
                result.append((timeStr, slug, temp))
                if result.count == 24 { return result }
            }
        }
        return result
    }

    private func fetchIPLocation() async throws -> (lat: Double, lon: Double, city: String) {
        let cacheAge = Date().timeIntervalSince1970 - ipLocDate
        let cacheValid = ipLocDate > 0 && ipLocCity != "" && cacheAge < 90 * 60

        if cacheValid {
            return (ipLocLat, ipLocLon, ipLocCity)
        }

        let url = URL(string: "https://ipapi.co/json/")!
        var request = URLRequest(url: url)
        request.setValue("Cluudo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(IPLocationResponse.self, from: data)
        guard response.error != true,
              let lat = response.latitude, let lon = response.longitude, let city = response.city else {
            throw WeatherError.apiError(response.reason ?? "Could not determine location from IP")
        }

        ipLocLat = lat
        ipLocLon = lon
        ipLocCity = city
        ipLocDate = Date().timeIntervalSince1970
        return (lat, lon, city)
    }

    // MARK: - Private helpers

    func meteoconSlug(from symbolCode: String, isDay: Bool) -> String {
        let base = symbolCode
            .replacingOccurrences(of: "_day", with: "")
            .replacingOccurrences(of: "_night", with: "")
            .replacingOccurrences(of: "_polartwilight", with: "")

        switch base {
        case "clearsky", "fair":
            return isDay ? "day" : "night"
        case "partlycloudy":
            return isDay ? "cloudy-day" : "cloudy-night"
        case "cloudy", "fog":
            return "cloudy"
        case "lightrain", "lightrainshowers",
             "rain", "rainshowers",
             "heavyrain", "heavyrainshowers",
             "lightsleet", "lightsleetshowers",
             "sleet", "sleetshowers",
             "heavysleet", "heavysleetshowers":
            return "rainy"
        case "lightsnow", "lightsnowshowers":
            return "snowy-1"
        case "snow", "snowshowers":
            return "snowy-2"
        case "heavysnow", "heavysnowshowers":
            return "snowy-3"
        case "lightrainandthunder", "rainandthunder", "heavyrainandthunder",
             "lightrainshowersandthunder", "rainshowersandthunder", "heavyrainshowersandthunder",
             "lightsleetandthunder", "sleetandthunder", "heavysleetandthunder",
             "lightsleetshowersandthunder", "sleetshowersandthunder", "heavysleetshowersandthunder",
             "lightsnowandthunder", "snowandthunder", "heavysnowandthunder",
             "lightsnowshowersandthunder", "snowshowersandthunder", "heavysnowshowersandthunder":
            return "thunder"
        default:
            return isDay ? "day" : "night"
        }
    }

    private func formatTemp(_ v: Double) -> String {
        let i = Int(v.rounded())
        if i < 0 { return "−\(abs(i))°" }
        return "\(i)°"
    }

    func sfSymbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 200...299: return "cloud.bolt.rain.fill"
        case 300...399: return "cloud.drizzle.fill"
        case 500...504: return "cloud.rain.fill"
        case 511: return "cloud.sleet.fill"
        case 520...599: return "cloud.heavyrain.fill"
        case 600...699: return "cloud.snow.fill"
        case 701, 741: return "cloud.fog.fill"
        case 711, 721, 731, 751, 761, 762: return "smoke.fill"
        case 771, 781: return "cloud.fill"
        case 800: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 801: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 802...804: return "cloud.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - IP geolocation

private struct IPLocationResponse: Decodable {
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let error: Bool?
    let reason: String?
}
