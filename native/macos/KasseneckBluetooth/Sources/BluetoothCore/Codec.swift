// Nachrichtenprotokoll zwischen Agent und Hilfsprogramm (docs/bluetooth-protokoll.md).
//
// Rein und ohne CoreBluetooth, damit es ohne Gerät testbar bleibt. Eine Zeile ist ein JSON-Objekt; gelesen und
// geschrieben wird so, dass eine Zeile der Dart-Seite byte-gleich wieder herauskommt (Schlüsselreihenfolge,
// Maskierung wie `jsonEncode`). Deshalb ein eigener kleiner JSON-Leser statt `JSONSerialization`, das weder die
// Reihenfolge hält noch `true` von `1` unterscheidet.
import Foundation

// MARK: - JSON

/// JSON-Wert; Objekte behalten ihre Schlüsselreihenfolge.
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

/// JSON-Objekt mit fester Reihenfolge. Ein doppelter Schlüssel behält seine erste Stelle und den letzten Wert –
/// genau wie die `Map` der Dart-Seite.
public struct JSONObject: Equatable, ExpressibleByDictionaryLiteral {
    public private(set) var members: [(key: String, value: JSONValue)] = []

    public init(_ pairs: [(String, JSONValue)] = []) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }

    public var isEmpty: Bool { members.isEmpty }

    public subscript(key: String) -> JSONValue? {
        get { members.first(where: { $0.key == key })?.value }
        set {
            let index = members.firstIndex(where: { $0.key == key })
            switch (index, newValue) {
            case let (i?, value?): members[i].value = value
            case let (i?, nil): members.remove(at: i)
            case let (nil, value?): members.append((key, value))
            case (nil, nil): break
            }
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.members.count == rhs.members.count
            && zip(lhs.members, rhs.members).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

extension JSONValue {
    var objectValue: JSONObject? {
        if case let .object(o) = self { return o }
        return nil
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case let .int(i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// Schreibt den Wert wie `jsonEncode` der Dart-Seite: ohne Leerraum, `/` und Nicht-ASCII unmaskiert.
    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .double(d): out += d.isFinite ? String(d) : "null"
        case let .string(s): writeString(s, into: &out)
        case let .array(items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case let .object(object): object.write(into: &out)
        }
    }
}

extension JSONObject {
    func write(into out: inout String) {
        out += "{"
        for (n, member) in members.enumerated() {
            if n > 0 { out += "," }
            writeString(member.key, into: &out)
            out += ":"
            member.value.write(into: &out)
        }
        out += "}"
    }
}

private func writeString(_ s: String, into out: inout String) {
    out += "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{8}": out += "\\b"
        case "\t": out += "\\t"
        case "\n": out += "\\n"
        case "\u{c}": out += "\\f"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

/// Liest genau einen JSON-Wert (RFC 8259) aus einer Zeile; `nil` bei allem anderen.
struct JSONReader {
    /// Schutz vor Stapelüberlauf durch tief verschachtelten Unsinn.
    static let maxDepth = 64

    private let bytes: [UInt8]
    private var i = 0
    private var depth = 0

    static func read(_ text: String) -> JSONValue? {
        var reader = JSONReader(bytes: Array(text.utf8))
        reader.skipSpace()
        guard let value = reader.value() else { return nil }
        reader.skipSpace()
        return reader.i == reader.bytes.count ? value : nil
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var current: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipSpace() {
        while let c = current, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
    }

    private mutating func expect(_ c: UInt8) -> Bool {
        guard current == c else { return false }
        i += 1
        return true
    }

    private mutating func value() -> JSONValue? {
        guard let c = current else { return nil }
        switch c {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return nil
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
        for b in word.utf8 {
            guard expect(b) else { return nil }
        }
        return value
    }

    private mutating func object() -> JSONValue? {
        guard depth < Self.maxDepth else { return nil }
        depth += 1
        defer { depth -= 1 }
        i += 1
        var result = JSONObject()
        skipSpace()
        if expect(UInt8(ascii: "}")) { return .object(result) }
        while true {
            skipSpace()
            guard current == UInt8(ascii: "\""), let key = string() else { return nil }
            skipSpace()
            guard expect(UInt8(ascii: ":")) else { return nil }
            skipSpace()
            guard let v = value() else { return nil }
            result[key] = v
            skipSpace()
            if expect(UInt8(ascii: ",")) { continue }
            return expect(UInt8(ascii: "}")) ? .object(result) : nil
        }
    }

    private mutating func array() -> JSONValue? {
        guard depth < Self.maxDepth else { return nil }
        depth += 1
        defer { depth -= 1 }
        i += 1
        var result: [JSONValue] = []
        skipSpace()
        if expect(UInt8(ascii: "]")) { return .array(result) }
        while true {
            skipSpace()
            guard let v = value() else { return nil }
            result.append(v)
            skipSpace()
            if expect(UInt8(ascii: ",")) { continue }
            return expect(UInt8(ascii: "]")) ? .array(result) : nil
        }
    }

    private mutating func string() -> String? {
        i += 1
        var buffer: [UInt8] = []
        while let c = current {
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let e = current else { return nil }
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(e)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else { return nil }
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: return nil
                }
            default:
                // Steuerzeichen müssen maskiert sein; alles andere ist schon gültiges UTF-8 aus dem String.
                guard c >= 0x20 else { return nil }
                buffer.append(c)
            }
        }
        return nil
    }

    /// `\uXXXX`, bei Ersatzpaaren beide Hälften. Eine einzelne Hälfte ist in Swift kein Zeichen → ungültig.
    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let high = hex4() else { return nil }
        if (0xD800...0xDBFF).contains(high) {
            guard expect(UInt8(ascii: "\\")), expect(UInt8(ascii: "u")), let low = hex4(),
                  (0xDC00...0xDFFF).contains(low) else { return nil }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        }
        return Unicode.Scalar(high)
    }

    private mutating func hex4() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let d = hexValue(bytes[i]) else { return nil }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    private func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(c - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(c - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    /// Ganzzahl ohne Bruch und Exponent wird `int` (wie in Dart), sonst `double`.
    private mutating func number() -> JSONValue? {
        let start = i
        var integral = true
        _ = expect(UInt8(ascii: "-"))
        if expect(UInt8(ascii: "0")) {
            // Führende Nullen sind in JSON nicht erlaubt.
        } else {
            guard digits() else { return nil }
        }
        if expect(UInt8(ascii: ".")) {
            integral = false
            guard digits() else { return nil }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            integral = false
            i += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { i += 1 }
            guard digits() else { return nil }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if integral, let n = Int(text) { return .int(n) }
        return Double(text).map(JSONValue.double)
    }

    private mutating func digits() -> Bool {
        let start = i
        while let c = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { i += 1 }
        return i > start
    }
}

// MARK: - Nachrichten

/// Fehler einer Antwort. Die Meldung ist nur fürs Protokoll gedacht.
public struct HelperError: Error, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Fehlercodes des Hilfsprogramms (gleich `HelperErrorCode` in `protocol.dart`).
public enum HelperErrorCode {
    public static let unknownDevice = "unknown_device"
    public static let notConnected = "not_connected"
    public static let unknownCharacteristic = "unknown_characteristic"
    public static let unsupportedOperation = "unsupported_operation"
    public static let writeFailed = "write_failed"
    public static let readFailed = "read_failed"
    public static let bluetoothOff = "bluetooth_off"
    public static let unauthorized = "unauthorized"
    public static let bluetoothUnsupported = "bluetooth_unsupported"
    public static let badRequest = "bad_request"
}

/// Befehle des Agenten (gleich `HelperOp` in `protocol.dart`).
public enum HelperOp {
    public static let ping = "ping"
    public static let state = "state"
    public static let scan = "scan"
    public static let stopScan = "stopScan"
    public static let connect = "connect"
    public static let disconnect = "disconnect"
    public static let gatt = "gatt"
    public static let read = "read"
    public static let write = "write"
    public static let subscribe = "subscribe"
    public static let unsubscribe = "unsubscribe"
}

/// Befehl des Agenten; `id` ordnet die Antwort zu.
public struct HelperRequest: Equatable {
    public let id: Int
    public let op: String
    public let args: JSONObject

    public init(id: Int, op: String, args: JSONObject = [:]) {
        self.id = id
        self.op = op
        self.args = args
    }
}

/// Antwort auf einen Befehl; der Nutzinhalt steht unter `result`, ein Fehler unter `error`.
public struct HelperResponse: Equatable {
    public let id: Int
    public let result: JSONObject
    public let error: HelperError?

    public var ok: Bool { error == nil }

    public static func success(_ id: Int, _ result: JSONObject = [:]) -> HelperResponse {
        HelperResponse(id: id, result: result, error: nil)
    }

    public static func failure(_ id: Int, _ error: HelperError) -> HelperResponse {
        HelperResponse(id: id, result: [:], error: error)
    }
}

/// Ungefragte Meldung ohne `id`; `fields` sind die Felder neben `event`.
public struct HelperEvent: Equatable {
    public let event: String
    public let fields: JSONObject

    public init(event: String, fields: JSONObject = [:]) {
        self.event = event
        self.fields = fields
    }

    public static func state(_ state: String) -> HelperEvent {
        HelperEvent(event: "state", fields: ["state": .string(state)])
    }

    public static func discovered(device: UUID, name: String?, rssi: Int, services: [String]) -> HelperEvent {
        HelperEvent(event: "discovered", fields: [
            "device": .string(deviceId(device)),
            "name": name.map(JSONValue.string) ?? .null,
            "rssi": .int(rssi),
            "services": .array(services.map(JSONValue.string)),
        ])
    }

    public static func connected(device: UUID, maxWriteWithResponse: Int, maxWriteWithoutResponse: Int) -> HelperEvent {
        HelperEvent(event: "connected", fields: [
            "device": .string(deviceId(device)),
            "maxWriteWithResponse": .int(maxWriteWithResponse),
            "maxWriteWithoutResponse": .int(maxWriteWithoutResponse),
        ])
    }

    public static func disconnected(device: UUID, reason: String) -> HelperEvent {
        HelperEvent(event: "disconnected", fields: [
            "device": .string(deviceId(device)),
            "reason": .string(reason),
        ])
    }

    public static func notification(device: UUID, service: String, characteristic: String, data: Data) -> HelperEvent {
        HelperEvent(event: "notification", fields: [
            "device": .string(deviceId(device)),
            "service": .string(service),
            "characteristic": .string(characteristic),
            "data": .string(data.base64EncodedString()),
        ])
    }
}

/// Geräte-ID auf der Leitung: CoreBluetooth-Kennung in Kleinschreibung.
public func deviceId(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

public enum HelperMessage: Equatable {
    case request(HelperRequest)
    case response(HelperResponse)
    case event(HelperEvent)

    var json: JSONObject {
        switch self {
        case let .request(r):
            return ["id": .int(r.id), "op": .string(r.op), "args": .object(r.args)]
        case let .response(r):
            if let e = r.error {
                return [
                    "id": .int(r.id), "ok": false,
                    "error": ["code": .string(e.code), "message": .string(e.message)],
                ]
            }
            return ["id": .int(r.id), "ok": true, "result": .object(r.result)]
        case let .event(e):
            var json: JSONObject = ["event": .string(e.event)]
            for member in e.fields.members { json[member.key] = member.value }
            return json
        }
    }

    /// Die Nachricht als eine Zeile (ohne Zeilenende).
    public func encode() -> String {
        var out = ""
        json.write(into: &out)
        return out
    }
}

/// Liest eine Zeile; `nil` bei allem, was keine gültige Nachricht ist (gleiche Regeln wie `decodeHelperLine` in Dart).
public func decodeHelperLine(_ line: String) -> HelperMessage? {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let json = JSONReader.read(text)?.objectValue else { return nil }

    let id = json["id"]
    if let event = json["event"]?.stringValue, id == nil || id == .null {
        var fields = json
        fields["event"] = nil
        return .event(HelperEvent(event: event, fields: fields))
    }
    guard let id = id?.intValue else { return nil }

    if let op = json["op"]?.stringValue {
        let args = json["args"] ?? .null
        if args == .null { return .request(HelperRequest(id: id, op: op)) }
        guard let object = args.objectValue else { return nil }
        return .request(HelperRequest(id: id, op: op, args: object))
    }

    guard let ok = json["ok"]?.boolValue else { return nil }
    if ok {
        let result = json["result"] ?? .null
        if result == .null { return .response(.success(id)) }
        guard let object = result.objectValue else { return nil }
        return .response(.success(id, object))
    }
    guard let error = json["error"]?.objectValue, let code = error["code"]?.stringValue else { return nil }
    return .response(.failure(id, HelperError(code: code, message: error["message"]?.stringValue ?? "")))
}

/// Die `id` einer Zeile, die zwar ein JSON-Objekt mit ganzzahliger `id` ist, aber kein gültiger Befehl –
/// darauf antwortet das Hilfsprogramm mit `bad_request`. Abgeschnittene Zeilen haben keine erkennbare `id`.
public func recognizableRequestId(_ line: String) -> Int? {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return JSONReader.read(text)?.objectValue?["id"]?.intValue
}

// MARK: - Befehle

/// Merkmal eines Geräts; Dienst und Merkmal stehen schon in der langen Kleinschreibung.
public struct CharacteristicAddress: Equatable {
    public let device: UUID
    public let service: String
    public let characteristic: String

    public init(device: UUID, service: String, characteristic: String) {
        self.device = device
        self.service = service
        self.characteristic = characteristic
    }
}

/// Ein geprüfter Befehl.
public enum Command: Equatable {
    case ping
    case state
    case scan(milliseconds: Int)
    case stopScan
    case connect(UUID)
    case disconnect(UUID)
    case gatt(UUID)
    case read(CharacteristicAddress)
    case write(CharacteristicAddress, data: Data, withResponse: Bool)
    case subscribe(CharacteristicAddress)
    case unsubscribe(CharacteristicAddress)

    /// Das Gerät, auf das sich der Befehl bezieht.
    public var device: UUID? {
        switch self {
        case .ping, .state, .scan, .stopScan: return nil
        case let .connect(d), let .disconnect(d), let .gatt(d): return d
        case let .read(a), let .write(a, _, _), let .subscribe(a), let .unsubscribe(a): return a.device
        }
    }
}

/// Längste Suche, die angenommen wird (eine Stunde); die Brücke sucht ohnehin nur Sekunden.
public let maxScanMilliseconds = 3_600_000

/// Prüft die Argumente eines Befehls; Fehler sind immer `bad_request`.
public func parseCommand(_ request: HelperRequest) -> Result<Command, HelperError> {
    let args = request.args
    func bad(_ message: String) -> Result<Command, HelperError> {
        .failure(HelperError(code: HelperErrorCode.badRequest, message: message))
    }
    func device() -> UUID? {
        args["device"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
    func address() -> CharacteristicAddress? {
        guard let d = device(),
              let s = args["service"]?.stringValue.flatMap(canonicalUuid),
              let c = args["characteristic"]?.stringValue.flatMap(canonicalUuid) else { return nil }
        return CharacteristicAddress(device: d, service: s, characteristic: c)
    }

    switch request.op {
    case HelperOp.ping: return .success(.ping)
    case HelperOp.state: return .success(.state)
    case HelperOp.stopScan: return .success(.stopScan)
    case HelperOp.scan:
        guard let ms = args["ms"]?.intValue, (1...maxScanMilliseconds).contains(ms) else {
            return bad("scan needs ms between 1 and \(maxScanMilliseconds)")
        }
        return .success(.scan(milliseconds: ms))
    case HelperOp.connect, HelperOp.disconnect, HelperOp.gatt:
        guard let d = device() else { return bad("\(request.op) needs a device id") }
        switch request.op {
        case HelperOp.connect: return .success(.connect(d))
        case HelperOp.disconnect: return .success(.disconnect(d))
        default: return .success(.gatt(d))
        }
    case HelperOp.read, HelperOp.subscribe, HelperOp.unsubscribe:
        guard let a = address() else { return bad("\(request.op) needs device, service and characteristic") }
        switch request.op {
        case HelperOp.read: return .success(.read(a))
        case HelperOp.subscribe: return .success(.subscribe(a))
        default: return .success(.unsubscribe(a))
        }
    case HelperOp.write:
        guard let a = address() else { return bad("write needs device, service and characteristic") }
        guard let data = args["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
            return bad("write needs data as Base64")
        }
        guard let withResponse = args["withResponse"]?.boolValue else { return bad("write needs withResponse") }
        return .success(.write(a, data: data, withResponse: withResponse))
    default:
        return bad("unknown op")
    }
}

// MARK: - Kennungen

/// Basis-UUID des Bluetooth-SIG, in die 16-/32-Bit-Kurzformen eingebettet sind.
private let basisSuffix = "-0000-1000-8000-00805f9b34fb"

/// Bringt eine 16-, 32- oder 128-Bit-UUID in die 128-Bit-Kleinschreibung (wie `canonicalUuid` in Dart, aber
/// ohne Leerraum zu dulden); `nil`, wenn es keine dieser Formen ist. Auch für `CBUUID.uuidString`, das 16-Bit-UUIDs
/// kurz und groß liefert.
public func canonicalUuid(_ uuid: String) -> String? {
    let s = uuid.lowercased()
    let isHex = { (part: Substring) in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isHexDigit } }
    switch s.count {
    case 4 where isHex(Substring(s)): return "0000\(s)\(basisSuffix)"
    case 8 where isHex(Substring(s)): return "\(s)\(basisSuffix)"
    case 36:
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy(isHex) else { return nil }
        return s
    default: return nil
    }
}

// MARK: - GATT

public struct GattCharacteristic: Equatable {
    public let uuid: String
    /// Teilmenge von `read`, `write`, `writeWithoutResponse`, `notify`, `indicate` in dieser Reihenfolge.
    public let properties: [String]

    public init(uuid: String, properties: [String]) {
        self.uuid = uuid
        self.properties = properties
    }
}

public struct GattService: Equatable {
    public let uuid: String
    public let characteristics: [GattCharacteristic]

    public init(uuid: String, characteristics: [GattCharacteristic]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

/// Ergebnis von `gatt`: `{"services":[{"uuid","characteristics":[{"uuid","properties"}]}]}`.
public func gattResult(_ services: [GattService]) -> JSONObject {
    [
        "services": .array(services.map { service in
            [
                "uuid": .string(service.uuid),
                "characteristics": .array(service.characteristics.map { c in
                    ["uuid": .string(c.uuid), "properties": .array(c.properties.map(JSONValue.string))]
                }),
            ]
        }),
    ]
}

// MARK: - Zustand

/// Zustandsnamen des Funkmoduls, wie CoreBluetooth sie benennt (gleich `helperStates` in Dart).
public let helperStates = ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"]

/// Endgültige Zustände; in `unknown` und `resetting` warten Befehle, bis einer davon erreicht ist.
public func isSettledState(_ state: String) -> Bool {
    ["unsupported", "unauthorized", "poweredOff", "poweredOn"].contains(state)
}

/// Fehler für Befehle, die das Funkmodul brauchen; `nil` nur bei `poweredOn`.
public func stateError(_ state: String) -> HelperError? {
    switch state {
    case "poweredOn": return nil
    case "unauthorized": return HelperError(code: HelperErrorCode.unauthorized, message: "bluetooth not authorized")
    case "unsupported":
        return HelperError(code: HelperErrorCode.bluetoothUnsupported, message: "bluetooth le not supported")
    default: return HelperError(code: HelperErrorCode.bluetoothOff, message: "bluetooth \(state)")
    }
}
