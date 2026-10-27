import XCTest
@testable import NumidentCore

final class LayoutTests: XCTestCase {
    func testGoldenLineLengths() {
        for l in Golden.claim { XCTAssertEqual(l.utf8.count, DatasetKind.claim.lineLength) }
        for l in Golden.death { XCTAssertEqual(l.utf8.count, DatasetKind.death.lineLength) }
        for l in Golden.ss5 { XCTAssertEqual(l.utf8.count, DatasetKind.ss5.lineLength) }
    }

    func testClaimGolden() {
        let r = NumidentRecord(kind: .claim, line: Golden.claim[0])
        XCTAssertEqual(r.value("ref"), "65008336049")
        XCTAssertEqual(r.ssn, "001010002")
        XCTAssertEqual(r.value("form"), "5")
        XCTAssertEqual(r.entryCode, "L")
        XCTAssertEqual(r.cycleDate, PartialDate(year: 1976, month: 2, day: 19, raw: ""))
        XCTAssertEqual(r.fullName, "JOHN ALEXANDER HAZLETT")
        XCTAssertEqual(r.dob.description, "1879-02-28")
        XCTAssertEqual(r.sexCode, "0")
        XCTAssertEqual(r.value("pobCity"), "CAMBRIDGE")
        XCTAssertEqual(r.value("pobState"), "MA")
        // Columns 237–281 are the field office's address, not the birthplace.
        XCTAssertEqual(r.value("doAddress"), "CAMBRIDGE MASS")
        XCTAssertEqual(r.date("claimDate").description, "1944-03-17")
        XCTAssertEqual(r.value("conversion"), "A")
        XCTAssertEqual(r.birthplace, "CAMBRIDGE, MA")
    }

