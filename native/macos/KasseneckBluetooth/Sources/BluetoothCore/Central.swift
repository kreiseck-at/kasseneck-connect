// Übersetzt Befehle mechanisch auf CoreBluetooth und meldet zurück, was CoreBluetooth meldet.
//
// Keine Entscheidungen: kein Wiederverbinden, keine eigenen Zeitlimits, keine Abos von sich aus – das alles macht der
// Agent. Alles läuft auf einer seriellen Queue: die Delegates von CoreBluetooth, die Befehle von stdin und jede
// Ausgabe. Deshalb braucht der Zustand hier keine Sperren.
import CoreBluetooth
import Foundation

public final class Central: NSObject {
    private let queue: DispatchQueue
    private let emit: (String) -> Void
    private let note: (String) -> Void

    /// Entsteht erst beim ersten Befehl außer `ping`, damit der Start des Hilfsprogramms keine Freigabe auslöst.
    private var manager: CBCentralManager?
    /// Befehle, die auf einen endgültigen Zustand warten (`unknown`, `resetting`).
    private var waiting: [(id: Int, command: Command)] = []
    /// Gefundene und verbundene Geräte; CoreBluetooth braucht eine starke Referenz.
    private var known: [UUID: CBPeripheral] = [:]
    private var links: [UUID: Link] = [:]
    /// Befehle für ein Gerät, das gerade getrennt wird; sie laufen erst nach dem Trennen, damit ein später
    /// `didDisconnect` kein neues Verbinden trifft.
    private var deferred: [UUID: [(id: Int, command: Command)]] = [:]
    private var scan: ScanRun?
    private var scanCount = 0
    private var reads: [CharacteristicKey: [Int]] = [:]
    private var writes: [CharacteristicKey: [Int]] = [:]
    private var notifyChanges: [CharacteristicKey: [Int]] = [:]
    /// Schreiben ohne Antwort, das auf die Flusssteuerung wartet (Reihenfolge je Gerät).
    private var unsent: [UUID: [UnsentWrite]] = [:]

    /// - Parameters:
    ///   - queue: serielle Queue für CoreBluetooth und allen Zustand; `handle(line:)` nur darauf aufrufen.
    ///   - emit: schreibt eine Protokollzeile (ohne Zeilenende) auf stdout.
    ///   - note: schreibt eine Notiz auf stderr (nie Nutzdaten).
    public init(queue: DispatchQueue, emit: @escaping (String) -> Void, note: @escaping (String) -> Void) {
        self.queue = queue
        self.emit = emit
        self.note = note
        super.init()
    }

    /// Verarbeitet eine Zeile von stdin.
    public func handle(line: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard case let .request(request)? = decodeHelperLine(line) else {
            if let id = recognizableRequestId(line) {
                fail(id, HelperError(code: HelperErrorCode.badRequest, message: "not a valid command"))
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note("Zeile verworfen, kein gültiger Befehl (\(line.utf8.count) Byte)")
            }
            return
        }
        switch parseCommand(request) {
        case let .failure(error): fail(request.id, error)
        case let .success(command): accept(request.id, command)
        }
    }

    // MARK: - Befehle

    private func accept(_ id: Int, _ command: Command) {
        if command == .ping { return succeed(id) }
        let manager = self.manager ?? makeManager()
        guard isSettledState(stateName(manager.state)) else {
            waiting.append((id, command))
            return
        }
        run(id, command)
    }

    private func makeManager() -> CBCentralManager {
        let manager = CBCentralManager(delegate: self, queue: queue)
        self.manager = manager
        return manager
    }

    private func run(_ id: Int, _ command: Command) {
        guard let manager else { return }
        if let device = command.device, links[device]?.phase == .disconnecting, command != .disconnect(device) {
            deferred[device, default: []].append((id, command))
            return
        }
        let state = stateName(manager.state)
        switch command {
        case .ping:
            succeed(id)
        case .state:
            succeed(id, ["state": .string(state)])
        case .stopScan:
            // Ohne Funk sucht nichts; das Ziel „keine Suche“ ist dann schon erreicht.
            if manager.state == .poweredOn { manager.stopScan() }
            finishScan(stop: false)
            succeed(id)
        case let .disconnect(device):
            disconnect(id, device)
        case .scan, .connect, .gatt, .read, .write, .subscribe, .unsubscribe:
            if let error = stateError(state) { return fail(id, error) }
            runWithRadio(id, command, manager)
        }
    }

