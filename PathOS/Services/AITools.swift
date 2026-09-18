import Foundation
import FoundationModels

nonisolated struct SearchPlacesTool: Tool {
    let name = "searchPlaces"
    let description = """
        Finds real places near the user with Apple Maps: cafés, restaurants, bars, parks, \
        metro stations, cinemas and more. Returns names, categories and walking minutes.
        """

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "What to look for, e.g. 'cafe', 'south indian restaurant', 'metro station'")
        var query: String

        @Guide(description: "Maximum walking time in minutes", .range(1...60))
        var maxWalkMinutes: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let places = await AppState.shared.searchPlacesForAssistant(
            query: arguments.query,
            maxWalkMinutes: arguments.maxWalkMinutes
        )
        guard !places.isEmpty else {
            return "No matching places found within \(arguments.maxWalkMinutes) minutes' walk."
        }
        return places.prefix(6)
            .map { "\($0.name) (\($0.categoryName)), about \($0.walkMinutes) min walk" }
            .joined(separator: "\n")
    }
}

nonisolated struct NearbyNotesTool: Tool {
    let name = "savedNotes"
    let description = """
        Looks up the user's saved spatial notes, such as where they parked or a locker code. \
        Optionally filter by a keyword.
        """

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Optional keyword like 'parking' or 'locker'; empty for all nearby notes")
        var keyword: String
    }

    func call(arguments: Arguments) async throws -> String {
        let notes = await AppState.shared.notesForAssistant(keyword: arguments.keyword)
        return notes.isEmpty ? "No saved notes match." : notes.joined(separator: "\n")
    }
}

nonisolated struct WeatherTool: Tool {
    let name = "currentWeather"
    let description = "Gets current weather, rain chance for the next 2 hours, and the barometer trend at the user's location."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always 'now'")
        var when: String
    }

    func call(arguments: Arguments) async throws -> String {
        await AppState.shared.weatherForAssistant()
    }
}
