import BluetoothCore
import Foundation
import XCTest

/// Beispielzeilen aus der gemeinsamen Quelle; die Dart-Tests lesen dieselbe Datei.
private let beispiele: [(name: String, line: String)] = {
    let datei = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BluetoothCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // KasseneckBluetooth
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // native
        .deletingLastPathComponent() // Repo
        .appendingPathComponent("test/fixtures/bluetooth_protokoll_beispiele.jsonl")
    guard let text = try? String(contentsOf: datei, encoding: .utf8) else { return [] }
    var result: [(name: String, line: String)] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        guard let tab = raw.firstIndex(of: "\t") else { continue }
        result.append((name: String(raw[..<tab]), line: String(raw[raw.index(after: tab)...])))
    }
    return result
}()

private func beispiel(_ name: String) -> String {
    guard let line = beispiele.first(where: { $0.name == name })?.line else {
        XCTFail("Beispiel \(name) fehlt")
        return ""
    }
    return line
}

private let geraet = UUID(uuidString: "3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b")!

private func full(_ short: String) -> String { "0000\(short)-0000-1000-8000-00805f9b34fb" }

final class CodecTests: XCTestCase {
    func testBeispieldateiEnthaeltAlleBefehleUndEreignisse() {
        let names = Set(beispiele.map(\.name))
        XCTAssertFalse(names.isEmpty, "Beispieldatei nicht gefunden")
        for op in ["ping", "state", "scan", "stopScan", "connect", "disconnect", "gatt", "read", "write",
                   "subscribe", "unsubscribe"] {
            XCTAssertTrue(names.contains("request.\(op)"), op)
        }
        for event in ["state", "discovered", "connected", "disconnected", "notification"] {
            XCTAssertTrue(names.contains("event.\(event)"), event)
        }
    }

    func testGueltigeBeispielzeilenErgebenLesenUndSchreibenDieselbeZeile() {
        let gueltig = beispiele.filter { !$0.name.hasPrefix("invalid.") }
        XCTAssertGreaterThan(gueltig.count, 10)
        for (name, line) in gueltig {
            guard let msg = decodeHelperLine(line) else {
                XCTFail("\(name) nicht gelesen")
                continue
            }
            XCTAssertEqual(msg.encode(), line, name)
            XCTAssertEqual(decodeHelperLine(msg.encode()), msg, name)
        }
    }

    func testUngueltigeBeispielzeilenErgebenNil() {
        let ungueltig = beispiele.filter { $0.name.hasPrefix("invalid.") }
        XCTAssertEqual(ungueltig.count, 4)
        for (name, line) in ungueltig {
            XCTAssertNil(decodeHelperLine(line), name)
        }
    }

    func testWeitereUnsinnszeilenErgebenNil() {
        for line in [
            "null", "42", "\"x\"", "{\"id\":\"1\",\"op\":\"ping\"}", "{\"id\":1,\"ok\":false}",
            "{\"id\":1,\"ok\":false,\"error\":\"x\"}", "{\"id\":1,\"op\":\"ping\",\"args\":[]}", "{\"event\":5}",
            "\u{0}", "{\"id\":1.0,\"op\":\"ping\"}", "{\"id\":01,\"op\":\"ping\"}", "{\"id\":1,\"op\":\"ping\"} x",
            "{\"id\":1,\"op\":\"p\u{1}ng\"}", "{\"id\":1,\"op\":\"\\ud800\"}", "{'id':1}",
            String(repeating: "[", count: 100_000), String(repeating: "{\"a\":", count: 100_000),
        ] {
            XCTAssertNil(decodeHelperLine(line), line.prefix(40).description)
        }
    }

    func testAnfrageAntwortUndEreignisHabenDieErwartetenTypen() {
        guard case let .request(req)? = decodeHelperLine(beispiel("request.write")) else {
            return XCTFail("keine Anfrage")
        }
        XCTAssertEqual(req.id, 9)
        XCTAssertEqual(req.op, "write")
        XCTAssertEqual(req.args["withResponse"], .bool(false))

        guard case let .response(ok)? = decodeHelperLine(beispiel("response.okRead")) else {
            return XCTFail("keine Antwort")
        }
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.result["data"], .string("AgK2AA=="))

