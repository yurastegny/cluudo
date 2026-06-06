import Foundation

enum WeatherError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:       return "Invalid URL"
        case .invalidResponse:  return "Invalid server response"
        case .httpError(403):   return "MET Norway rejected the request"
        case .httpError(let c): return "Server error (\(c))"
        case .apiError(let m):  return m
        }
    }
}

struct APIErrorResponse: Decodable {
    let message: String?
    let reason: String?
}

actor WeatherService {
    static let shared = WeatherService()

    private let userAgent = "Cluudo/1.0 contact: yura@yura.me"

    func searchLocations(query: String) async throws -> [SearchLocation] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "geocoding-api.open-meteo.com"
        components.path = "/v1/search"
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmedQuery),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]

        let response: OpenMeteoGeocodingResponse = try await fetchJSON(components)
        return (response.results ?? []).map {
            SearchLocation(
                name: $0.name,
                region: $0.admin1 ?? "",
                country: $0.country ?? "",
                lat: $0.latitude,
                lon: $0.longitude
            )
        }
    }

    func fetch(location: String, displayNameOverride: String? = nil) async throws -> ForecastResponse {
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocation.isEmpty, trimmedLocation != "auto:ip" else {
            throw WeatherError.apiError("Enter a city or coordinates")
        }

        let resolvedLocation = try await resolveLocation(location: trimmedLocation)
        let metForecast = try await fetchMETForecast(location: resolvedLocation)
        return makeForecastResponse(from: metForecast, location: resolvedLocation, displayNameOverride: displayNameOverride)
    }

    private func resolveLocation(location: String) async throws -> ResolvedLocation {
        if let coords = parseCoordinates(location) {
            return ResolvedLocation(
                name: "\(formattedCoordinate(coords.lat)),\(formattedCoordinate(coords.lon))",
                region: "",
                country: "",
                lat: coords.lat,
                lon: coords.lon
            )
        }

        let results = try await searchLocations(query: location)
        guard let first = results.first else {
            throw WeatherError.apiError("Location not found")
        }
        return ResolvedLocation(name: first.name, region: first.region, country: first.country, lat: first.lat, lon: first.lon)
    }

    private func reverseGeocode(lat: Double, lon: Double) async throws -> ResolvedLocation? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "nominatim.openstreetmap.org"
        components.path = "/reverse"
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: formattedCoordinate(lat)),
            URLQueryItem(name: "lon", value: formattedCoordinate(lon)),
            URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "addressdetails", value: "1"),
        ]

        let response: NominatimReverseResponse = try await fetchJSON(components)
        guard let address = response.address else { return nil }
        let name = address.populatedPlace ?? response.name ?? response.displayName?.split(separator: ",").first.map(String.init)
        guard let name, !name.isEmpty else { return nil }
        return ResolvedLocation(
            name: name,
            region: address.region,
            country: address.country ?? "",
            lat: lat,
            lon: lon
        )
    }

    private func fetchMETForecast(location: ResolvedLocation) async throws -> METForecastResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.met.no"
        components.path = "/weatherapi/locationforecast/2.0/compact"
        components.queryItems = [
            URLQueryItem(name: "lat", value: formattedCoordinate(location.lat)),
            URLQueryItem(name: "lon", value: formattedCoordinate(location.lon)),
        ]
        return try await fetchJSON(components)
    }

    private func fetchJSON<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url else { throw WeatherError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherError.invalidResponse }
        guard http.statusCode == 200 else {
            if let body = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               let message = body.message ?? body.reason {
                throw WeatherError.apiError(message)
            }
            throw WeatherError.httpError(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func makeForecastResponse(
        from response: METForecastResponse,
        location resolvedLocation: ResolvedLocation,
        displayNameOverride: String?
    ) -> ForecastResponse {
        let sortedSeries = response.properties.timeseries.sorted { $0.time < $1.time }
        let now = Date()
        let currentSeries = sortedSeries.first { $0.time >= now } ?? sortedSeries.first
        let currentDetails = currentSeries?.data.instant.details
        let currentSymbol = bestSummary(from: currentSeries)?.symbolCode
        let currentCode = conditionCode(from: currentSymbol)
        let currentTemp = currentDetails?.airTemperature ?? 0

        let location = WeatherLocation(
            name: displayNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? resolvedLocation.name,
            region: resolvedLocation.region,
            country: resolvedLocation.country,
            localtime: localDateTimeString(from: currentSeries?.time ?? now)
        )

        let current = Current(
            tempC: currentTemp,
            tempF: celsiusToFahrenheit(currentTemp),
            isDay: isDay(symbolCode: currentSymbol) ? 1 : 0,
            condition: Condition(
                text: conditionText(from: currentSymbol),
                icon: currentSymbol ?? "",
                code: currentCode
            ),
            windMph: (currentDetails?.windSpeed ?? 0) * 2.236936,
            windKph: (currentDetails?.windSpeed ?? 0) * 3.6,
            humidity: Int((currentDetails?.relativeHumidity ?? 0).rounded()),
            feelslikeC: currentTemp,
            feelslikeF: celsiusToFahrenheit(currentTemp),
            visKm: 0,
            uv: currentDetails?.ultravioletIndexClearSky ?? 0,
            pressureMb: currentDetails?.airPressureAtSeaLevel ?? 0,
            lastUpdated: localDateTimeString(from: currentSeries?.time ?? now)
        )

        let hours = sortedSeries.map { series in
            let temp = series.data.instant.details.airTemperature ?? 0
            let symbol = bestSummary(from: series)?.symbolCode
            return ForecastHour(
                time: localDateTimeString(from: series.time),
                tempC: temp,
                tempF: celsiusToFahrenheit(temp),
                isDay: isDay(symbolCode: symbol) ? 1 : 0,
                condition: Condition(
                    text: conditionText(from: symbol),
                    icon: symbol ?? "",
                    code: conditionCode(from: symbol)
                )
            )
        }

        let days = makeForecastDays(from: sortedSeries)
        return ForecastResponse(location: location, current: current, forecast: Forecast(forecastday: days.map { day in
            let dayHours = hours.filter { $0.time.hasPrefix(day.date) }
            return ForecastDay(date: day.date, day: day.day, hour: dayHours)
        }))
    }

    private func makeForecastDays(from series: [METTimeseries]) -> [(date: String, day: ForecastDayData)] {
        let grouped = Dictionary(grouping: series) { localDateString(from: $0.time) }

        return grouped.keys.sorted().compactMap { date in
            guard let items = grouped[date], !items.isEmpty else { return nil }
            let temps = items.compactMap(\.data.instant.details.airTemperature)
            let representative = items.min { lhs, rhs in
                abs(localHour(from: lhs.time) - 12) < abs(localHour(from: rhs.time) - 12)
            } ?? items[0]
            let symbol = bestSummary(from: representative)?.symbolCode
            let maxTemp = temps.max() ?? 0
            let minTemp = temps.min() ?? 0
            return (
                date,
                ForecastDayData(
                    maxtempC: maxTemp,
                    mintempC: minTemp,
                    maxtempF: celsiusToFahrenheit(maxTemp),
                    mintempF: celsiusToFahrenheit(minTemp),
                    condition: Condition(
                        text: conditionText(from: symbol),
                        icon: symbol ?? "",
                        code: conditionCode(from: symbol)
                    )
                )
            )
        }
    }

    private func bestSummary(from series: METTimeseries?) -> METSummary? {
        series?.data.next1Hours?.summary
            ?? series?.data.next6Hours?.summary
            ?? series?.data.next12Hours?.summary
    }

    private func conditionCode(from symbolCode: String?) -> Int {
        let symbol = symbolCode ?? ""
        if symbol.contains("thunder") { return 200 }
        if symbol.contains("snow") { return 600 }
        if symbol.contains("sleet") { return 611 }
        if symbol.contains("rain") { return symbol.contains("light") ? 500 : 501 }
        if symbol.contains("fog") { return 741 }
        if symbol.contains("cloudy") { return symbol == "cloudy" ? 804 : 801 }
        if symbol.contains("clearsky") { return 800 }
        return 801
    }

    private func conditionText(from symbolCode: String?) -> String {
        guard let symbolCode else { return "Weather" }
        return symbolCode
            .replacingOccurrences(of: "_day", with: "")
            .replacingOccurrences(of: "_night", with: "")
            .replacingOccurrences(of: "_polartwilight", with: "")
            .replacingOccurrences(of: "and", with: " and ")
            .replacingOccurrences(of: "partlycloudy", with: "partly cloudy")
            .replacingOccurrences(of: "clearsky", with: "clear sky")
            .replacingOccurrences(of: "fair", with: "fair")
            .capitalized
    }

    private func isDay(symbolCode: String?) -> Bool {
        guard let symbolCode else { return true }
        return !symbolCode.contains("_night")
    }

    private func parseCoordinates(_ value: String) -> (lat: Double, lon: Double)? {
        let parts = value.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1])
        else { return nil }
        return (lat, lon)
    }

    private func formattedCoordinate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func celsiusToFahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    private func localDateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func localDateString(from date: Date) -> String {
        String(localDateTimeString(from: date).prefix(10))
    }

    private func localHour(from date: Date) -> Int {
        let value = localDateTimeString(from: date)
        let hour = value.dropFirst(11).prefix(2)
        return Int(hour) ?? 0
    }
}

