import '../config/model.dart';
import '../config/neuerungen.dart';

/// Fähigkeiten ab 1.5.0 (Spec 1.9) samt den Neuerungen, an denen sie hängen.
enum Faehigkeit {
  /// Kennung je Drucker (`identity`), `installationId`.
  identitaet('identity', <Neuerung>[Neuerung.druckerKennung]),

  /// `paper`, `cover`, `statusAt`, `POST /v1/printers/{id}/status`,
  /// `paper_out`, `cover_open`.
  druckerStatus('printer_status', <Neuerung>[Neuerung.druckerStatus]),

  /// Wiederfinden, `endpoint`, `locate` – an, solange eine der beiden
  /// Neuerungen an ist.
  wiederfinden('relocate', <Neuerung>[
    Neuerung.druckerWiederfinden,
    Neuerung.terminalWiederfinden,
  ]),

  /// Update- und Schlafsperre, `update_device_busy`, `terminal_busy`.
  betriebSperre('busy_lock', <Neuerung>[Neuerung.betriebSperre]),

  /// `GET /v1/diagnosis`.
  diagnose('diagnosis', <Neuerung>[]),

  /// `POST /v1/restart`.
  neustart('restart', <Neuerung>[]);

  const Faehigkeit(this.wireName, this.neuerungen);

  /// Name in `features`.
  final String wireName;

  /// Ohne Eintrag immer an; sonst an, solange eine davon an ist.
  final List<Neuerung> neuerungen;

  bool aktivIn(AgentConfig config) =>
      neuerungen.isEmpty || neuerungen.any(config.aktiv);
}
