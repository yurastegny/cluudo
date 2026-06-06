import Foundation

struct ForecastResponse: Codable {
    let location: WeatherLocation
    let current: Current
    let forecast: Forecast
}

struct WeatherLocation: Codable {
    let name: String
    let region: String
    let country: String
    let localtime: String
}

struct SearchLocation: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let region: String
    let country: String
    let lat: Double
    let lon: Double

    init(name: String, region: String, country: String, lat: Double, lon: Double) {
        self.name = name
        self.region = region
        self.country = country
        self.lat = lat
        self.lon = lon
        self.id = "\(lat),\(lon),\(name),\(region),\(country)"
    }

    var displayName: String {
        [name, region, country]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var queryValue: String {
        "\(lat),\(lon)"
    }
}

struct Current: Codable {
    let tempC: Double
    let tempF: Double
    let isDay: Int
    let condition: Condition
    let windMph: Double
    let windKph: Double
    let humidity: Int
    let feelslikeC: Double
    let feelslikeF: Double
    let visKm: Double
    let uv: Double
    let pressureMb: Double
    let lastUpdated: String

    enum CodingKeys: String, CodingKey {
        case tempC = "temp_c"
        case tempF = "temp_f"
        case isDay = "is_day"
        case condition
        case windMph = "wind_mph"
        case windKph = "wind_kph"
        case humidity
        case feelslikeC = "feelslike_c"
        case feelslikeF = "feelslike_f"
        case visKm = "vis_km"
        case uv
        case pressureMb = "pressure_mb"
        case lastUpdated = "last_updated"
    }
}

struct Condition: Codable {
    let text: String
    let icon: String
    let code: Int
}

struct Forecast: Codable {
    let forecastday: [ForecastDay]
}

struct ForecastDay: Codable {
    let date: String
    let day: ForecastDayData
    let hour: [ForecastHour]
}

struct ForecastHour: Codable {
    let time: String
    let tempC: Double
    let tempF: Double
    let isDay: Int
    let condition: Condition

    enum CodingKeys: String, CodingKey {
        case time
        case tempC = "temp_c"
        case tempF = "temp_f"
        case isDay = "is_day"
        case condition
    }
}

struct ForecastDayData: Codable {
    let maxtempC: Double
    let mintempC: Double
    let maxtempF: Double
    let mintempF: Double
    let condition: Condition

    enum CodingKeys: String, CodingKey {
        case maxtempC = "maxtemp_c"
        case mintempC = "mintemp_c"
        case maxtempF = "maxtemp_f"
        case mintempF = "mintemp_f"
        case condition
    }
}
