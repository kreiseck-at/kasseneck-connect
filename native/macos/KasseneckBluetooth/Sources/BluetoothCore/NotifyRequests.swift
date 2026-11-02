// Offene `subscribe`/`unsubscribe` eines Merkmals.
//
// CoreBluetooth meldet `didUpdateNotificationStateFor` nur sicher für einen echten Wechsel. Ein zweiter Aufruf mit
// demselben Ziel, solange der erste noch läuft, bliebe womöglich ohne Rückmeldung – sein Befehl hinge dann, und
// jede spätere Rückmeldung beantwortete den falschen Befehl. Deshalb Gruppen je Ziel: Ein Wunsch mit demselben Ziel
// wie die letzte offene Gruppe schließt sich ihr an (ohne neuen Aufruf), jede Rückmeldung beantwortet genau die
// älteste Gruppe. Unveränderlich: je Gruppe genau ein `setNotifyValue`, benachbarte Gruppen haben verschiedene
// Ziele, jede `id` steht genau einmal hier oder ist schon beantwortet (beim Trennen über `allIds`).

/// Wünsche für ein Merkmal in der Reihenfolge, in der CoreBluetooth sie bestätigt.
public struct NotifyRequests {
    public enum Action: Equatable {
        /// Der Zustand steht schon und nichts läuft: sofort `{}`, nichts gespeichert.
        case answerNow
        /// Neue Gruppe: jetzt `setNotifyValue` aufrufen.
        case callSetNotify
        /// Angeschlossen an die letzte Gruppe mit demselben Ziel: auf deren Bestätigung warten.
        case wait
    }

    private var groups: [(ids: [Int], enabled: Bool)] = []

    public init() {}

    public var isEmpty: Bool { groups.isEmpty }

    /// Alle noch offenen `id`s, älteste zuerst (für das Trennen).
    public var allIds: [Int] { groups.flatMap(\.ids) }

    /// Nimmt einen Wunsch an; `current` ist `isNotifying` des Merkmals.
    public mutating func add(_ id: Int, enabled: Bool, current: Bool) -> Action {
        guard let last = groups.indices.last else {
            if current == enabled { return .answerNow }
            groups.append((ids: [id], enabled: enabled))
            return .callSetNotify
        }
        if groups[last].enabled == enabled {
            groups[last].ids.append(id)
            return .wait
        }
        groups.append((ids: [id], enabled: enabled))
        return .callSetNotify
    }

    /// CoreBluetooth hat einen Wechsel gemeldet: die `id`s der ältesten Gruppe (leer, wenn nichts offen war).
    public mutating func confirm() -> [Int] {
        groups.isEmpty ? [] : groups.removeFirst().ids
    }
}
