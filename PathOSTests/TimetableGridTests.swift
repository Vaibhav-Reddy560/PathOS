import Foundation
import Testing
@testable import PathOS

/// Reading timetables from photos. The first case is a real timetable (BMS College of
/// Engineering, 5E, 2026) exactly as Vision's table recognition read it, with its mistakes: two
/// header slots merged, labs read as one slot, two classes merged into one cell, and cells
/// stretched over the lunch column. Read as plain lines, it produced nothing usable.
struct TimetableGridTests {
    private func cell(_ row: Int, _ columns: ClosedRange<Int>, _ text: String) -> TimetableGrid.Cell {
        TimetableGrid.Cell(row: row, columns: columns, text: text.replacingOccurrences(of: " ⏎ ", with: "\n"))
    }

    /// Table 0 of the photo, as `RecognizeDocumentsRequest` returned it.
    private var bmsTimetable: TimetableGrid {
        TimetableGrid(cells: [
            cell(0, 0...0, "Time → ⏎ Day +"), cell(0, 1...1, "11:15 AM - 12:10 PM"), cell(0, 2...2, "12:10PM - 1:05 PM"),
            cell(0, 3...3, "1:05 PM - 2:00 PM"), cell(0, 4...4, ""), cell(0, 5...5, "2:55 PM - 3:50 PM3:50 PM - 4:45PM"), cell(0, 6...6, ""),
            cell(1, 0...0, "MON"), cell(1, 1...1, "RMD"), cell(1, 2...2, ""), cell(1, 3...3, "DAV(P) ⏎ MEL-LAB3 ⏎ (Prof. NM, Prof. RV)"),
            cell(1, 4...6, "CNS ⏎ NIC ⏎ MEL-CR3 ⏎ MEL-CR3"),
            cell(2, 0...0, "TUE"), cell(2, 1...1, "RMD"), cell(2, 2...2, ""), cell(2, 3...3, "SML(P) ⏎ MEL-LAB2 ⏎ (Prof. SS, Prof. MK)"),
            cell(2, 4...5, "SML ⏎ MEL-CR3"), cell(2, 6...6, "DEL ⏎ MEL-CR3"),
            cell(3, 0...0, "WED"), cell(3, 1...1, "DEL ⏎ C-508"), cell(3, 2...2, "SML ⏎ C-508"),
            cell(3, 3...3, "KDD: MEL-CR-01 | MEL-CR-02 |MEL-CR-03 | MEL-CR-507|MEL-CR-216 ⏎ IOT : MEL-CR-506 ⏎ ITSMF : MEL-CR-508"),
            cell(3, 4...4, "LUNCH BREAK"), cell(3, 5...6, "DEL(P) ⏎ MEL-LAB1 ⏎ (Dr. JS, Prof. SP)"),
            cell(4, 0...0, "THUR"), cell(4, 1...1, "DAV ⏎ MEL-CR2"), cell(4, 2...2, "NIC ⏎ MEL-CR2"),
            cell(4, 3...3, "KDD: MEL-CR-01 | MEL-CR-02 | MEL-CR-03 | MBA-CR2 | MBA-CR4 ⏎ IOT: MEL-CR-506 ⏎ ITSMF: MBA-CR1"),
            cell(4, 4...5, "DEL ⏎ C-217"), cell(4, 6...6, "SML ⏎ C-217"),
            cell(5, 0...0, "FRI"), cell(5, 1...1, "MPW"), cell(5, 2...2, "MPW"),
            cell(5, 3...3, "KDD: MEL-CR-01 | MEL-CR-02 | MEL-CR-03 | MBA-CR2 | MBA-CR3 ⏎ IOT : MBA-CR1 ⏎ ITSMF: MBA-CR4"),
            cell(5, 4...4, ""), cell(5, 5...5, "CNS ⏎ C-216"), cell(5, 6...6, "EVS"),
            cell(6, 0...0, "SAT"), cell(6, 1...1, "MPW"), cell(6, 2...2, "MPW"),
            cell(6, 3...3, ""), cell(6, 4...4, ""), cell(6, 5...5, ""), cell(6, 6...6, ""),
        ])
    }

