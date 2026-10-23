import Foundation

/// Mail from the services you use to get about, go out and get things delivered, read for what
/// it records: a ride and its fare, a ticket and its show, an order and where it's got to.
///
/// Recognised by who sent it, never by guessing from the words: a newsletter that mentions Uber
/// is not an Uber receipt. The rules here read what these mails say the same way every time — an
/// amount, a booking id, "out for delivery"; the on-device model reads the rest (`AIClient`).
nonisolated enum ServiceMail {
    nonisolated enum Kind: String, Codable, Sendable {
        case ride
        case ticket
        case order
    }

    nonisolated enum Service: String, Codable, CaseIterable, Sendable {
        case uber
        case ola
        case rapido
        case nammaYatri
        case bookMyShow
        case amazon
        case swiggy
        case zomato

        var name: String {
            switch self {
            case .uber: "Uber"
            case .ola: "Ola"
            case .rapido: "Rapido"
            case .nammaYatri: "Namma Yatri"
            case .bookMyShow: "BookMyShow"
            case .amazon: "Amazon"
            case .swiggy: "Swiggy"
            case .zomato: "Zomato"
            }
        }

        var kind: Kind {
            switch self {
            case .uber, .ola, .rapido, .nammaYatri: .ride
            case .bookMyShow: .ticket
            case .amazon, .swiggy, .zomato: .order
            }
        }

        var symbol: String {
            switch self {
            case .uber, .ola: "car.fill"
            case .rapido: "scooter"
            case .nammaYatri: "car.rear.fill"
            case .bookMyShow: "ticket.fill"
            case .amazon: "shippingbox.fill"
            case .swiggy, .zomato: "takeoutbag.and.cup.and.straw.fill"
            }
        }

        /// The domains their mail comes from.
        var domains: [String] {
            switch self {
            case .uber: ["uber.com"]
            case .ola: ["olacabs.com", "olamoney.com"]
            case .rapido: ["rapido.bike"]
            case .nammaYatri: ["nammayatri.in"]
            case .bookMyShow: ["bookmyshow.com"]
            case .amazon: ["amazon.in", "amazon.com"]
            case .swiggy: ["swiggy.in", "swiggy.com"]
            case .zomato: ["zomato.com"]
            }
        }
    }

    /// Who sent it, by the address's domain or a subdomain of it.
    static func service(of senderAddress: String) -> Service? {
        guard let domain = senderAddress.lowercased().split(separator: "@").last.map(String.init) else { return nil }
        return Service.allCases.first { service in
            service.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
    }

    /// The Gmail search for these services' mail. Their receipts often land in Promotions, which
    /// the everyday search leaves out, so they're asked for by sender as well.
    static func searchQuery(since: Date?, now: Date = Date()) -> String {
        let window = since.map { "after:\(Int(min($0.addingTimeInterval(-5 * 60), now).timeIntervalSince1970))" } ?? "newer_than:3d"
        // Braces are Gmail's "any of these".
        let senders = Service.allCases.flatMap(\.domains).map { "from:\($0)" }.joined(separator: " ")
        return "\(window) {\(senders)} -in:spam -in:trash"
    }

    // MARK: Rides

    nonisolated struct Ride: Equatable, Sendable {
        var service: Service
        /// What you paid, in rupees.
        var fare: Double?
        var distanceKm: Double?
        var minutes: Int?
        var pickup: String?
        var drop: String?
        var vehicle: DoorToDoor.Mode?
        /// When it picked you up and dropped you, where the receipt prints the times.
        var startedAt: Date? = nil
        var endedAt: Date? = nil
    }

    /// What a ride receipt records. Nil when it isn't a receipt — a promotion, a rating request.
    /// `received` dates the receipt's clock times: a ride ends a little before its receipt comes.
    static func ride(_ service: Service, subject: String, body: String, received: Date? = nil,
                     calendar: Calendar = .current) -> Ride? {
        let text = subject + "\n" + body
        let lower = text.lowercased()
        let isReceipt = ["receipt", "trip with", "ride with", "your trip", "your ride", "invoice", "total fare",
                         "trip fare", "ride fare", "thanks for riding", "thanks for travelling"]
            .contains(where: lower.contains)
        guard isReceipt, let fare = total(in: text) else { return nil }
        let stops = timedStops(in: body, received: received, calendar: calendar)
        return Ride(service: service, fare: fare, distanceKm: distanceKm(in: text), minutes: minutes(in: text),
                    pickup: stops.first?.address ?? labelled(["pickup", "pick-up", "picked up from", "from"], in: body),
                    drop: (stops.count > 1 ? stops.last?.address : nil) ?? labelled(["drop", "dropoff", "drop-off", "dropped at", "to"], in: body),
                    vehicle: vehicle(service, in: lower),
                    startedAt: stops.first?.at, endedAt: stops.count > 1 ? stops.last?.at : nil)
    }

    /// Uber's receipt has no "Pickup:": a time, and the address under it, for each end —
    /// "11:29 am / 136, 3rd Cross Rd, … BTM Layout, Bengaluru …", then "11:57 am / Bull Temple Rd,
    /// Basavanagudi, …". Dated by the receipt: a time later than it came is the day before's.
    static func timedStops(in body: String, received: Date?, calendar: Calendar = .current) -> [(at: Date?, address: String)] {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var stops: [(at: Date?, address: String)] = []
        for (index, line) in lines.enumerated() {
            guard let time = line.wholeMatch(of: #/(?i)(\d{1,2}):(\d{2})\s*([ap])\.?\s*m\.?/#),
                  let address = lines[safe: index + 1], address.count >= 8, address.contains(","),
                  address.wholeMatch(of: #/(?i)\d{1,2}:\d{2}.*/#) == nil else { continue }
            var at: Date?
            if let received, var hour = Int(time.1), let minute = Int(time.2) {
                if time.3.lowercased() == "p", hour < 12 { hour += 12 }
                if time.3.lowercased() == "a", hour == 12 { hour = 0 }
                at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: received)
                if let dated = at, dated > received.addingTimeInterval(3_600) {
                    at = calendar.date(byAdding: .day, value: -1, to: dated)
                }
            }
            stops.append((at, String(address.prefix(160))))
        }
        return stops
    }

    /// An address as a place you'd say you went: the area it's in — "136, 3rd Cross Rd, Dollar
    /// Layout, Stage 2, BTM Layout, Bengaluru, Karnataka 560076, India" is BTM Layout.
    static func area(of address: String) -> String {
        let parts = address.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                let lower = part.lowercased()
                return !part.isEmpty && lower != "india" && !lower.hasPrefix("karnataka")
                    && !["bengaluru", "bangalore", "bengaluru urban", "bangalore urban"].contains(lower)
                    && !part.allSatisfy { $0.isNumber || $0 == " " }
            }
        return parts.last ?? address
    }

    /// The amount a receipt says was paid: on the line that says "total", or failing that the
    /// largest amount in it — a receipt's other figures are the parts of its total.
    static func total(in text: String) -> Double? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard ["total", "amount paid", "you paid", "paid by", "trip fare", "fare"].contains(where: lower.contains),
                  !lower.contains("subtotal") else { continue }
            // The amount is on the line, or alone on the next.
            if let amount = amounts(in: line).last ?? lines[safe: index + 1].flatMap({ amounts(in: $0).first }) {
                return amount
            }
        }
        return amounts(in: text).max()
    }

    /// Every rupee amount: "₹123.45", "Rs. 1,234", "INR 99".
    static func amounts(in text: String) -> [Double] {
        text.matches(of: /(?i)(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/).compactMap {
            Double($0.1.replacingOccurrences(of: ",", with: ""))
        }.filter { $0 > 0 && $0 < 100_000 }
    }

    static func distanceKm(in text: String) -> Double? {
        text.firstMatch(of: /(?i)([0-9]+(?:\.[0-9]+)?)\s*(?:km|kms|kilomet(?:er|re)s?)\b/).flatMap { Double($0.1) }
    }

    static func minutes(in text: String) -> Int? {
        text.firstMatch(of: /(?i)([0-9]{1,3})\s*(?:min|mins|minutes)\b/).flatMap { Int($0.1) }
    }

    /// The text after a label, on its line or the next: "Pickup: 12th Main, Indiranagar".
    static func labelled(_ labels: [String], in body: String) -> String? {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            // The label as a word: "To" isn't the start of "Total".
            guard let label = labels.first(where: { label in
                lower.hasPrefix(label) && !(lower.dropFirst(label.count).first?.isLetter ?? false)
            }) else { continue }
            let rest = line.dropFirst(label.count).trimmingCharacters(in: CharacterSet(charactersIn: " :-–\t"))
            let value = rest.isEmpty ? lines[safe: index + 1] ?? "" : rest
            // An address has letters and is more than a word; "To: you@gmail.com" isn't one.
            if value.count >= 6, value.contains(where: \.isLetter), !value.contains("@") {
                return String(value.prefix(120))
            }
        }
        return nil
    }

    private static func vehicle(_ service: Service, in lower: String) -> DoorToDoor.Mode? {
        if ["bike", "moto"].contains(where: lower.contains) { return .bikeTaxi }
        if lower.contains("auto") { return .auto }
        if ["uber go", "premier", "sedan", "mini", "prime", "suv", "cab", "car"].contains(where: lower.contains) { return .cab }
        return service == .rapido ? .bikeTaxi : nil
    }

    // MARK: Tickets

    nonisolated struct Ticket: Equatable, Sendable {
        var bookingID: String
        var seats: String?
        var showtime: Date?
    }

    /// A confirmed booking: its id, its seats and when the show is. What's showing and where is
    /// left to the model, which reads names better than rules do.
    static func ticket(subject: String, body: String, received: Date, calendar: Calendar = .current) -> Ticket? {
        let text = subject + "\n" + body
        let lower = text.lowercased()
        guard ["confirmed", "booking id", "your ticket", "tickets for"].contains(where: lower.contains),
              !lower.contains("cancelled"),
              let id = text.firstMatch(of: /(?i)booking\s*(?:id|no\.?|number)\s*[:#]?\s*([A-Z0-9]{5,})/)?.1 else { return nil }
        let seats = text.firstMatch(of: /(?i)seats?(?:\s*\(s\))?\s*[:\-]\s*([^\n]{1,60})/).map {
            String($0.1).trimmingCharacters(in: .whitespaces)
        }
        return Ticket(bookingID: String(id), seats: seats, showtime: showtime(in: text, received: received, calendar: calendar))
    }

    /// "Sat, 25 Oct, 2026 | 07:30 PM", "25 Oct 2026 07:30 PM", "Saturday, October 25 at 7:30 PM".
    static func showtime(in text: String, received: Date, calendar: Calendar = .current) -> Date? {
        let year = calendar.component(.year, from: received)
        func at(_ day: Int?, _ month: Int?, _ givenYear: Int?, _ hour: Int?, _ minute: Int?, _ meridiem: Substring?) -> Date? {
            guard let day, let month, var hour, let minute else { return nil }
            if let meridiem = meridiem?.lowercased() {
                if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
                if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
            }
            var parts = DateComponents(year: givenYear ?? year, month: month, day: day, hour: hour, minute: minute)
            guard var date = calendar.date(from: parts) else { return nil }
            // A show is after the booking: a date without a year that's already gone is next year's.
            if givenYear == nil, date < received.addingTimeInterval(-86_400) {
                parts.year = year + 1
                date = calendar.date(from: parts) ?? date
            }
            return date
        }
        // Every candidate in turn: "Chapter 1 (U/A)" looks like the start of a date until its month doesn't.
        for match in text.matches(of: /(?i)\b(\d{1,2})(?:st|nd|rd|th)?[ \t]+([a-z]{3,9}),?[ \t]*(\d{4})?[^0-9\n]{0,12}(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?/) {
            if let month = month(match.2),
               let date = at(Int(match.1), month, match.3.flatMap { Int($0) }, Int(match.4), Int(match.5), match.6) {
                return date
            }
        }
        for match in text.matches(of: /(?i)\b([a-z]{3,9})[ \t]+(\d{1,2})(?:st|nd|rd|th)?,?[ \t]*(\d{4})?[^0-9\n]{0,12}(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?/) {
            if let month = month(match.1),
               let date = at(Int(match.2), month, match.3.flatMap { Int($0) }, Int(match.4), Int(match.5), match.6) {
                return date
            }
        }
        return nil
    }

    private static func month(_ word: Substring) -> Int? {
        HolidayListReader.month(String(word))
    }

    // MARK: Orders

    nonisolated enum OrderStatus: String, Codable, Sendable, Comparable {
        case placed
        case shipped
        case outForDelivery
        case delivered
        case cancelled

        var label: String {
            switch self {
            case .placed: "Ordered"
            case .shipped: "Shipped"
            case .outForDelivery: "On its way to you"
            case .delivered: "Delivered"
            case .cancelled: "Cancelled"
            }
        }

        /// Where it's got to: an update never moves an order back.
        private var stage: Int {
            switch self {
            case .placed: 0
            case .shipped: 1
            case .outForDelivery: 2
            case .delivered, .cancelled: 3
            }
        }

        static func < (lhs: OrderStatus, rhs: OrderStatus) -> Bool { lhs.stage < rhs.stage }

        var isDone: Bool { self == .delivered || self == .cancelled }
    }

    nonisolated struct Order: Equatable, Sendable {
        var service: Service
        var orderID: String?
        var status: OrderStatus
        var item: String?
    }

    /// Where an order has got to, by what the mail says of it. Nil for mail that isn't about an
    /// order — offers, reviews, account mail.
    static func order(_ service: Service, subject: String, body: String) -> Order? {
        let subjectLower = subject.lowercased()
        let lower = (subject + "\n" + body.prefix(1_500)).lowercased()
        let status: OrderStatus
        if ["cancelled", "canceled", "refund"].contains(where: subjectLower.contains) {
            status = .cancelled
        } else if lower.contains("delivered") && !lower.contains("will be delivered") && !lower.contains("to be delivered") {
            status = .delivered
        } else if ["out for delivery", "arriving today", "on the way", "on its way", "picked up", "is nearby", "reached your location"]
                    .contains(where: lower.contains) {
            status = .outForDelivery
        } else if ["shipped", "dispatched"].contains(where: lower.contains) {
            status = .shipped
        } else if ["order placed", "order confirmed", "order is confirmed", "ordered:", "thank you for your order",
                   "order has been placed", "received your order"].contains(where: lower.contains) {
            status = .placed
        } else {
            return nil
        }
        let id = (subject + "\n" + body).firstMatch(of: /\b(\d{3}-\d{7}-\d{7})\b/).map { String($0.1) }
            ?? (subject + "\n" + body).firstMatch(of: /(?i)order\s*(?:id|no\.?|number|#)\s*[:#]?\s*([A-Z0-9\-]{6,})/).map { String($0.1) }
        // Amazon names the item in quotes in its subject: Your Amazon.in order of "Boat Rockerz…" has shipped.
        let item = subject.firstMatch(of: /["“]([^"”]{3,80})["”]/).map { String($0.1) }
        return Order(service: service, orderID: id, status: status, item: item)
    }

    // MARK: What rides really cost

    /// How much your rides actually cost against PathOS's estimate for the same distance: the
    /// middle of the last few, so one surge doesn't set it. Nil until there are enough to go on.
    static func fareFactor(_ rides: [(fare: Double, estimate: Double)], recent: Int = 10, atLeast: Int = 3) -> Double? {
        let ratios = rides.suffix(recent).filter { $0.estimate > 0 && $0.fare > 0 }.map { $0.fare / $0.estimate }.sorted()
        guard ratios.count >= atLeast else { return nil }
        let middle = ratios.count / 2
        return ratios.count.isMultiple(of: 2) ? (ratios[middle - 1] + ratios[middle]) / 2 : ratios[middle]
    }
}