        guard case let .response(err)? = decodeHelperLine(beispiel("response.error")) else {
            return XCTFail("keine Antwort")
        }
        XCTAssertFalse(err.ok)
        XCTAssertEqual(err.error, HelperError(code: "not_connected", message: "peripheral is not connected"))

        guard case let .event(ev)? = decodeHelperLine(beispiel("event.connected")) else {
            return XCTFail("kein Ereignis")
        }
        XCTAssertEqual(ev.event, "connected")
        XCTAssertEqual(ev.fields["maxWriteWithoutResponse"], .int(20))
        XCTAssertNil(ev.fields["event"])
    }

    func testUnbekannteZusatzfelderWerdenIgnoriert() {
        XCTAssertEqual(
            decodeHelperLine("{\"id\":1,\"op\":\"ping\",\"args\":{},\"neu\":true}"),
            .request(HelperRequest(id: 1, op: "ping"))
        )
        XCTAssertEqual(
            decodeHelperLine("{\"id\":2,\"ok\":true,\"result\":{},\"x\":1}"),
            .response(.success(2))
        )
        XCTAssertEqual(
            decodeHelperLine(
                "{\"id\":3,\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"m\",\"x\":1},\"y\":2}"
            ),
            .response(.failure(3, HelperError(code: "bad_request", message: "m")))
        )
    }

    func testAnfrageOhneArgsUndZeileMitLeerraum() {
        XCTAssertEqual(
            decodeHelperLine("{\"id\":1,\"op\":\"ping\"}\r\n"),
            .request(HelperRequest(id: 1, op: "ping"))
        )
        XCTAssertEqual(
            decodeHelperLine("  { \"id\" : 1 , \"op\" : \"ping\" , \"args\" : { } }\t"),
            .request(HelperRequest(id: 1, op: "ping"))
        )
    }

    func testEncodeErzeugtGenauEineZeile() throws {
        let line = HelperMessage.request(HelperRequest(id: 1, op: "write", args: ["data": "a\nb"])).encode()
        XCTAssertFalse(line.contains("\n"))
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8))
        XCTAssertTrue(json is [String: Any])
    }

    func testZeichenWerdenWieAufDerDartSeiteMaskiert() {
        let event = HelperMessage.event(HelperEvent(event: "x", fields: [
            "s": "a\"b\\c/d\u{1}\u{8}\u{c}\n\r\tä€😀",
        ]))
        XCTAssertEqual(event.encode(), "{\"event\":\"x\",\"s\":\"a\\\"b\\\\c/d\\u0001\\b\\f\\n\\r\\tä€😀\"}")
        XCTAssertEqual(decodeHelperLine(event.encode()), event)
        // \u-Folgen inklusive Ersatzpaar werden gelesen.
        guard case let .event(read)? = decodeHelperLine("{\"event\":\"x\",\"s\":\"\\u00e4\\ud83d\\ude00\\/\"}") else {
            return XCTFail("nicht gelesen")
        }
        XCTAssertEqual(read.fields["s"], .string("ä😀/"))
    }

    func testDoppelterSchluesselBehaeltDieStelleUndNimmtDenLetztenWert() {
        let line = "{\"id\":1,\"op\":\"x\",\"args\":{\"a\":1,\"b\":2,\"a\":3}}"
        guard case let .request(req)? = decodeHelperLine(line) else {
            return XCTFail("nicht gelesen")
        }
        XCTAssertEqual(HelperMessage.request(req).encode(), "{\"id\":1,\"op\":\"x\",\"args\":{\"a\":3,\"b\":2}}")
    }

    // MARK: Ausgaben des Hilfsprogramms entsprechen den Beispielen

    func testAntwortenEntsprechenDenBeispielen() {
        XCTAssertEqual(HelperMessage.response(.success(1)).encode(), beispiel("response.ok"))
        XCTAssertEqual(HelperMessage.response(.success(8, ["data": "AgK2AA=="])).encode(), beispiel("response.okRead"))
        XCTAssertEqual(
            HelperMessage.response(.failure(9, HelperError(code: HelperErrorCode.notConnected,
                                                         message: "peripheral is not connected"))).encode(),
            beispiel("response.error")
        )
        let gatt = gattResult([
            GattService(uuid: full("ff00"), characteristics: [
                GattCharacteristic(uuid: full("ff01"), properties: ["read"]),
                GattCharacteristic(uuid: full("ff02"), properties: ["write", "writeWithoutResponse"]),
                GattCharacteristic(uuid: full("ff03"), properties: ["notify"]),
            ]),
        ])
        XCTAssertEqual(HelperMessage.response(.success(7, gatt)).encode(), beispiel("response.okGatt"))
    }

    func testEreignisseEntsprechenDenBeispielen() {
        XCTAssertEqual(HelperMessage.event(.state("poweredOn")).encode(), beispiel("event.state"))
        XCTAssertEqual(
            HelperMessage.event(.discovered(device: geraet, name: "Q199E00000", rssi: -58, services: ["ff00"]))
                .encode(),
            beispiel("event.discovered")
        )
        XCTAssertEqual(
            HelperMessage.event(.discovered(device: UUID(uuidString: "7C1D2E3F-4A5B-4C6D-8E9F-0A1B2C3D4E5F")!,
                                            name: nil, rssi: -80, services: [])).encode(),
            beispiel("event.discoveredUnnamed")
        )
        XCTAssertEqual(
            HelperMessage.event(.connected(device: geraet, maxWriteWithResponse: 512, maxWriteWithoutResponse: 20))
                .encode(),
            beispiel("event.connected")
        )
        XCTAssertEqual(
            HelperMessage.event(.disconnected(device: geraet, reason: "peripheral disconnected")).encode(),
            beispiel("event.disconnected")
        )
        XCTAssertEqual(
            HelperMessage.event(.notification(device: geraet, service: "ff00", characteristic: "ff03",
                                              data: Data([1, 1]))).encode(),
            beispiel("event.notification")
        )
    }

    // MARK: Befehle prüfen

    private func command(_ name: String) -> Command? {
        guard case let .request(req)? = decodeHelperLine(beispiel(name)) else { return nil }
        return try? parseCommand(req).get()
    }

    func testBeispielbefehleWerdenVerstanden() {
        let adresse = { (c: String) in
            CharacteristicAddress(device: geraet, service: full("ff00"), characteristic: full(c))
        }
        XCTAssertEqual(command("request.ping"), .ping)
        XCTAssertEqual(command("request.state"), .state)
        XCTAssertEqual(command("request.scan"), .scan(milliseconds: 5000))
        XCTAssertEqual(command("request.stopScan"), .stopScan)
        XCTAssertEqual(command("request.connect"), .connect(geraet))
        XCTAssertEqual(command("request.disconnect"), .disconnect(geraet))
        XCTAssertEqual(command("request.gatt"), .gatt(geraet))
        XCTAssertEqual(command("request.read"), .read(adresse("ff03")))
        XCTAssertEqual(command("request.write"), .write(adresse("ff02"), data: Data([1, 1]), withResponse: false))
        XCTAssertEqual(command("request.subscribe"), .subscribe(adresse("ff03")))
        XCTAssertEqual(command("request.unsubscribe"), .unsubscribe(adresse("ff03")))
        XCTAssertEqual(command("request.write")?.device, geraet)
        XCTAssertNil(command("request.scan")?.device)
    }

    func testLangeUuidsUndGrossschreibungWerdenVerstanden() throws {
        let req = HelperRequest(id: 1, op: "write", args: [
            "device": "3F2A9C1E-7B4D-4E2A-9A10-5C6D7E8F9A0B",
            "service": "0000FF00-0000-1000-8000-00805F9B34FB",
            "characteristic": "FF02",
            "data": "",
            "withResponse": true,
        ])
        XCTAssertEqual(
            try parseCommand(req).get(),
            .write(CharacteristicAddress(device: geraet, service: full("ff00"), characteristic: full("ff02")),
                   data: Data(), withResponse: true)
        )
    }

    func testFehlerhafteBefehleErgebenBadRequest() {
        let device = "3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b"
        let faelle: [(String, JSONObject)] = [
            ("fly", [:]),
            ("scan", [:]),
            ("scan", ["ms": "5000"]),
            ("scan", ["ms": 0]),
            ("scan", ["ms": 3_600_001]),
            ("connect", [:]),
            ("connect", ["device": "kein-geraet"]),
            ("connect", ["device": 5]),
            ("gatt", ["device": "3f2a9c1e7b4d4e2a9a105c6d7e8f9a0b"]),
            ("read", ["device": .string(device), "service": "ff0", "characteristic": "ff03"]),
            ("read", ["device": .string(device), "service": "ff00"]),
            ("subscribe", ["device": .string(device), "service": "ff00", "characteristic": "zz03"]),
            ("write", ["device": .string(device), "service": "ff00", "characteristic": "ff02", "data": "AQE=",
                       "withResponse": 1]),
            ("write", ["device": .string(device), "service": "ff00", "characteristic": "ff02", "data": "AQE="]),
            ("write", ["device": .string(device), "service": "ff00", "characteristic": "ff02", "data": "kein base64!",
                       "withResponse": true]),
        ]
        for (op, args) in faelle {
            let result = parseCommand(HelperRequest(id: 4, op: op, args: args))
            XCTAssertEqual(try? result.get(), nil, "\(op) \(args)")
            if case let .failure(error) = result {
                XCTAssertEqual(error.code, HelperErrorCode.badRequest, "\(op) \(args)")
            }
        }
    }

    func testEineZeileMitErkennbarerIdBekommtEineAntwort() {
        XCTAssertEqual(recognizableRequestId("{\"id\":5,\"op\":42}"), 5)
        XCTAssertEqual(recognizableRequestId("{\"id\":6,\"ok\":true}"), 6)
        XCTAssertNil(recognizableRequestId("{\"id\":1"))
        XCTAssertNil(recognizableRequestId("[]"))
        XCTAssertNil(recognizableRequestId("{\"id\":\"7\"}"))
        XCTAssertNil(recognizableRequestId("{\"event\":\"state\"}"))
    }

    // MARK: Kennungen und Zustände

    func testUuidsWerdenLangUndKleinGeschrieben() {
        XCTAssertEqual(canonicalUuid("ff00"), full("ff00"))
        XCTAssertEqual(canonicalUuid("FF00"), full("ff00"))
        XCTAssertEqual(canonicalUuid("0000FF00"), full("ff00"))
        XCTAssertEqual(canonicalUuid("12345678"), "12345678-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(canonicalUuid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"), "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        for ungueltig in ["", "ff0", "fff00", "zz00", "6e400001b5a3f393e0a9e50e24dcca9e", " ff00", "ff00\n",
                         "6e400001-b5a3-f393-e0a9-e50e24dcca9", "+f00"] {
            XCTAssertNil(canonicalUuid(ungueltig), ungueltig)
        }
    }

    func testZustaendeUndIhreFehler() {
        XCTAssertEqual(helperStates, ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"])
        XCTAssertNil(stateError("poweredOn"))
        XCTAssertEqual(stateError("poweredOff")?.code, HelperErrorCode.bluetoothOff)
        XCTAssertEqual(stateError("resetting")?.code, HelperErrorCode.bluetoothOff)
        XCTAssertEqual(stateError("unknown")?.code, HelperErrorCode.bluetoothOff)
        XCTAssertEqual(stateError("unauthorized")?.code, HelperErrorCode.unauthorized)
        XCTAssertEqual(stateError("unsupported")?.code, HelperErrorCode.bluetoothUnsupported)
        XCTAssertEqual(HelperErrorCode.bluetoothUnsupported, "bluetooth_unsupported")
        XCTAssertEqual(
            ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"].filter(isSettledState),
            ["unsupported", "unauthorized", "poweredOff", "poweredOn"]
        )
    }
}
