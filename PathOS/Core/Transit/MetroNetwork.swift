import Foundation

/// A metro line and its stations, in order from one terminus to the other.
nonisolated struct MetroLine: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var stations: [String]

    var termini: String { "\(stations.first ?? "") ↔ \(stations.last ?? "")" }
}

/// Namma Metro's operating network.
///
/// Station names and order are from Wikipedia (Purple, Green and Yellow Line articles,
/// read 17 September 2026), which is CC BY-SA — see Settings → About the data.
/// BMRCL publishes no real-time feed, so PathOS never claims to know where a train is:
/// it tracks *you* by GPS and estimates the rest from the station order.
nonisolated enum MetroNetwork {
    static let purple = MetroLine(id: "purple", name: "Purple Line", stations: [
        "Whitefield (Kadugodi)", "Hopefarm Channasandra", "Kadugodi Tree Park", "Pattandur Agrahara",
        "Sri Sathya Sai Hospital", "Nallurhalli", "Kundalahalli", "Seetharampalya", "Hoodi",
        "Garudacharpalya", "Singayyanapalya", "Krishnarajapura (K.R.Pura)", "Benniganahalli",
        "Baiyappanahalli", "Swami Vivekananda Road", "Indiranagar", "Halasuru", "Trinity",
        "Mahatma Gandhi Road", "Cubbon Park", "Dr. B.R. Ambedkar Station, Vidhana Soudha",
        "Sir M. Visvesvaraya Station, Central College", "Nadaprabhu Kempegowda Station, Majestic",
        "Krantivira Sangolli Rayanna Railway Station", "Magadi Road",
        "Sri Balagangadharanatha Swamiji Station, Hosahalli", "Vijayanagara", "Attiguppe",
        "Deepanjali Nagar", "Mysuru Road", "Pantharapalya - Nayandahalli", "Rajarajeshwari Nagar",
        "Jnanabharathi", "Pattanagere", "Kengeri Bus Terminal", "Kengeri", "Challaghatta",
    ])

    static let green = MetroLine(id: "green", name: "Green Line", stations: [
        "Madavara", "Chikkabidarakallu", "Manjunath Nagar", "Nagasandra", "Dasarahalli", "Jalahalli",
        "Peenya Industry", "Peenya", "Goraguntepalya", "Yeshwanthpur", "Sandal Soap Factory",
        "Mahalakshmi", "Rajajinagar", "Mahakavi Kuvempu Road", "Srirampura", "Mantri Square Sampige Road",
        "Nadaprabhu Kempegowda Station, Majestic", "Chickpete", "Krishna Rajendra Market",
        "National College", "Lalbagh", "South End Circle", "Jayanagar", "Rashtreeya Vidyalaya Road",
        "Banashankari", "Jaya Prakash Nagar", "Yelachenahalli", "Konanakunte Cross", "Doddakallasandra",
        "Vajarahalli", "Thalaghattapura", "Silk Institute",
    ])

    static let yellow = MetroLine(id: "yellow", name: "Yellow Line", stations: [
        "Rashtreeya Vidyalaya Road", "Ragigudda", "Jayadeva Hospital", "BTM Layout", "Central Silk Board",
        "Bommanahalli", "Hongasandra", "Kudlu Gate", "Singasandra", "Hosa Road", "Beratena Agrahara",
        "Electronic City", "Infosys Foundation Konappana Agrahara", "Huskur Road", "Biocon Hebbagodi",
        "Delta Electronics Bommasandra",
    ])

    static let lines = [purple, green, yellow]

    static func line(id: String) -> MetroLine? {
        lines.first { $0.id == id }
    }

    /// Stations served by more than one line, for change-here hints.
    static func interchangeLines(for station: String) -> [MetroLine] {
        lines.filter { $0.stations.contains(station) }
    }

    /// Every station name once, for search.
    static var allStations: [String] {
        Array(Set(lines.flatMap(\.stations))).sorted()
    }
}
