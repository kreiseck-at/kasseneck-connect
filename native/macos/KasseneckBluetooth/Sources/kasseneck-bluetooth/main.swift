// Bluetooth-Hilfsprogramm von Kasseneck Connect: liest Befehle zeilenweise von stdin und schreibt Antworten und
// Ereignisse zeilenweise auf stdout (docs/bluetooth-protokoll.md). Auf stdout steht nie etwas anderes; Notizen gehen
// nach stderr. Endet stdin, ist der Agent weg – dann endet auch das Hilfsprogramm.
import BluetoothCore
import Darwin
import Dispatch
import Foundation

// Ein abgerissenes stdout soll das Programm sauber beenden statt per Signal.
signal(SIGPIPE, SIG_IGN)

/// Schreibt eine Zeile ungepuffert (also sofort beim Agenten); `false`, wenn die Gegenseite weg ist.
func writeLine(_ line: String, to fd: Int32) -> Bool {
    var bytes = Array(line.utf8)
    bytes.append(0x0A)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

let queue = DispatchQueue(label: "at.kasseneck.connect.bluetooth")
let central = Central(
    queue: queue,
    emit: { line in
        if !writeLine(line, to: STDOUT_FILENO) { exit(0) }
    },
    note: { text in
        _ = writeLine("kasseneck-bluetooth: \(text)", to: STDERR_FILENO)
    }
)

Thread {
    while let line = readLine(strippingNewline: true) {
        queue.async { central.handle(line: line) }
    }
    // Erst alles bis hierher Gelesene abarbeiten, dann gehen.
    queue.async { exit(0) }
}.start()

dispatchMain()
