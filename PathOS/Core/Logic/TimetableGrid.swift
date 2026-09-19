import Foundation

/// A class read off a timetable.
nonisolated struct ReadClass: Equatable, Sendable {
    var subject: String
    /// `Calendar` numbering: Sunday is 1.
    var weekday: Int
    /// Minutes since midnight.
    var start: Int
    var end: Int
    var room: String?
    var teacher: String?
}

nonisolated struct TimetableReading: Equatable, Sendable {
    var classes: [ReadClass]
    /// Subjects taught in the same slot, of which you take one ("KDD", "IOT", "ITSMF").
    var electives: [[String]]
}

/// A timetable read as a table: which class sits in which day's row and which time's column.
///
/// Vision finds a photo's table rows and columns; this works out which way the days and times
/// run and reads each cell as a class. It also repairs what table detection gets wrong on printed
/// college timetables, where cells are merged freely:
/// - two time slots read as one header cell,
/// - a two-hour lab read as one slot beside an empty one,
/// - two classes read as one cell,
/// - a cell stretched across the lunch column.
///
/// A plain flattening of the text into lines loses all of this, which is why reading a photo of
/// a grid as text failed.
nonisolated struct TimetableGrid: Sendable {
    nonisolated struct Cell: Equatable, Sendable {
        var rows: ClosedRange<Int>
        var columns: ClosedRange<Int>
        var lines: [String]
        /// Where each line's middle sits across the table, 0 to 1, when the cell came from a photo.
        var lineCenters: [Double]?
        /// And how far up the page, 0 to 1 from the bottom.
        var lineHeights: [Double]?
        /// The cell's left and right edges, 0 to 1.
        var xExtent: ClosedRange<Double>?
        /// Its bottom and top, 0 to 1 from the bottom.
        var yExtent: ClosedRange<Double>?

        init(rows: ClosedRange<Int>, columns: ClosedRange<Int>, lines: [String],
             lineCenters: [Double]? = nil, lineHeights: [Double]? = nil,
             xExtent: ClosedRange<Double>? = nil, yExtent: ClosedRange<Double>? = nil) {
            self.rows = rows
            self.columns = columns
            let trimmed = lines.map { TimetableGrid.latin($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let kept = trimmed.indices.filter { !trimmed[$0].isEmpty }
            self.lines = kept.map { trimmed[$0] }
            if let lineCenters, lineCenters.count == lines.count {
                self.lineCenters = kept.map { lineCenters[$0] }
            }
            if let lineHeights, lineHeights.count == lines.count {
                self.lineHeights = kept.map { lineHeights[$0] }
            }
            self.xExtent = xExtent
            self.yExtent = yExtent
        }

        init(row: Int, columns: ClosedRange<Int>, text: String) {
            self.init(rows: row...row, columns: columns, lines: text.components(separatedBy: .newlines))
        }

        var text: String { lines.joined(separator: " ") }
    }

    var cells: [Cell]

    /// Cyrillic and Greek letters that look like Latin ones, as text recognition sometimes returns
    /// them ("LH-З" for "LH-3"), put back as the Latin letters and digits they are.
    static func latin(_ text: String) -> String {
        let lookalikes: [Character: Character] = [
            "З": "3", "О": "O", "о": "o", "А": "A", "а": "a", "В": "B", "Е": "E", "е": "e", "К": "K",
            "М": "M", "Н": "H", "Р": "P", "р": "p", "С": "C", "с": "c", "Т": "T", "Х": "X", "х": "x",
            "у": "y", "І": "I", "і": "i", "Ο": "O", "ο": "o", "Α": "A", "Β": "B", "Ε": "E", "Κ": "K",
            "Μ": "M", "Ν": "N", "Ρ": "P", "Τ": "T", "Χ": "X",
        ]
        return String(text.map { lookalikes[$0] ?? $0 })
    }

    init(cells: [Cell]) {
        self.cells = cells
    }

    /// A table pasted as text: tab- or pipe-separated columns, one row per line, as spreadsheets
    /// and notes copy them. Nil when the text isn't laid out as a table.
    init?(delimitedText text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let separator: Character? = [Character("\t"), "|"].first { separator in
            lines.filter { $0.contains(separator) }.count >= 3
        }
        guard let separator else { return nil }
        var cells: [Cell] = []
        for (row, line) in lines.enumerated() where line.contains(separator) {
            var fields = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            // "| MON | RMD |" has empty ends; they aren't columns.
            if separator == "|", fields.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { fields.removeFirst() }
            if separator == "|", fields.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { fields.removeLast() }
            for (column, field) in fields.enumerated() {
                // One line; "DEL C-508 (Prof. SP)" is split into subject, room and teacher when read.
                cells.append(Cell(rows: row...row, columns: column...column, lines: [field]))
            }
        }
        self.init(cells: cells)
    }

    // MARK: Reading

    /// The classes in the table, or nil when it isn't a timetable (no days one way and times the
    /// other).
    func reading() -> TimetableReading? {
        let cells = realigned().cells
        if let reading = Self.read(cells) { return reading }
        // Days across the top and times down the side: read it turned the other way. (The
        // re-cutting works across columns, so it only applies the right way up.)
        let turned = self.cells.map { Cell(rows: $0.columns, columns: $0.rows, lines: $0.lines) }
        return Self.read(turned)
    }

    // MARK: Re-cutting by position

    /// Vision's cells, re-cut by where their text actually sits. Its table reader can put two
    /// neighbouring classes in one cell, or split a merged two-period cell into an empty cell
    /// and a full one. The text's own position says which column, or which pair, it belongs to:
    /// centred on the border between two columns, or across an empty neighbour, it spans both.
    func realigned() -> TimetableGrid {
        // Each column's edges: the middle of what the cells spanning it alone say.
        var extents: [Int: [ClosedRange<Double>]] = [:]
        for cell in cells where cell.columns.count == 1 {
            if let extent = cell.xExtent { extents[cell.columns.lowerBound, default: []].append(extent) }
        }
        guard extents.count >= 3, cells.contains(where: { $0.lineCenters != nil }) else { return self }
        let edges = extents.mapValues { ranges -> ClosedRange<Double> in
            let lows = ranges.map(\.lowerBound).sorted(), highs = ranges.map(\.upperBound).sorted()
            return lows[lows.count / 2]...max(lows[lows.count / 2], highs[highs.count / 2])
        }
        let order = edges.keys.sorted()
        func middle(_ column: Int) -> Double { edges[column].map { ($0.lowerBound + $0.upperBound) / 2 } ?? 0 }

        /// The column a line sits in, or the pair whose border it's centred on.
        func place(_ x: Double) -> ClosedRange<Int> {
            guard let column = order.min(by: { abs(middle($0) - x) < abs(middle($1) - x) }),
                  let edge = edges[column], let index = order.firstIndex(of: column) else { return 0...0 }
            let width = edge.upperBound - edge.lowerBound
            if index > 0, x - edge.lowerBound < width * 0.12 { return order[index - 1]...column }
            if index + 1 < order.count, edge.upperBound - x < width * 0.12 { return column...order[index + 1] }
            return column...column
        }

        // Rows the same way: a line belongs to the row whose band it sits in, which on a table
        // without vertical lines isn't always the row the reader filed its cell under.
        var heights: [Int: [ClosedRange<Double>]] = [:]
        for cell in cells where cell.rows.count == 1 {
            if let extent = cell.yExtent { heights[cell.rows.lowerBound, default: []].append(extent) }
        }
        let bands = heights.mapValues { ranges -> ClosedRange<Double> in
            let lows = ranges.map(\.lowerBound).sorted(), highs = ranges.map(\.upperBound).sorted()
            return lows[lows.count / 2]...max(lows[lows.count / 2], highs[highs.count / 2])
        }
        func row(at y: Double, otherwise fallback: Int) -> Int {
            bands.first { $0.value.contains(y) }?.key ?? fallback
        }

        // Each cell's lines, filed by the row they sit in.
        var pieces: [(row: Int, cell: Cell)] = []
        for cell in cells {
            guard let centers = cell.lineCenters, centers.count == cell.lines.count, !cell.lines.isEmpty else {
                pieces.append((cell.rows.lowerBound, cell))
                continue
            }
            let lineRows = cell.lines.indices.map { index in
                cell.lineHeights.map { row(at: $0[index], otherwise: cell.rows.lowerBound) } ?? cell.rows.lowerBound
            }
            for lineRow in Set(lineRows).sorted() {
                let indices = cell.lines.indices.filter { lineRows[$0] == lineRow }
                pieces.append((lineRow, Cell(rows: lineRow...lineRow, columns: cell.columns,
                                             lines: indices.map { cell.lines[$0] }, lineCenters: indices.map { centers[$0] },
                                             lineHeights: cell.lineHeights.map { heights in indices.map { heights[$0] } },
                                             xExtent: cell.xExtent)))
            }
        }

        var rebuilt: [Cell] = []
        for row in Set(pieces.map(\.row)).sorted() {
            var blocks: [(columns: ClosedRange<Int>, lines: [String], centers: [Double], heights: [Double])] = []
            var occupied = Set<Int>()
            for cell in pieces.filter({ $0.row == row }).map(\.cell) {
                guard let centers = cell.lineCenters, centers.count == cell.lines.count, !cell.lines.isEmpty else {
                    if !cell.lines.isEmpty { occupied.formUnion(cell.columns) }
                    rebuilt.append(cell)
                    continue
                }
                var keys = centers.map(place)
                // Lines of one cell that fall on a border and just beside it are one cell across
                // both columns, not two.
                if let pair = keys.first(where: { $0.count == 2 }),
                   keys.allSatisfy({ $0 == pair || ($0.count == 1 && pair.contains($0.lowerBound)) }) {
                    keys = keys.map { _ in pair }
                }
                if Set(keys).count == 1, var key = keys.first {
                    // A merge wider than two columns has its text in the middle of the span.
                    if cell.columns.count > 2, let extent = cell.xExtent {
                        let average = centers.reduce(0, +) / Double(centers.count)
                        if abs(average - (extent.lowerBound + extent.upperBound) / 2) < (extent.upperBound - extent.lowerBound) * 0.1 {
                            key = cell.columns
                        }
                    }
                    blocks.append((key, cell.lines, centers, cell.lineHeights ?? centers.map { _ in 0 }))
                } else {
                    // Several classes read as one cell: one per column, each keeping its lines' order.
                    var seen: [ClosedRange<Int>] = []
                    for key in keys where !seen.contains(key) { seen.append(key) }
                    for key in seen {
                        let indices = keys.indices.filter { keys[$0] == key }
                        blocks.append((key, indices.map { cell.lines[$0] }, indices.map { centers[$0] },
                                       indices.map { cell.lineHeights?[$0] ?? 0 }))
                    }
                }
            }
            // Pieces that landed in the same place are one cell. Joined, their lines read top to
            // bottom, and left to right where they share a line ("12:10PM -" then "1:05 PM");
            // a cell that wasn't joined keeps the reader's own order.
            var merged: [(columns: ClosedRange<Int>, lines: [String], centers: [Double], heights: [Double], joined: Bool)] = []
            for block in blocks {
                if let index = merged.firstIndex(where: { $0.columns == block.columns }) {
                    merged[index].lines += block.lines
                    merged[index].centers += block.centers
                    merged[index].heights += block.heights
                    merged[index].joined = true
                } else {
                    merged.append((block.columns, block.lines, block.centers, block.heights, false))
                }
            }
            blocks = merged.map { block in
                guard block.joined else { return (block.columns, block.lines, block.centers, block.heights) }
                let order = block.lines.indices.sorted { a, b in
                    abs(block.heights[a] - block.heights[b]) < 0.01 ? block.centers[a] < block.centers[b] : block.heights[a] > block.heights[b]
                }
                return (block.columns, order.map { block.lines[$0] }, order.map { block.centers[$0] }, order.map { block.heights[$0] })
            }
            for block in blocks { occupied.formUnion(block.columns) }

            // Text alone in its column but centred across it and an empty neighbour: a merged
            // cell the reader split in two.
            for index in blocks.indices where blocks[index].columns.count == 1 {
                let column = blocks[index].columns.lowerBound
                guard let position = order.firstIndex(of: column), let own = edges[column] else { continue }
                let x = blocks[index].centers.reduce(0, +) / Double(blocks[index].centers.count)
                let offset = abs(x - middle(column))
                for neighbour in [position - 1, position + 1] where order.indices.contains(neighbour) && !occupied.contains(order[neighbour]) {
                    guard let other = edges[order[neighbour]] else { continue }
                    let pair = min(column, order[neighbour])...max(column, order[neighbour])
                    let pairMiddle = (min(own.lowerBound, other.lowerBound) + max(own.upperBound, other.upperBound)) / 2
                    if abs(x - pairMiddle) < offset * 0.5 {
                        blocks[index].columns = pair
                        occupied.insert(order[neighbour])
                        break
                    }
                }
            }
            rebuilt += blocks.map { Cell(rows: row...row, columns: $0.columns, lines: $0.lines, lineCenters: $0.centers, lineHeights: $0.heights) }
        }
        return TimetableGrid(cells: rebuilt)
    }

    private static func read(_ cells: [Cell]) -> TimetableReading? {
        // The header is the row with the most time ranges in it; failing that, a row of start
        // times ("9:00 | 10:00 | 11:00"), each slot running to the next.
        let rowIndices = Set(cells.map(\.rows.lowerBound))
        let header: Int
        var slots: [Int: (start: Int, end: Int)]
        if let ranged = rowIndices.max(by: { timeCount(inRow: $0, of: cells) < timeCount(inRow: $1, of: cells) }),
           timeCount(inRow: ranged, of: cells) >= 2 {
            header = ranged
            slots = slotColumns(headerRow: ranged, cells: cells)
        } else if let timed = rowIndices.max(by: { pointCount(inRow: $0, of: cells) < pointCount(inRow: $1, of: cells) }),
                  pointCount(inRow: timed, of: cells) >= 3 {
            header = timed
            slots = startColumns(headerRow: timed, cells: cells)
        } else {
            return nil
        }
        // A slot marked as a break, where nobody has a class, is a break for everyone: a lab mustn't
        // spread into it just because it's empty on that day. A break in one day's row alone is
        // only that day's.
        let breaks = Set(slots.keys.filter { column in
            let below = cells.filter { !$0.rows.contains(header) && $0.columns.contains(column) && !$0.lines.isEmpty }
            let saysBreak = below.contains { CellReader.isBreak($0.text) }
                || cells.contains { $0.rows.contains(header) && $0.columns.contains(column) && CellReader.isBreak($0.text) }
            let hasClass = below.contains { !CellReader.isBreak($0.text) && Weekday.number($0.text) == nil }
            return saysBreak && !hasClass
        })
        slots = slots.filter { !breaks.contains($0.key) }
        guard slots.count >= 2 else { return nil }
        let hasGeometry = cells.contains { $0.lineCenters != nil }

        // The day column is the one whose cells below the header name the most days.
        let columnIndices = Set(cells.map(\.columns.lowerBound))
        let dayColumn = columnIndices.max { a, b in dayCount(inColumn: a, of: cells, below: header) < dayCount(inColumn: b, of: cells, below: header) }
        guard let dayColumn, dayCount(inColumn: dayColumn, of: cells, below: header) >= 2 else { return nil }

        var classes: [ReadClass] = []
        var electives: [[String]] = []
        let days = weekdays(rows: rowIndices.sorted().filter { $0 > header }, dayColumn: dayColumn, cells: cells)
        for row in rowIndices.sorted() where row > header {
            guard let weekday = days[row] else { continue }

            // Each class with the slot columns it covers, in time order.
            var placed: [(columns: [Int], reading: CellReader.Class)] = []
            for cell in cells where cell.rows.lowerBound == row && !cell.columns.contains(dayColumn) {
                let covered = cell.columns.filter { slots[$0] != nil }
                guard !covered.isEmpty, !cell.lines.isEmpty, !CellReader.isBreak(cell.text) else { continue }
                let reading = CellReader.read(cell.lines, slotCount: covered.count)
                switch reading {
                case .classes(let found) where found.count == covered.count && found.count > 1:
                    // Two classes in one merged cell: one per slot, in order.
                    for (column, found) in zip(covered, found) { placed.append(([column], found)) }
                case .classes(let found):
                    for found in found { placed.append((covered, found)) }
                case .electives(let options):
                    electives.append(options.map(\.subject))
                    for option in options { placed.append((covered, option)) }
                }
            }

            // From a photo, merged cells were already found by where their text sits.
            if !hasGeometry {
                placed = spreadLabs(placed, slots: slots)
            }
            for (columns, found) in placed {
                guard let first = columns.min(), let last = columns.max(),
                      let start = slots[first]?.start, let end = slots[last]?.end, end > start else { continue }
                classes.append(ReadClass(subject: found.subject, weekday: weekday, start: start, end: end,
                                         room: found.room, teacher: found.teacher))
            }
        }
        guard !classes.isEmpty else { return nil }
        return TimetableReading(classes: joinRepeats(classes), electives: unique(electives))
    }

    /// Each row's day. A label the reader couldn't make out ("Th" read as nothing) is filled in
    /// from the rows either side, when they leave room for exactly the days between.
    private static func weekdays(rows: [Int], dayColumn: Int, cells: [Cell]) -> [Int: Int] {
        var days: [Int: Int] = [:]
        for row in rows {
            if let cell = cells.first(where: { $0.rows.contains(row) && $0.columns.contains(dayColumn) }),
               let weekday = Weekday.number(cell.text) {
                days[row] = weekday
            }
        }
        let known = rows.filter { days[$0] != nil }
        for (before, after) in zip(known, known.dropFirst()) {
            guard let first = days[before], let last = days[after] else { continue }
            let between = rows.filter { $0 > before && $0 < after }
            // Only rows that hold classes; a spacer row isn't a day.
            let dayRows = between.filter { row in cells.contains { $0.rows.lowerBound == row && !$0.columns.contains(dayColumn) && !$0.lines.isEmpty } }
            guard !dayRows.isEmpty, last - first == dayRows.count + 1 else { continue }
            for (offset, row) in dayRows.enumerated() { days[row] = first + offset + 1 }
        }
        return days
    }

    /// A lab read into one slot beside an empty one in the same row almost always filled both:
    /// the merged cell was split by the table's grid. Only across slots that run straight on
    /// from each other, never across lunch.
    private static func spreadLabs(_ placed: [(columns: [Int], reading: CellReader.Class)],
                                   slots: [Int: (start: Int, end: Int)]) -> [(columns: [Int], reading: CellReader.Class)] {
        let order = slots.keys.sorted()
        var taken = Set(placed.flatMap(\.columns))
        return placed.map { columns, found in
            guard found.isLab, columns.count == 1, let column = columns.first,
                  let index = order.firstIndex(of: column) else { return (columns, found) }
            let before = index > 0 ? order[index - 1] : nil
            let after = index + 1 < order.count ? order[index + 1] : nil
            if let before, !taken.contains(before), slots[before]?.end == slots[column]?.start {
                taken.insert(before)
                return ([before, column], found)
            }
            if let after, !taken.contains(after), slots[column]?.end == slots[after]?.start {
                taken.insert(after)
                return ([column, after], found)
            }
            return (columns, found)
        }
    }

    /// "MPW 11:15–12:10" and "MPW 12:10–1:05" are one class 11:15–1:05.
    private static func joinRepeats(_ classes: [ReadClass]) -> [ReadClass] {
        let sorted = classes.sorted { ($0.weekday, $0.start, $0.subject) < ($1.weekday, $1.start, $1.subject) }
        var joined: [ReadClass] = []
        for item in sorted {
            if let index = joined.lastIndex(where: { $0.weekday == item.weekday && $0.subject == item.subject }),
               joined[index].end == item.start, joined[index].room == item.room, joined[index].teacher == item.teacher {
                joined[index].end = item.end
            } else {
                joined.append(item)
            }
        }
        return joined
    }

    private static func unique(_ groups: [[String]]) -> [[String]] {
        var seen = Set<[String]>()
        return groups.filter { seen.insert($0).inserted }
    }

    // MARK: Axes

    private static func timeCount(inRow row: Int, of cells: [Cell]) -> Int {
        cells.filter { $0.rows.lowerBound == row }.reduce(0) { $0 + TimeRange.all(in: $1.text).count }
    }

    private static func pointCount(inRow row: Int, of cells: [Cell]) -> Int {
        cells.filter { $0.rows.lowerBound == row && TimeRange.points(in: $0.text).count == 1 }.count
    }

    /// Slots from a header of start times: each runs to the next start, the last as long as the
    /// usual slot.
    private static func startColumns(headerRow: Int, cells: [Cell]) -> [Int: (start: Int, end: Int)] {
        let starts = cells
            .filter { $0.rows.lowerBound == headerRow }
            .compactMap { cell in TimeRange.points(in: cell.text).first.map { (column: cell.columns.lowerBound, start: $0) } }
            .sorted { $0.column < $1.column }
        guard starts.count >= 2 else { return [:] }
        let gaps = zip(starts, starts.dropFirst()).map { $1.start - $0.start }.filter { $0 > 0 }.sorted()
        let usual = gaps.isEmpty ? 60 : gaps[gaps.count / 2]
        var slots: [Int: (start: Int, end: Int)] = [:]
        for (index, item) in starts.enumerated() {
            let next = index + 1 < starts.count ? starts[index + 1].start : item.start + usual
            // A long gap before the next start is a break, not a longer class.
            let end = next - item.start > usual * 3 / 2 ? item.start + usual : next
            if end > item.start { slots[item.column] = (item.start, end) }
        }
        return slots
    }

    private static func dayCount(inColumn column: Int, of cells: [Cell], below header: Int) -> Int {
        cells.filter { $0.columns.lowerBound == column && $0.rows.lowerBound > header && Weekday.number($0.text) != nil }.count
    }

    /// Each header column's time slot. A header cell holding two ranges ("2:55–3:50 3:50–4:45")
    /// hands the second to the next column whose own header is empty.
    private static func slotColumns(headerRow: Int, cells: [Cell]) -> [Int: (start: Int, end: Int)] {
        let header = cells.filter { $0.rows.contains(headerRow) }
        var slots: [Int: (start: Int, end: Int)] = [:]
        var spill: [(start: Int, end: Int)] = []
        let lastColumn = cells.map(\.columns.upperBound).max() ?? 0
        for column in 0...lastColumn {
            if let cell = header.first(where: { $0.columns.lowerBound == column }) {
                var ranges = TimeRange.all(in: cell.text)
                for spanned in cell.columns where !ranges.isEmpty {
                    slots[spanned] = ranges.removeFirst()
                }
                spill += ranges
            }
            // A column with no time of its own takes the one a neighbour's header held extra,
            // unless it's the lunch column.
            if slots[column] == nil, !spill.isEmpty, !isBreakColumn(column, cells: cells) {
                slots[column] = spill.removeFirst()
            }
        }
        return slots
    }

    private static func isBreakColumn(_ column: Int, cells: [Cell]) -> Bool {
        cells.contains { $0.columns == column...column && CellReader.isBreak($0.text) }
    }
}

// MARK: - Cells

/// What one cell says: a class, several, or electives offered in the same slot.
nonisolated enum CellReader {
    struct Class: Equatable, Sendable {
        var subject: String
        var room: String?
        var teacher: String?
        var isLab: Bool
    }

    enum Reading: Equatable, Sendable {
        case classes([Class])
        case electives([Class])
    }

    static func read(_ lines: [String], slotCount: Int) -> Reading {
        // "KDD: MEL-CR-01 | MEL-CR-02" / "IOT: MEL-CR-506": one option per line.
        let options = lines.compactMap(elective(from:))
        if options.count >= 2, options.count == lines.count {
            return .electives(options)
        }

        var subjects: [String] = []
        var rooms: [String] = []
        var teachers: [String] = []
        // Only the first line can carry its room after it ("English LH-2"); a later line is a room
        // or a teacher on its own ("CSE Lab 2").
        let expanded = lines.enumerated().flatMap { index, line in expand(line, roomAfter: index == 0) }
        for line in expanded {
            if isTeacher(line) {
                teachers.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
            } else if !subjects.isEmpty, isRoom(line) {
                rooms.append(line)
            } else if TimeRange.all(in: line).isEmpty {
                subjects.append(line)
            }
        }
        let teacher = teachers.isEmpty ? nil : teachers.joined(separator: ", ")

        // As many subjects as rooms, and as many as the slots the cell covers: one class each.
        if subjects.count > 1, subjects.count == slotCount, rooms.isEmpty || rooms.count == subjects.count {
            return .classes(subjects.enumerated().map { index, subject in
                make(subject, room: rooms.isEmpty ? nil : rooms[index], teacher: teacher)
            })
        }
        guard let first = subjects.first else { return .classes([]) }

        // One class: a later line naming a place is its room ("PE" / "Ground"); anything else is
        // the subject wrapped onto another line ("Operating" / "Systems").
        var subject = first
        for line in subjects.dropFirst() {
            if rooms.isEmpty, isPlace(line) {
                rooms.append(line)
            } else {
                subject += " " + line
            }
        }
        return .classes([make(subject, room: rooms.isEmpty ? nil : rooms.joined(separator: ", "), teacher: teacher)])
    }

    /// Places that carry no number: where PE, assembly or a talk happens.
    static func isPlace(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["ground", "field", "court", "hall", "auditorium", "library", "gym", "playground", "online",
                "seminar", "canteen", "block", "campus", "pool", "studio", "room"].contains { lower.contains($0) }
            && text.split(separator: " ").count <= 3
    }

    /// One written line can hold a subject with its room or teacher: "Maths (LH-3)",
    /// "Physics - Mr. Rao", "Chemistry / C-101", "Maths, LH-3". Split where a part is plainly a
    /// room or a teacher, and nowhere else, so "Data Structures & Algorithms" stays whole.
    static func expand(_ line: String, roomAfter: Bool = true) -> [String] {
        if isTeacher(line) { return [line] }
        // A bracketed room or teacher at the end.
        if let open = line.lastIndex(of: "("), line.hasSuffix(")"), open > line.startIndex {
            let inside = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            let before = line[..<open].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty, isRoom(inside) || isTeacher(inside) {
                return expand(before, roomAfter: roomAfter) + [isTeacher(inside) ? "(\(inside))" : inside]
            }
        }
        for separator in [" - ", " – ", " — ", " / ", ", "] {
            let parts = line.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count > 1, !parts[0].isEmpty,
                  parts.dropFirst().allSatisfy({ isRoom($0) || isTeacher($0) }) else { continue }
            return [parts[0]] + parts.dropFirst()
        }
        guard roomAfter else { return [line] }
        // A room after the subject on the same line: a code with a number ("English LH-2",
        // "Chemistry C-101"), or a room word and a number ("Physics Lab 2"). A bare number stays
        // with the subject ("Maths 2"), as does a room word alone ("DS Lab").
        let words = line.split(separator: " ").map(String.init)
        let roomWords: Set<String> = ["lab", "room", "rm", "hall", "lh", "block", "cr"]
        for index in words.indices.dropFirst() {
            let word = words[index]
            guard word.contains(where: \.isNumber) else { continue }
            let isCode = word.contains { $0.isLetter || $0 == "-" } && TimeRange.all(in: word).isEmpty
            let isNumbered = word.allSatisfy(\.isNumber) && index >= 2 && roomWords.contains(words[index - 1].lowercased())
            guard isCode || isNumbered else { continue }
            let start = isNumbered ? index - 1 : index
            return [words[..<start].joined(separator: " "), words[start...].joined(separator: " ")]
        }
        return [line]
    }

    private static func make(_ subject: String, room: String?, teacher: String?) -> Class {
        // "DAV(P)" is the DAV practical: a lab.
        let practical = subject.range(of: #"\s*\((P|p|Lab|LAB|lab)\)\s*$"#, options: .regularExpression)
        let isLab = practical != nil || room?.uppercased().contains("LAB") == true || subject.lowercased().hasSuffix(" lab")
        var name = subject
        if let practical { name = name.replacingCharacters(in: practical, with: "") + " lab" }
        return Class(subject: name, room: room, teacher: teacher, isLab: isLab)
    }

    private static func elective(from line: String) -> Class? {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 12, !parts[1].isEmpty,
              parts[0].range(of: #"^[A-Za-z][A-Za-z0-9&/ .-]*$"#, options: .regularExpression) != nil,
              TimeRange.all(in: line).isEmpty else { return nil }
        let rooms = parts[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Class(subject: parts[0], room: rooms.joined(separator: ", "), teacher: nil, isLab: false)
    }

    /// "C-508", "MEL-CR3", "MEL-LAB1", "Room 12", "LH 3".
    static func isRoom(_ text: String) -> Bool {
        let upper = text.uppercased()
        guard TimeRange.all(in: text).isEmpty, !isTeacher(text) else { return false }
        return upper.rangeOfCharacter(from: .decimalDigits) != nil
            || ["LAB", "ROOM", "HALL", "AUDITORIUM"].contains { upper.contains($0) }
    }

    /// "(Prof. NM, Prof. RV)", "Dr. JS".
    static func isTeacher(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        return trimmed.range(of: #"^(Prof|Dr|Mr|Mrs|Ms|Sir|Madam)\.?\s"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isBreak(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["lunch", "break", "recess", "free period"].contains { lower.contains($0) }
    }
}

// MARK: - Days and times

nonisolated enum Weekday {
    private static let names: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
        // Two-letter forms, as some timetables print them. Only ever the whole cell.
        "su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7,
    ]

    /// "MON", "Thur.", "Wednesday" → `Calendar` weekday. The whole cell has to be the day, so
    /// "Monitoring" isn't Monday.
    static func number(_ text: String) -> Int? {
        let letters = text.lowercased().filter(\.isLetter)
        return names[letters]
    }
}

nonisolated enum TimeRange {
    /// Every "11:15 AM – 12:10 PM", "9.00-9.55", "9 AM - 10 AM" or "1:05 to 2:00" in the text, as
    /// minutes since midnight. A start without am/pm takes its end's, unless that would put it
    /// after the end. Bare hours ("9-10") only count where the caller knows a time is expected.
    static func all(in text: String, allowingBareHours: Bool = false) -> [(start: Int, end: Int)] {
        // Photos add stray marks between a time's halves ("12:10PM - • 1:05 PM").
        let text = text.replacingOccurrences(of: #"[•·●▪◦∙]"#, with: " ", options: .regularExpression)
        let pattern = #/(\d{1,2}(?:[:.]\d{2})?)\s*([ap]\.?m\.?)?\s*(?:-|–|—|to)\s*(\d{1,2}(?:[:.]\d{2})?)\s*([ap]\.?m\.?)?/#
            .ignoresCase()
        return text.matches(of: pattern).compactMap { match in
            let startText = String(match.output.1)
            let endText = String(match.output.3)
            let endMeridiem = match.output.4.map { String($0).lowercased().filter(\.isLetter) }
            let startMeridiem = match.output.2.map { String($0).lowercased().filter(\.isLetter) }
            // "12:10PM" and "9 AM" are times; "3-0-1" credits and "2026-27" years aren't.
            let hasMinutes = (startText.contains(":") || startText.contains(".")) && (endText.contains(":") || endText.contains("."))
            guard hasMinutes || startMeridiem != nil || endMeridiem != nil || allowingBareHours else { return nil }
            guard let end = TimetableRoutine.minutes(fromTime: endText + (endMeridiem.map { " " + $0 } ?? "")) else { return nil }
            var start: Int?
            if let startMeridiem {
                start = TimetableRoutine.minutes(fromTime: "\(startText) \(startMeridiem)")
            } else if let endMeridiem {
                start = TimetableRoutine.minutes(fromTime: "\(startText) \(endMeridiem)")
                if let guess = start, guess >= end {
                    start = TimetableRoutine.minutes(fromTime: "\(startText) \(endMeridiem == "pm" ? "am" : "pm")")
                }
            } else {
                start = TimetableRoutine.minutes(fromTime: startText)
            }
            guard let start, end > start, end - start <= 6 * 60 else { return nil }
            return (start, end)
        }
    }

    /// Single times, for a header of start times: "9:00", "10.30", "2 PM".
    static func points(in text: String) -> [Int] {
        guard all(in: text).isEmpty else { return [] }
        let pattern = #/(\d{1,2}[:.]\d{2}|\d{1,2}\s*[ap]\.?m\.?)/#.ignoresCase()
        return text.matches(of: pattern).compactMap { match in
            // Not part of a longer number, such as a year or a room ("C-508").
            if match.range.lowerBound > text.startIndex {
                let before = text[text.index(before: match.range.lowerBound)]
                if before.isNumber || before == ":" || before == "." || before == "-" { return nil }
            }
            if match.range.upperBound < text.endIndex, text[match.range.upperBound].isNumber { return nil }
            let raw = String(match.output.1).lowercased().filter { $0 != "." || $0 == ":" }
            let normalized = raw.contains("m") ? raw : String(match.output.1).replacingOccurrences(of: ".", with: ":")
            return TimetableRoutine.minutes(fromTime: normalized)
        }
    }
}

// MARK: - Lists

/// A timetable written as a list rather than a grid, as it arrives in messages and notes:
///
///     Monday
///     9:00 - 10:00 Maths (LH-3)
///     10-11 Physics - Mr. Rao
///     Tue: 9-10 Chemistry
///     Wed 11:00-11:55 English LH-2
nonisolated enum TimetableList {
    static func reading(from text: String) -> TimetableReading? {
        var day: Int?
        var classes: [ReadClass] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "•*-–·"))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // A day at the start of the line: "Monday", "MONDAY:", "Tue: 9-10 Chemistry".
            let words = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == ":" || $0 == "," || $0 == "-" })
            if let first = words.first, let found = Weekday.number(String(first)) {
                day = found
                line = words.count > 1 ? String(words[1]).trimmingCharacters(in: CharacterSet(charactersIn: " :-–,")) : ""
                if line.isEmpty { continue }
            }
            guard let day, !CellReader.isBreak(line) else { continue }

            // The time comes first on the line, so bare hours ("9-10") are safe to read there.
            guard let match = line.firstMatch(of: #/^\(?\s*\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?m\.?)?\s*(?:-|–|—|to)\s*\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?m\.?)?\s*\)?/#.ignoresCase()),
                  let range = TimeRange.all(in: String(match.output), allowingBareHours: true).first else { continue }
            let rest = line[match.range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :-–|,"))
            guard !rest.isEmpty, case .classes(let found) = CellReader.read([rest], slotCount: 1), let item = found.first else { continue }
            classes.append(ReadClass(subject: item.subject, weekday: day, start: range.start, end: range.end,
                                     room: item.room, teacher: item.teacher))
        }
        return classes.count >= 2 ? TimetableReading(classes: classes, electives: []) : nil
    }
}

// MARK: - Faculty

nonisolated enum FacultyTable {
    /// Teachers by course code, from a "Faculty in-charge" table: course codes along the top and a
    /// row labelled FIC, Faculty or Teacher. Codes are matched on their first line, so
    /// "DEL (3-0-1)" is "DEL".
    static func teachers(in grid: TimetableGrid) -> [String: String] {
        let cells = grid.cells
        guard let facultyRow = cells.first(where: {
            $0.columns.lowerBound == 0 && $0.text.range(of: #"^(FIC|Faculty|Teacher|Instructor|Staff)"#, options: [.regularExpression, .caseInsensitive]) != nil
        })?.rows.lowerBound else { return [:] }
        let codeRow = cells.filter { $0.rows.lowerBound < facultyRow }.map(\.rows.lowerBound).max() ?? 0
        var teachers: [String: String] = [:]
        for codeCell in cells where codeCell.rows.lowerBound == codeRow && codeCell.columns.lowerBound > 0 {
            guard let code = codeCell.lines.first,
                  let names = cells.first(where: { $0.rows.contains(facultyRow) && $0.columns == codeCell.columns })?.lines,
                  !names.isEmpty else { continue }
            teachers[code.uppercased()] = joinNames(names)
        }
        return teachers
    }

    /// "Prof. Nida" / "Mohammadi" is one name; "Dr. VBG" / "Dr. VH" are two.
    private static func joinNames(_ lines: [String]) -> String {
        var names: [String] = []
        for line in lines {
            if CellReader.isTeacher(line) || names.isEmpty {
                names.append(line)
            } else {
                names[names.count - 1] += " " + line
            }
        }
        return names.joined(separator: ", ")
    }

    /// Fills in teachers the timetable's cells don't name, by course code ("DAV lab" is DAV).
    static func apply(_ teachers: [String: String], to reading: TimetableReading) -> TimetableReading {
        guard !teachers.isEmpty else { return reading }
        var reading = reading
        for index in reading.classes.indices where reading.classes[index].teacher == nil {
            let code = reading.classes[index].subject.replacingOccurrences(of: " lab", with: "").uppercased()
            reading.classes[index].teacher = teachers[code]
        }
        return reading
    }
}