    private func runWithRadio(_ id: Int, _ command: Command, _ manager: CBCentralManager) {
        switch command {
        case let .scan(milliseconds): startScan(id, milliseconds, manager)
        case let .connect(device): connect(id, device, manager)
        case let .gatt(device): gatt(id, device)
        case let .read(address): read(id, address)
        case let .write(address, data, withResponse): write(id, address, data, withResponse)
        case let .subscribe(address): setNotify(id, address, true)
        case let .unsubscribe(address): setNotify(id, address, false)
        case .ping, .state, .stopScan, .disconnect: break
        }
    }

    private func startScan(_ id: Int, _ milliseconds: Int, _ manager: CBCentralManager) {
        // Eine neue Suche beendet das Fenster der vorigen (deren Antwort kommt jetzt) und zählt Geräte neu.
        finishScan(stop: false)
        scanCount += 1
        let number = scanCount
        scan = ScanRun(number: number, request: id)
        manager.scanForPeripherals(withServices: nil, options: nil)
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self, self.scan?.number == number else { return }
            self.finishScan(stop: true)
        }
    }

    private func finishScan(stop: Bool) {
        guard let run = scan else { return }
        scan = nil
        if stop, let manager, manager.state == .poweredOn { manager.stopScan() }
        succeed(run.request)
    }

    private func connect(_ id: Int, _ device: UUID, _ manager: CBCentralManager) {
        if var link = links[device] {
            switch link.phase {
            case .ready:
                announce(link.peripheral)
                succeed(id)
            case .connecting, .discovering:
                link.connects.append(id)
                links[device] = link
            case .disconnecting:
                break // schon in `run` zurückgestellt
            }
            return
        }
        guard let peripheral = manager.retrievePeripherals(withIdentifiers: [device]).first ?? known[device] else {
            return fail(id, HelperError(code: HelperErrorCode.unknownDevice, message: "device not known to this mac"))
        }
        known[device] = peripheral
        peripheral.delegate = self
        links[device] = Link(peripheral: peripheral, phase: .connecting, connects: [id])
        manager.connect(peripheral, options: nil)
    }

    private func disconnect(_ id: Int, _ device: UUID) {
        guard var link = links[device] else { return succeed(id) }
        let cancelled = HelperError(code: HelperErrorCode.notConnected, message: "connect cancelled")
        switch link.phase {
        case .connecting:
            // Noch keine Verbindung: auf eine Rückmeldung zum abgebrochenen Verbinden ist kein Verlass, also gleich
            // fertig. Kommt es doch noch zustande, baut `didConnect` es wieder ab.
            links[device] = nil
            manager?.cancelPeripheralConnection(link.peripheral)
            link.connects.forEach { fail($0, cancelled) }
            succeed(id)
        case .discovering, .ready:
            link.connects.forEach { fail($0, cancelled) }
            link.connects = []
            link.phase = .disconnecting
            link.disconnects = [id]
            links[device] = link
            manager?.cancelPeripheralConnection(link.peripheral)
        case .disconnecting:
            link.disconnects.append(id)
            links[device] = link
        }
    }

    private func gatt(_ id: Int, _ device: UUID) {
        guard let peripheral = readyPeripheral(device) else { return fail(id, notConnected) }
        let services = (peripheral.services ?? []).compactMap { service -> GattService? in
            guard let uuid = canonicalUuid(service.uuid.uuidString) else { return nil }
            let characteristics = (service.characteristics ?? []).compactMap { c -> GattCharacteristic? in
                guard let uuid = canonicalUuid(c.uuid.uuidString) else { return nil }
                return GattCharacteristic(uuid: uuid, properties: propertyNames(c.properties))
            }
            return GattService(uuid: uuid, characteristics: characteristics)
        }
        succeed(id, gattResult(services))
    }

    private func read(_ id: Int, _ address: CharacteristicAddress) {
        guard let (peripheral, characteristic) = find(id, address) else { return }
        guard characteristic.properties.contains(.read) else {
            return fail(id, unsupported("characteristic cannot be read"))
        }
        reads[CharacteristicKey(address.device, characteristic), default: []].append(id)
        peripheral.readValue(for: characteristic)
    }

    private func write(_ id: Int, _ address: CharacteristicAddress, _ data: Data, _ withResponse: Bool) {
        guard let (peripheral, characteristic) = find(id, address) else { return }
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        guard characteristic.properties.contains(withResponse ? .write : .writeWithoutResponse) else {
            return fail(id, unsupported(withResponse ? "characteristic has no write with response"
                                                     : "characteristic has no write without response"))
        }
        // Ohne Antwort kürzt CoreBluetooth zu lange Daten stumm – deshalb nie schreiben, was nicht passt.
        let max = peripheral.maximumWriteValueLength(for: type)
        guard data.count <= max else {
            return fail(id, HelperError(code: HelperErrorCode.writeFailed,
                                        message: "data longer than \(max) bytes for this write type"))
        }
        if withResponse {
            writes[CharacteristicKey(address.device, characteristic), default: []].append(id)
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } else if (unsent[address.device] ?? []).isEmpty && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            succeed(id)
        } else {
            unsent[address.device, default: []].append(UnsentWrite(id: id, characteristic: characteristic, data: data))
        }
    }

    private func setNotify(_ id: Int, _ address: CharacteristicAddress, _ enabled: Bool) {
        guard let (peripheral, characteristic) = find(id, address) else { return }
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            return fail(id, unsupported("characteristic cannot notify"))
        }
        let key = CharacteristicKey(address.device, characteristic)
        // Steht der Wunsch schon, meldet CoreBluetooth nicht zwingend zurück – dann gleich antworten.
        if (notifyChanges[key] ?? []).isEmpty && characteristic.isNotifying == enabled { return succeed(id) }
        notifyChanges[key, default: []].append(id)
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    // MARK: - Hilfen

    private var notConnected: HelperError {
        HelperError(code: HelperErrorCode.notConnected, message: "peripheral is not connected")
    }

    private func unsupported(_ message: String) -> HelperError {
        HelperError(code: HelperErrorCode.unsupportedOperation, message: message)
    }

    private func readyPeripheral(_ device: UUID) -> CBPeripheral? {
        guard let link = links[device], link.phase == .ready else { return nil }
        return link.peripheral
    }

    /// Sucht das Merkmal; antwortet selbst mit dem Fehler, wenn es nicht geht.
    private func find(_ id: Int, _ address: CharacteristicAddress) -> (CBPeripheral, CBCharacteristic)? {
        guard let peripheral = readyPeripheral(address.device) else {
            fail(id, notConnected)
            return nil
        }
        for service in peripheral.services ?? [] where canonicalUuid(service.uuid.uuidString) == address.service {
            if let c = service.characteristics?.first(where: {
                canonicalUuid($0.uuid.uuidString) == address.characteristic
            }) {
                return (peripheral, c)
            }
        }
        fail(id, HelperError(code: HelperErrorCode.unknownCharacteristic, message: "characteristic not found"))
        return nil
    }

    private func announce(_ peripheral: CBPeripheral) {
        send(.event(.connected(
            device: peripheral.identifier,
            maxWriteWithResponse: peripheral.maximumWriteValueLength(for: .withResponse),
            maxWriteWithoutResponse: peripheral.maximumWriteValueLength(for: .withoutResponse)
        )))
    }

    private func becomeReady(_ device: UUID) {
        guard var link = links[device] else { return }
        let waitingConnects = link.connects
        link.phase = .ready
        link.announced = true
        link.connects = []
        links[device] = link
        // Erst das Ereignis, dann die Antwort: kehrt `connect` beim Agenten zurück, kennt er die Schreiblängen.
        announce(link.peripheral)
        waitingConnects.forEach { succeed($0) }
    }

    /// Verbinden gescheitert, nachdem CoreBluetooth schon verbunden hatte: Verbindung wieder abbauen.
    private func abortConnect(_ device: UUID, _ message: String) {
        guard var link = links[device] else { return }
        link.connects.forEach { fail($0, HelperError(code: HelperErrorCode.notConnected, message: message)) }
        link.connects = []
        link.phase = .disconnecting
        links[device] = link
        manager?.cancelPeripheralConnection(link.peripheral)
    }

    /// Die Verbindung ist weg: melden, Offenes beantworten, Zurückgestelltes weiterlaufen lassen.
    private func closeLink(_ device: UUID, reason: String) {
        guard let link = links.removeValue(forKey: device) else { return }
        if link.announced { send(.event(.disconnected(device: device, reason: reason))) }
        let gone = HelperError(code: HelperErrorCode.notConnected, message: reason)
        link.connects.forEach { fail($0, gone) }
        var open = take(&reads, device) + take(&writes, device) + take(&notifyChanges, device)
        open += (unsent.removeValue(forKey: device) ?? []).map(\.id)
        open.sorted().forEach { fail($0, gone) }
        link.disconnects.forEach { succeed($0) }
        for (id, command) in deferred.removeValue(forKey: device) ?? [] { accept(id, command) }
    }

    private func take(_ table: inout [CharacteristicKey: [Int]], _ device: UUID) -> [Int] {
        var ids: [Int] = []
        for key in table.keys.filter({ $0.device == device }) { ids += table.removeValue(forKey: key) ?? [] }
        return ids
    }

    private func pop(_ table: inout [CharacteristicKey: [Int]], _ key: CharacteristicKey) -> Int? {
        guard var ids = table[key], !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        table[key] = ids.isEmpty ? nil : ids
        return id
    }

    private func send(_ message: HelperMessage) { emit(message.encode()) }

    private func succeed(_ id: Int, _ result: JSONObject = [:]) { send(.response(.success(id, result))) }

    private func fail(_ id: Int, _ error: HelperError) { send(.response(.failure(id, error))) }
}