    /// Table 1 of the photo: who teaches what.
    private var bmsFaculty: TimetableGrid {
        TimetableGrid(cells: [
            cell(0, 0...0, "Course"), cell(0, 1...1, "DEL ⏎ （3-0-1）"), cell(0, 2...2, "CNS ⏎ （2-0-0）"), cell(0, 3...3, "SML ⏎ （3-0-1）"),
            cell(0, 4...4, "DAV ⏎ （1-0-1）"), cell(0, 5...5, "NIC ⏎ （1-0-0）"), cell(0, 6...6, "KDD ⏎ （3-0-0）"), cell(0, 7...7, "IOT ⏎ （3-0-0）"),
            cell(0, 8...8, "ITSMLF ⏎ （3-0-0）"), cell(0, 9...9, "MPW ⏎ （0-0-2）"), cell(0, 10...10, "EVS ⏎ （1-0-0）"), cell(0, 11...11, "RMD ⏎ （2-0-0）"),
            cell(1, 0...0, "FIC"), cell(1, 1...1, "Prof. Supriya P"), cell(1, 2...2, "Prof. Vishwas S"), cell(1, 3...3, "Prof. Sunil Sungas"),
            cell(1, 4...4, "Prof. Nida ⏎ Mohammadi"), cell(1, 5...5, "Dr. Jahnavi S"), cell(1, 6...6, "Dr. VBG ⏎ Dr. VH"),
            cell(1, 7...7, "Prof. Spoorthi ⏎ G.S."), cell(1, 8...8, "Prof. ⏎ Pallavi B"), cell(1, 9...9, "Prof. YBM"),
            cell(1, 10...10, ""), cell(1, 11...11, ""),
            cell(2, 0...0, "Initials"), cell(2, 1...1, "Prof. SP"),
        ])
    }

    private func time(_ hour: Int, _ minute: Int) -> Int { hour * 60 + minute }

    private func classes(on weekday: Int, in reading: TimetableReading) -> [String] {
        reading.classes.filter { $0.weekday == weekday }.map { item in
            let start = String(format: "%02d:%02d", item.start / 60, item.start % 60)
            let end = String(format: "%02d:%02d", item.end / 60, item.end % 60)
            return "\(start)-\(end) \(item.subject)" + (item.room.map { " @\($0)" } ?? "")
        }
    }

