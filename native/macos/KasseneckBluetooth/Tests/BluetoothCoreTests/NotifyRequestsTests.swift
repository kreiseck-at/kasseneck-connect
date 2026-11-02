import BluetoothCore
import XCTest

/// Offene `subscribe`/`unsubscribe` eines Merkmals: jeder Wunsch wird genau einmal beantwortet.
final class NotifyRequestsTests: XCTestCase {
    func testStehtDerZustandSchonUndLaeuftNichtsWirdSofortGeantwortet() {
        var requests = NotifyRequests()
        XCTAssertEqual(requests.add(1, enabled: true, current: true), .answerNow)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(requests.confirm(), [])
    }

    func testGleicherWunschWaehrendEinesWechselsWartetAufDessenBestaetigung() {
        var requests = NotifyRequests()
        XCTAssertEqual(requests.add(1, enabled: true, current: false), .callSetNotify)
        // Auch wenn CoreBluetooth den Zustand schon zeigt: ein zweiter Aufruf bliebe evtl. ohne Rückmeldung.
        XCTAssertEqual(requests.add(2, enabled: true, current: true), .wait)
        XCTAssertEqual(requests.add(3, enabled: true, current: false), .wait)
        XCTAssertEqual(requests.confirm(), [1, 2, 3])
        XCTAssertTrue(requests.isEmpty)
        // Danach gilt wieder die Sofort-Antwort.
        XCTAssertEqual(requests.add(4, enabled: true, current: true), .answerNow)
    }

    func testWechselnderWunschBekommtEineEigeneGruppeInReihenfolge() {
        var requests = NotifyRequests()
        XCTAssertEqual(requests.add(1, enabled: true, current: false), .callSetNotify)
        XCTAssertEqual(requests.add(2, enabled: false, current: false), .callSetNotify)
        XCTAssertEqual(requests.add(3, enabled: false, current: true), .wait)
        XCTAssertEqual(requests.add(4, enabled: true, current: true), .callSetNotify)
        XCTAssertEqual(requests.allIds, [1, 2, 3, 4])
        XCTAssertEqual(requests.confirm(), [1])
        XCTAssertEqual(requests.confirm(), [2, 3])
        XCTAssertEqual(requests.confirm(), [4])
        XCTAssertTrue(requests.isEmpty)
    }

    func testBeimTrennenSindAlleOffenenWuenscheGenauEinmalDa() {
        var requests = NotifyRequests()
        _ = requests.add(1, enabled: true, current: false)
        _ = requests.add(2, enabled: true, current: false)
        _ = requests.add(3, enabled: false, current: false)
        XCTAssertEqual(requests.allIds, [1, 2, 3])
        XCTAssertEqual(requests.confirm(), [1, 2])
        XCTAssertEqual(requests.allIds, [3])
    }
}