private struct ResolvedLocation {
    let name: String
    let region: String
    let country: String
    let lat: Double
    let lon: Double
}

private struct OpenMeteoGeocodingResponse: Decodable {
    let results: [OpenMeteoGeocodingResult]?
}

private struct OpenMeteoGeocodingResult: Decodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
}

private struct NominatimReverseResponse: Decodable {
    let name: String?
    let displayName: String?
    let address: NominatimAddress?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case address
    }
}

private struct NominatimAddress: Decodable {
    let city: String?
    let town: String?
    let village: String?
    let hamlet: String?
    let municipality: String?
    let locality: String?
    let suburb: String?
    let county: String?
    let state: String?
    let country: String?

    var populatedPlace: String? {
        city ?? town ?? village ?? hamlet ?? municipality ?? locality ?? suburb ?? county
    }

    var region: String {
        [state, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct METForecastResponse: Decodable {
    let properties: METProperties
}

private struct METProperties: Decodable {
    let timeseries: [METTimeseries]
}

private struct METTimeseries: Decodable {
    let time: Date
    let data: METData
}

private struct METData: Decodable {
    let instant: METInstant
    let next1Hours: METPeriod?
    let next6Hours: METPeriod?
    let next12Hours: METPeriod?

    enum CodingKeys: String, CodingKey {
        case instant
        case next1Hours = "next_1_hours"
        case next6Hours = "next_6_hours"
        case next12Hours = "next_12_hours"
    }
}

private struct METInstant: Decodable {
    let details: METDetails
}

private struct METPeriod: Decodable {
    let summary: METSummary?
}

private struct METSummary: Decodable {
    let symbolCode: String?

    enum CodingKeys: String, CodingKey {
        case symbolCode = "symbol_code"
    }
}

private struct METDetails: Decodable {
    let airTemperature: Double?
    let windSpeed: Double?
    let relativeHumidity: Double?
    let airPressureAtSeaLevel: Double?
    let ultravioletIndexClearSky: Double?

    enum CodingKeys: String, CodingKey {
        case airTemperature = "air_temperature"
        case windSpeed = "wind_speed"
        case relativeHumidity = "relative_humidity"
        case airPressureAtSeaLevel = "air_pressure_at_sea_level"
        case ultravioletIndexClearSky = "ultraviolet_index_clear_sky"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