    @Test func itReadsTheWholeWeek() throws {
        let reading = try #require(bmsTimetable.reading())

        #expect(classes(on: 2, in: reading) == [
            "11:15-12:10 RMD", "12:10-14:00 DAV lab @MEL-LAB3", "14:55-15:50 CNS @MEL-CR3", "15:50-16:45 NIC @MEL-CR3",
        ])
        #expect(classes(on: 3, in: reading) == [
            "11:15-12:10 RMD", "12:10-14:00 SML lab @MEL-LAB2", "14:55-15:50 SML @MEL-CR3", "15:50-16:45 DEL @MEL-CR3",
        ])
        #expect(classes(on: 4, in: reading) == [
            "11:15-12:10 DEL @C-508", "12:10-13:05 SML @C-508",
            "13:05-14:00 IOT @MEL-CR-506", "13:05-14:00 ITSMF @MEL-CR-508",
            "13:05-14:00 KDD @MEL-CR-01, MEL-CR-02, MEL-CR-03, MEL-CR-507, MEL-CR-216",
            "14:55-16:45 DEL lab @MEL-LAB1",
        ])
        #expect(classes(on: 5, in: reading).filter { !$0.hasPrefix("13:05-") } == [
            "11:15-12:10 DAV @MEL-CR2", "12:10-13:05 NIC @MEL-CR2", "14:55-15:50 DEL @C-217", "15:50-16:45 SML @C-217",
        ])
        #expect(classes(on: 6, in: reading).filter { !$0.hasPrefix("13:05-") } == [
            "11:15-13:05 MPW", "14:55-15:50 CNS @C-216", "15:50-16:45 EVS",
        ])
        #expect(classes(on: 7, in: reading) == ["11:15-13:05 MPW"])
        #expect(classes(on: 1, in: reading).isEmpty)
    }

    @Test func labsKeepTheirTeachers() throws {
        let reading = try #require(bmsTimetable.reading())
        #expect(reading.classes.first { $0.subject == "DAV lab" }?.teacher == "Prof. NM, Prof. RV")
        #expect(reading.classes.first { $0.subject == "DEL lab" }?.teacher == "Dr. JS, Prof. SP")
    }

    @Test func electivesInOneSlotAreOffered() throws {
        let reading = try #require(bmsTimetable.reading())
        #expect(reading.electives == [["KDD", "IOT", "ITSMF"]])
    }

    @Test func theFacultyTableNamesTheRest() throws {
        let teachers = FacultyTable.teachers(in: bmsFaculty)
        #expect(teachers["DEL"] == "Prof. Supriya P")
        #expect(teachers["DAV"] == "Prof. Nida Mohammadi")
        #expect(teachers["KDD"] == "Dr. VBG, Dr. VH")
        #expect(teachers["ITSMLF"] == "Prof. Pallavi B")
        #expect(teachers["EVS"] == nil)
        #expect(bmsFaculty.reading() == nil)

        let reading = FacultyTable.apply(teachers, to: try #require(bmsTimetable.reading()))
        #expect(reading.classes.first { $0.subject == "CNS" }?.teacher == "Prof. Vishwas S")
        #expect(reading.classes.first { $0.subject == "DAV lab" }?.teacher == "Prof. NM, Prof. RV")
    }

    @Test func daysAcrossTheTopReadTheSame() throws {
        let turned = TimetableGrid(cells: bmsTimetable.cells.map {
            TimetableGrid.Cell(rows: $0.columns, columns: $0.rows, lines: $0.lines)
        })
        let reading = try #require(turned.reading())
        #expect(classes(on: 7, in: reading) == ["11:15-13:05 MPW"])
    }

    @Test func aPastedTableReads() throws {
        let text = """
        Day\t9:00-9:55\t10:00-10:55\t11:00-11:55
        Monday\tMaths LH-3\tPhysics Lab 2\t
        Tuesday\tChemistry C-101 (Dr. Rao)\tMaths LH-3\tMaths LH-3
        Wednesday\t\tBreak\tEnglish
        """
        let reading = try #require(TimetableGrid(delimitedText: text)?.reading())
        #expect(classes(on: 2, in: reading) == ["09:00-09:55 Maths @LH-3", "10:00-10:55 Physics @Lab 2"])
        #expect(classes(on: 3, in: reading) == ["09:00-09:55 Chemistry @C-101", "10:00-11:55 Maths @LH-3"] || classes(on: 3, in: reading) == ["09:00-09:55 Chemistry @C-101", "10:00-10:55 Maths @LH-3", "11:00-11:55 Maths @LH-3"])
        #expect(reading.classes.first { $0.subject == "Chemistry" }?.teacher == "Dr. Rao")
        #expect(classes(on: 4, in: reading) == ["11:00-11:55 English"])
    }

    @Test func timesReadEveryWay() {
        #expect(TimeRange.all(in: "11:15 AM - 12:10 PM").map(\.start) == [675])
        #expect(TimeRange.all(in: "12:10PM - 1:05 PM").map(\.end) == [785])
        #expect(TimeRange.all(in: "2:55 PM - 3:50 PM3:50 PM - 4:45PM").count == 2)
        #expect(TimeRange.all(in: "9.00-9.55").map(\.start) == [540])
        #expect(TimeRange.all(in: "11:15 - 12:10 pm").map(\.start) == [675])
        #expect(TimeRange.all(in: "(3-0-1)").isEmpty)
        #expect(TimeRange.all(in: "2026-27").isEmpty)
    }

    @Test func daysReadEveryWay() {
        #expect(Weekday.number("THUR") == 5)
        #expect(Weekday.number("Wednesday") == 4)
        #expect(Weekday.number("Tues.") == 3)
        #expect(Weekday.number("Monitoring") == nil)
    }

    // MARK: Photos, by where the text sits

    private func placed(_ row: Int, _ columns: ClosedRange<Int>, _ x: ClosedRange<Double>, _ lines: [(String, Double)]) -> TimetableGrid.Cell {
        TimetableGrid.Cell(rows: row...row, columns: columns, lines: lines.map(\.0), lineCenters: lines.map(\.1),
                           lineHeights: lines.map { _ in 0.5 - Double(row) * 0.1 }, xExtent: x,
                           yExtent: (0.45 - Double(row) * 0.1)...(0.55 - Double(row) * 0.1))
    }

    /// Rows of a drawn timetable as Vision read them: a merged two-period lab put in one column
    /// beside an empty one, and two neighbouring classes put in one cell. Where the text sits says
    /// what was really there.
    @Test func mergedAndRunTogetherCellsAreCutByPosition() throws {
        let edges: [ClosedRange<Double>] = [0.054...0.161, 0.161...0.286, 0.286...0.420, 0.420...0.553, 0.553...0.687, 0.687...0.812, 0.812...0.946]
        let times = ["09:00–09:50", "09:50–10:40", "10:50–11:40", "11:40–12:30", "13:30–14:20", "14:20–15:10"]
        var cells = [placed(0, 0...0, edges[0], [("Day", 0.106)])]
        for (index, time) in times.enumerated() {
            let edge = edges[index + 1]
            cells.append(placed(0, (index + 1)...(index + 1), edge, [(time, (edge.lowerBound + edge.upperBound) / 2)]))
        }
        cells += [
            placed(1, 0...0, edges[0], [("Monday", 0.105)]),
            placed(1, 1...1, edges[1], [("Data Structures", 0.225)]),
            // "Discrete Maths" in its own column, and a lab centred on the border of the next two.
            placed(1, 2...3, 0.286...0.553, [("Discrete Maths", 0.356), ("DS Lab", 0.552), ("CSE Lab 2", 0.553)]),
            placed(1, 4...4, edges[4], []),
            placed(1, 5...5, edges[5], [("Physics", 0.750), ("LH-204", 0.750)]),
            placed(1, 6...6, edges[6], [("Library", 0.882)]),
            placed(2, 0...0, edges[0], [("Wednesday", 0.105)]),
            placed(2, 1...1, edges[1], []),
            // A lab centred across the first two periods, filed under the second.
            placed(2, 2...2, edges[2], [("Physics Lab", 0.290), ("PHY Lab", 0.291)]),
            placed(2, 3...4, 0.420...0.687, [("Data Structures", 0.487), ("Discrete Maths", 0.619), ("LH-101", 0.485), ("LH-101", 0.618)]),
            placed(2, 5...6, 0.687...0.946, [("English", 0.751), ("LH-3", 0.750), ("Mentoring", 0.882)]),
        ]
        let reading = try #require(TimetableGrid(cells: cells).reading())
        #expect(classes(on: 2, in: reading) == [
            "09:00-09:50 Data Structures", "09:50-10:40 Discrete Maths", "10:50-12:30 DS Lab @CSE Lab 2",
            "13:30-14:20 Physics @LH-204", "14:20-15:10 Library",
        ])
        #expect(classes(on: 4, in: reading) == [
            "09:00-10:40 Physics Lab @PHY Lab", "10:50-11:40 Data Structures @LH-101", "11:40-12:30 Discrete Maths @LH-101",
            "13:30-14:20 English @LH-3", "14:20-15:10 Mentoring",
        ])
    }

    /// Two halves of one header read side by side, the second a hair higher: still one range, in
    /// reading order, with the stray mark between them ignored.
    @Test func aSplitHeaderStillReadsAsOneRange() throws {
        let cells = [
            placed(0, 0...0, 0.0...0.1, [("Day", 0.05)]),
            TimetableGrid.Cell(rows: 0...0, columns: 1...1, lines: ["12:10PM -"], lineCenters: [0.14], lineHeights: [0.50], xExtent: 0.1...0.2, yExtent: 0.45...0.55),
            TimetableGrid.Cell(rows: 0...0, columns: 1...1, lines: ["• 1:05 PM"], lineCenters: [0.17], lineHeights: [0.502], xExtent: 0.1...0.2, yExtent: 0.45...0.55),
            placed(0, 2...2, 0.2...0.3, [("1:05 PM - 2:00 PM", 0.25)]),
            placed(0, 3...3, 0.3...0.4, [("2:00 PM - 3:00 PM", 0.35)]),
            placed(1, 0...0, 0.0...0.1, [("Mon", 0.05)]), placed(1, 1...1, 0.1...0.2, [("Maths", 0.15)]),
            placed(1, 2...2, 0.2...0.3, [("Physics", 0.25)]), placed(1, 3...3, 0.3...0.4, [("Art", 0.35)]),
            placed(2, 0...0, 0.0...0.1, [("Tue", 0.05)]), placed(2, 1...1, 0.1...0.2, [("Art", 0.15)]),
        ]
        let reading = try #require(TimetableGrid(cells: cells).reading())
        #expect(classes(on: 2, in: reading).first == "12:10-13:05 Maths")
    }

    @Test func aBreakRowIsABreakForEveryDay() throws {
        let text = """
        Period\tMonday\tTuesday
        8:00 - 8:45\tScience Lab 1\tMaths Room 12
        8:45 - 9:00\tBREAK\t
        9:00 - 9:45\t\tEnglish Room 12
        """
        let reading = try #require(TimetableGrid(delimitedText: text)?.reading())
        // The lab doesn't spill into the break, even though the break is empty on Monday.
        #expect(classes(on: 2, in: reading) == ["08:00-08:45 Science @Lab 1"])
        #expect(classes(on: 3, in: reading) == ["08:00-08:45 Maths @Room 12", "09:00-09:45 English @Room 12"])
    }

    @Test func anUnreadableDayIsFilledInFromItsNeighbours() throws {
        let text = """
        Day\t9 AM - 10 AM\t10 AM - 11 AM
        Mo\tOS\tDBMS
        Tu\tDBMS\tOS
        We\tCN\tSE
        ??\tSE\tAI
        Fr\tAI\tCN
        """
        let reading = try #require(TimetableGrid(delimitedText: text)?.reading())
        #expect(classes(on: 5, in: reading) == ["09:00-10:00 SE", "10:00-11:00 AI"])
    }

    @Test func aHeaderOfStartTimesRunsEachToTheNext() throws {
        let text = """
        Time\t9:00\t10:00\t11:00\t2:00
        Mon\tMaths - Mr. Rao\tPhysics / C-101\tBiology (Lab 2)\tPE Ground
        Tue\tEnglish\tMaths - Mr. Rao\tPhysics / C-101\tArt
        """
        let reading = try #require(TimetableGrid(delimitedText: text)?.reading())
        #expect(classes(on: 2, in: reading) == [
            "09:00-10:00 Maths", "10:00-11:00 Physics @C-101", "11:00-12:00 Biology @Lab 2", "14:00-15:00 PE Ground",
        ])
        #expect(reading.classes.first { $0.subject == "Maths" }?.teacher == "Mr. Rao")
    }

    @Test func aPlaceOnTheNextLineIsTheRoom() {
        #expect(CellReader.read(["PE", "Ground"], slotCount: 1) == .classes([CellReader.Class(subject: "PE", room: "Ground", teacher: nil, isLab: false)]))
        // A wrapped title stays whole.
        #expect(CellReader.read(["Operating", "Systems"], slotCount: 1) == .classes([CellReader.Class(subject: "Operating Systems", room: nil, teacher: nil, isLab: false)]))
    }

    @Test func aListReadsLikeATable() throws {
        let text = """
        Monday
        9:00 - 10:00 Maths (LH-3)
        10-11 Physics - Mr. Rao
        • Lunch 1-2
        Tue: 9-10 Chemistry
        Wed 11:00-11:55 English LH-2
        """
        let reading = try #require(TimetableList.reading(from: text))
        #expect(classes(on: 2, in: reading) == ["09:00-10:00 Maths @LH-3", "10:00-11:00 Physics"])
        #expect(classes(on: 3, in: reading) == ["09:00-10:00 Chemistry"])
        #expect(classes(on: 4, in: reading) == ["11:00-11:55 English @LH-2"])
        #expect(reading.classes.first { $0.subject == "Physics" }?.teacher == "Mr. Rao")
    }

    @Test func lookalikeLettersAreReadAsLatin() {
        #expect(TimetableGrid.latin("LH-З") == "LH-3")
        #expect(TimetableGrid.Cell(row: 0, columns: 0...0, text: "Мaths").lines == ["Maths"])
    }
}
