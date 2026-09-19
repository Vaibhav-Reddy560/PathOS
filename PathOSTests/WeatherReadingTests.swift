import Foundation
import Testing
@testable import PathOS

/// Built from what the forecasts and HAL Airport said about south Bengaluru at 9 PM on
/// 19 September 2026, when PathOS said 89% and "raining nearby right now" and it stayed dry.
struct WeatherReadingTests {
    private let now = Date(timeIntervalSince1970: 1_789_833_600) // 19 Sep 2026, 21:30 IST

    /// The current hour and the two after it, per model, as Open-Meteo returned them.
    private let evening: [WeatherReading.ModelHours] = [
        .init(name: "ecmwf_ifs025", probability: [89, 87, 82], precipitation: [1.6, 1.6, 0.6], temperature: [21.6, 21.4, 21.2], weatherCode: [55, 51, 53]),
        .init(name: "gfs_seamless", probability: [44, 71, 60], precipitation: [0.3, 0.2, 0.0], temperature: [23.0, 22.7, 22.4], weatherCode: [51, 51, 3]),
        .init(name: "icon_seamless", probability: [48, 53, 40], precipitation: [0.0, 0.0, 0.0], temperature: [22.4, 22.1, 21.9], weatherCode: [3, 3, 3]),
    ]

    private func hal(_ weather: String?, minutesAgo: Double = 30, km: Double = 8) -> WeatherObservation {
        WeatherObservation(station: "Hal Airport", distanceMeters: km * 1_000, observedAt: now.addingTimeInterval(-minutesAgo * 60),
                           temperatureC: 26, presentWeather: weather, cloudCover: "BKN")
    }

    @Test func theChanceIsTheMiddleModelNotTheWorst() {
        #expect(WeatherReading.chanceOfRain(evening) == 71)
        #expect(WeatherReading.expectedRain(evening) == 0.3)
        #expect(WeatherReading.modelsExpectingRain(evening) == 2)
    }

    @Test func aStationReportDecidesWhatsHappeningNow() {
        let dry = WeatherReading.snapshot(models: evening, observation: hal(nil), now: now, latitude: 12.918, longitude: 77.6)
        #expect(!dry.isRainingNearby)
        #expect(dry.summary == "Cloudy")
        // The station read 26°C; ECMWF said 21.6.
        #expect(dry.temperatureC == 26)

        let wet = WeatherReading.snapshot(models: evening, observation: hal("-TSRA"), now: now, latitude: 12.918, longitude: 77.6)
        #expect(wet.isRainingNearby)
        #expect(wet.weatherCode == 95)
    }

    @Test func oldOrDistantReportsAreIgnored() {
        #expect(WeatherReading.usable(hal("RA", minutesAgo: 120), now: now) == nil)
        #expect(WeatherReading.usable(hal("RA", km: 35), now: now) == nil)
        #expect(WeatherReading.usable(hal("RA"), now: now) != nil)
    }

    /// Without a station, the forecast only says rain where the models agree it's raining this hour.
    @Test func withoutAStationTheForecastDoesntClaimRainNow() {
        let snapshot = WeatherReading.snapshot(models: evening, observation: nil, now: now, latitude: 12.918, longitude: 77.6)
        // The middle model has 0.3 mm this hour, so ECMWF's drizzle stands.
        #expect(snapshot.weatherCode == 55)
        #expect(!snapshot.isRainingNearby)

        var drier = evening
        drier[0].precipitation[0] = 0.1
        drier[1].precipitation[0] = 0.0
        #expect(WeatherReading.snapshot(models: drier, observation: nil, now: now, latitude: 0, longitude: 0).summary == "Cloudy")
    }

    @Test(arguments: [
        ("-TSRA", true), ("RA", true), ("+SHRA", true), ("DZ", true), ("-RA BR", true),
        ("TS", false), ("VCSH", false), ("BR", false), ("HZ", false),
    ])
    func presentWeatherMeansRainOnlyWhenItIs(_ weather: String, _ isRain: Bool) {
        #expect(WeatherReading.isRain(weather) == isRain)
    }

    @Test func reportsBecomeWeatherCodes() {
        func code(_ weather: String?, _ cover: String? = nil) -> Int {
            WeatherReading.weatherCode(for: WeatherObservation(station: "", distanceMeters: 0, observedAt: now, presentWeather: weather, cloudCover: cover))
        }
        #expect(code("-RA") == 61)
        #expect(code("+RA") == 65)
        #expect(code("SHRA") == 80)
        #expect(code("DZ") == 51)
        #expect(code("BR") == 45)
        #expect(code(nil, "SCT") == 2)
        #expect(code(nil, "OVC") == 3)
        #expect(code(nil, "CLR") == 0)
    }

    @Test func stationNamesReadNaturally() {
        #expect(WeatherReading.stationName("Bangaluru/Hal Arpt, KA, IN") == "Hal Airport")
        #expect(WeatherReading.stationName("Bengaluru Intl Arpt, KA, IN") == "Bengaluru International Airport")
    }
}