    func testDeathGolden() {
        let r = NumidentRecord(kind: .death, line: Golden.death[0])
        XCTAssertEqual(r.ssn, "001010104")
        XCTAssertEqual(r.entryCode, "T")
        XCTAssertEqual(r.cycleDate.description, "1989-12-21")
        XCTAssertEqual(r.fullName, "ELSIE E BAKER")
        XCTAssertEqual(r.dob.description, "1909-10-30")
        XCTAssertEqual(r.value("d1.otherNum"), "001010104")
        XCTAssertEqual(r.value("d1.zipResidence"), "033030000")
        XCTAssertEqual(r.value("d1.edr"), "N")
        XCTAssertEqual(r.value("noe"), "1")
        let p = r.deathPostings
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].dod.description, "1989-12-18")
        XCTAssertEqual(p[0].posted.description, "1989-12-21")

        let v = NumidentRecord(kind: .death, line: Golden.death[1])
        XCTAssertEqual(v.value("ref"), "87090100000")
        XCTAssertEqual(v.fullName, "VICTOR THOMPSON")
        XCTAssertEqual(v.value("d1.recordId"), "1")
        // Day unknown: "06XX1974".
        XCTAssertEqual(v.deathDate.description, "1974-06-??")
        XCTAssertEqual(v.deathDate.year, 1974)
        XCTAssertNil(v.deathDate.day)

        let e = NumidentRecord(kind: .death, line: Golden.death[2])
        XCTAssertEqual(e.fullName, "EDWARD O SMITH")
        XCTAssertEqual(e.value("d1.source"), "HC")
        XCTAssertEqual(Codes.sourceOfDeath.describe("HC"), "CMS (formerly HCFA)")
        XCTAssertEqual(e.deathDate.description, "1993-11-??")
    }

    func testSS5Golden() {
        let r = NumidentRecord(kind: .ss5, line: Golden.ss5[0])
        XCTAssertEqual(r.value("ref"), "65008000144")
        XCTAssertEqual(r.ssn, "001010501")
        XCTAssertEqual(r.value("form"), "1")
        XCTAssertEqual(r.entryCode, "0")
        XCTAssertEqual(Codes.entry.describe(r.entryCode), "Original SSN")
        // Cycle date with unknown day: "193611XX".
        XCTAssertEqual(r.cycleDate.description, "1936-11-??")
        XCTAssertEqual(r.fullName, "JOHN MARSHALL HOYT")
        XCTAssertEqual(r.dob.description, "1885-11-10")
        XCTAssertEqual(r.sex, "Male")
        XCTAssertEqual(r.value("race"), "1")
        XCTAssertEqual(r.motherName, "MINNIE PERKINS")
        XCTAssertEqual(r.fatherName, "J F HOYT")
        XCTAssertEqual(r.value("pobCity"), "LOCONIA")
        XCTAssertEqual(r.value("pobState"), "NH")
        XCTAssertEqual(r.value("sigCode"), "S")
        XCTAssertEqual(r.value("conversion"), "A")

        let s = NumidentRecord(kind: .ss5, line: Golden.ss5[2])
        XCTAssertEqual(s.fullName, "DONALD CHARLES GUYETTE")
        XCTAssertEqual(s.value("pobCity"), "CHESTERFIELD")
    }

    func testFieldsDoNotOverlap() {
        for kind in DatasetKind.allCases {
            let f = Layouts.fields(for: kind).sorted { $0.start < $1.start }
            for (a, b) in zip(f, f.dropFirst()) {
                XCTAssertLessThan(a.end, b.start, "\(kind) \(a.key) overlaps \(b.key)")
            }
            XCTAssertLessThanOrEqual(f.last!.end, 500)
        }
        XCTAssertEqual(Layouts.field("d3.posted", in: .death)?.end, 486)
        XCTAssertEqual(Layouts.field("d2.dod", in: .death)?.start, 295)
    }

    func testPartialDates() {
        XCTAssertEqual(PartialDate.mdy("06XX1974").description, "1974-06-??")
        XCTAssertEqual(PartialDate.mdy("XXXX1974").description, "1974-??-??")
        XCTAssertEqual(PartialDate.mdy("00001974").month, nil)
        XCTAssertEqual(PartialDate.ymd("193611XX").description, "1936-11-??")
        XCTAssertTrue(PartialDate.mdy("        ").isEmpty)
        XCTAssertTrue(PartialDate.mdy("06XX1974").isCompatible(with: .mdy("06151974")))
        XCTAssertFalse(PartialDate.mdy("06XX1974").isCompatible(with: .mdy("07151974")))
    }

    func testSoundex() {
        XCTAssertEqual(Soundex.string("Robert"), "R163")
        XCTAssertEqual(Soundex.string("Rupert"), "R163")
        XCTAssertEqual(Soundex.string("Rubin"), "R150")
        XCTAssertEqual(Soundex.string("Ashcraft"), "A261")
        XCTAssertEqual(Soundex.string("Tymczak"), "T522")
        XCTAssertEqual(Soundex.string("Pfister"), "P236")
        XCTAssertEqual(Soundex.string("Lee"), "L000")
        XCTAssertEqual(Soundex.code("SMITH"), Soundex.code("SMYTHE"))
    }

    func testQueryMatchingOnGoldenLines() {
        let hoyt = NumidentRecord(kind: .ss5, line: Golden.ss5[0])
        var q = SearchQuery()
        q.lastName = "hoyt"
        XCTAssertTrue(CompiledQuery(q).matches(hoyt))
        q.lastName = "HOY"
        XCTAssertFalse(CompiledQuery(q).matches(hoyt))
        q.nameMatch = .prefix
        XCTAssertTrue(CompiledQuery(q).matches(hoyt))
        q = SearchQuery()
        q.lastName = "HOIT"
        q.nameMatch = .soundex
        XCTAssertTrue(CompiledQuery(q).matches(hoyt))
        q = SearchQuery()
        q.dobYearFrom = 1880
        q.dobYearTo = 1890
        q.pobState = "nh"
        q.motherLast = "PERKINS"
        XCTAssertTrue(CompiledQuery(q).matches(hoyt))
        q.pobState = "MA"
        XCTAssertFalse(CompiledQuery(q).matches(hoyt))

        let thompson = NumidentRecord(kind: .death, line: Golden.death[1])
        q = SearchQuery()
        q.deathYearFrom = 1974
        q.deathYearTo = 1974
        XCTAssertTrue(CompiledQuery(q).matches(thompson))
        q.deathYearFrom = 1975
        q.deathYearTo = 1980
        XCTAssertFalse(CompiledQuery(q).matches(thompson))
        // Death-year searches never match SS-5 records, and the set is skipped up front.
        XCTAssertFalse(CompiledQuery(q).matches(hoyt))
        XCTAssertFalse(q.applicableKinds.contains(.ss5))

        XCTAssertTrue(CompiledQuery(.ssn("001-01-0501")).matches(hoyt))
        XCTAssertFalse(CompiledQuery(.ssn("001010502")).matches(hoyt))
    }

    func testSeparatorRecordNeverMatches() {
        let z = String(decoding: SyntheticDataset.separatorLine(.ss5).dropLast(), as: UTF8.self)
        let r = NumidentRecord(kind: .ss5, line: z)
        var q = SearchQuery()
        q.lastName = "Z"
        q.nameMatch = .prefix
        XCTAssertFalse(CompiledQuery(.ssn("999999999")).matches(r))
        XCTAssertNil(SSNIndex.validKey(r.bytes))
    }
}