// MARK: - CoreBluetooth

extension Central: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = stateName(central.state)
        send(.event(.state(state)))
        if central.state != .poweredOn {
            // Ohne Funk sind alle Verbindungen weg; CoreBluetooth ruft dafür kein `didDisconnect`.
            if let run = scan, let error = stateError(state) {
                scan = nil
                fail(run.request, error)
            }
            for device in Array(links.keys) { closeLink(device, reason: "bluetooth \(state)") }
            known.removeAll()
        }
        guard isSettledState(state) else { return }
        let ready = waiting
        waiting = []
        for (id, command) in ready { run(id, command) }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard var run = scan else { return }
        let device = peripheral.identifier
        known[device] = peripheral
        let name = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        // Je Gerät und Suche ein Fund; kommt der Name erst mit einer späteren Meldung, folgt er einmal nach.
        switch run.seen[device] {
        case true?: return
        case false?: if name == nil { return }
        case nil: break
        }
        run.seen[device] = name != nil
        scan = run
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .compactMap { canonicalUuid($0.uuidString) }
        send(.event(.discovered(device: device, name: name, rssi: RSSI.intValue, services: services)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let device = peripheral.identifier
        guard var link = links[device] else {
            // Ein abgebrochener Verbindungsversuch kam doch noch zustande – nicht stehen lassen.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard link.phase == .connecting else { return }
        link.phase = .discovering
        links[device] = link
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        let device = peripheral.identifier
        guard let link = links[device], link.phase == .connecting || link.phase == .discovering else { return }
        closeLink(device, reason: error?.localizedDescription ?? "connect failed")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        let device = peripheral.identifier
        guard let link = links[device] else { return }
        let reason = error?.localizedDescription
            ?? (link.phase == .disconnecting ? "disconnect requested" : "disconnected")
        closeLink(device, reason: reason)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let device = peripheral.identifier
        guard var link = links[device], link.phase == .discovering else { return }
        if let error { return abortConnect(device, "service discovery failed: \(error.localizedDescription)") }
        let services = peripheral.services ?? []
        if services.isEmpty { return becomeReady(device) }
        link.servicesLeft = services.count
        links[device] = link
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let device = peripheral.identifier
        guard var link = links[device], link.phase == .discovering else { return }
        if let error {
            // Ein Dienst ohne Merkmale hält das Verbinden nicht auf; `gatt` zeigt ihn dann leer.
            note("Merkmale von \(service.uuid.uuidString) nicht gelesen: \(error.localizedDescription)")
        }
        link.servicesLeft -= 1
        links[device] = link
        if link.servicesLeft <= 0 { becomeReady(device) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let id = pop(&writes, CharacteristicKey(peripheral.identifier, characteristic)) else { return }
        if let error {
            fail(id, HelperError(code: HelperErrorCode.writeFailed, message: error.localizedDescription))
        } else {
            succeed(id)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let device = peripheral.identifier
        guard readyPeripheral(device) != nil else { return }
        while var pending = unsent[device], let next = pending.first, peripheral.canSendWriteWithoutResponse {
            pending.removeFirst()
            unsent[device] = pending.isEmpty ? nil : pending
            peripheral.writeValue(next.data, for: next.characteristic, type: .withoutResponse)
            succeed(next.id)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let device = peripheral.identifier
        // Lesen und Meldung kommen beide hier an; ein offenes Lesen nimmt den nächsten Wert.
        if let id = pop(&reads, CharacteristicKey(device, characteristic)) {
            if let error {
                return fail(id, HelperError(code: HelperErrorCode.readFailed, message: error.localizedDescription))
            }
            return succeed(id, ["data": .string((characteristic.value ?? Data()).base64EncodedString())])
        }
        if let error {
            return note("Meldung von \(characteristic.uuid.uuidString) mit Fehler: \(error.localizedDescription)")
        }
        guard characteristic.isNotifying, links[device]?.announced == true,
              let service = peripheral.services?.first(where: { service in
                  service.characteristics?.contains(where: { $0 === characteristic }) == true
              }),
              let serviceUuid = canonicalUuid(service.uuid.uuidString),
              let characteristicUuid = canonicalUuid(characteristic.uuid.uuidString) else { return }
        send(.event(.notification(device: device, service: serviceUuid, characteristic: characteristicUuid,
                                  data: characteristic.value ?? Data())))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let id = pop(&notifyChanges, CharacteristicKey(peripheral.identifier, characteristic)) else { return }
        if let error {
            // Ein Abo ist ein Schreibvorgang auf den Deskriptor des Merkmals.
            fail(id, HelperError(code: HelperErrorCode.writeFailed, message: error.localizedDescription))
        } else {
            succeed(id)
        }
    }
}

// MARK: - Zustand je Gerät

private struct Link {
    enum Phase { case connecting, discovering, ready, disconnecting }

    let peripheral: CBPeripheral
    var phase: Phase
    /// Offene `connect`-Befehle; sie warten auf Verbinden und vollständige Dienst-/Merkmalsuche.
    var connects: [Int]
    /// Offene `disconnect`-Befehle; sie warten auf `didDisconnect`.
    var disconnects: [Int] = []
    /// `connected` wurde gemeldet; nur dann folgt beim Trennen `disconnected`.
    var announced = false
    var servicesLeft = 0

    init(peripheral: CBPeripheral, phase: Phase, connects: [Int]) {
        self.peripheral = peripheral
        self.phase = phase
        self.connects = connects
    }
}

private struct ScanRun {
    let number: Int
    let request: Int
    /// Gerät → schon mit Namen gemeldet.
    var seen: [UUID: Bool] = [:]
}

private struct CharacteristicKey: Hashable {
    let device: UUID
    let characteristic: ObjectIdentifier

    init(_ device: UUID, _ characteristic: CBCharacteristic) {
        self.device = device
        self.characteristic = ObjectIdentifier(characteristic)
    }
}

private struct UnsentWrite {
    let id: Int
    let characteristic: CBCharacteristic
    let data: Data
}

private func stateName(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "unknown"
    }
}

private func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
    var names: [String] = []
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    return names
}
