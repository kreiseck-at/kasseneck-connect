/// Typisiertes Konfigurationsmodell des Agenten.
///
/// Alle `fromJson`-Fabriken sind bewusst tolerant: fehlende oder unbrauchbare
/// Felder fallen auf den Standardwert zurück, damit eine von Hand verpfuschte
/// oder ältere `config.json` den Agenten nicht am Start hindert.
library;

/// Aktuelle Schemaversion der `config.json`.
const int currentSchemaVersion = 1;

/// Standardport der lokalen API.
const int defaultAgentPort = 27182;

/// Standard-Update-Kanal.
const String defaultUpdateChannel = 'stable';

/// Anbindungsart eines Druckers.
enum PrinterKind {
  /// Roher Bytestrom über TCP 9100.
  tcp9100('tcp9100', 9100),

  /// Epson ePOS-Print über HTTP(S).
  epos('epos', 80);

  const PrinterKind(this.wireName, this.defaultPort);

  /// Bezeichner in JSON und API.
  final String wireName;

  /// Voreingestellter Port dieser Anbindung.
  final int defaultPort;

  /// Liest eine Anbindungsart; unbekannte Werte werden zu [tcp9100].
  static PrinterKind fromWireName(Object? value) {
    for (final kind in PrinterKind.values) {
      if (kind.wireName == value) return kind;
    }
    return PrinterKind.tcp9100;
  }
}

/// Ein konfigurierter Drucker.
class PrinterConfig {
  PrinterConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    int? port,
    this.devid,
  }) : port = port ?? kind.defaultPort;

  /// Stabile ID (wird vom Agenten vergeben).
  final String id;

  /// Anzeigename in der Kasse.
  final String name;

  final PrinterKind kind;

  /// IP oder Hostname.
  final String host;

  final int port;

  /// Geräte-ID für ePOS (`local_printer`), sonst `null`.
  final String? devid;

  PrinterConfig copyWith({
    String? id,
    String? name,
    PrinterKind? kind,
    String? host,
    int? port,
    String? devid,
  }) {
    return PrinterConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      devid: devid ?? this.devid,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'kind': kind.wireName,
    'host': host,
    'port': port,
    if (devid != null) 'devid': devid,
  };

  static PrinterConfig fromJson(Map<String, Object?> json) {
    final kind = PrinterKind.fromWireName(json['kind']);
    return PrinterConfig(
      id: readString(json['id']) ?? '',
      name: readString(json['name']) ?? '',
      kind: kind,
      host: readString(json['host']) ?? '',
      port: readInt(json['port']) ?? kind.defaultPort,
      devid: readString(json['devid']),
    );
  }

  @override
  String toString() => 'PrinterConfig($id, ${kind.wireName}, $host:$port)';
}

/// Ein konfiguriertes Zahlungsterminal (v1.1: `hobex`).
class TerminalConfig {
  TerminalConfig({
    this.kind = 'hobex',
    required this.host,
    this.port = 8080,
    this.tid,
  });

  final String kind;
  final String host;
  final int port;

  /// Terminal-ID, falls das Terminal mehrere führt.
  final String? tid;

  TerminalConfig copyWith({
    String? kind,
    String? host,
    int? port,
    String? tid,
  }) {
    return TerminalConfig(
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      tid: tid ?? this.tid,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'host': host,
    'port': port,
    if (tid != null) 'tid': tid,
  };

  static TerminalConfig fromJson(Map<String, Object?> json) => TerminalConfig(
    kind: readString(json['kind']) ?? 'hobex',
    host: readString(json['host']) ?? '',
    port: readInt(json['port']) ?? 8080,
    tid: readString(json['tid']),
  );

  @override
  String toString() => 'TerminalConfig($kind, $host:$port)';
}

/// Offener Kopplungsvorgang: Code, Ablauf, Fehlversuche, Sperre.
///
/// Der Code steht im Klartext in der Datei — er ist sechsstellig, zehn Minuten
/// gültig und steht ohnehin im Log bzw. auf der Konsole (`kasseneck-connect
/// pair`). Ein Hash brächte hier keine Sicherheit, verhinderte aber, dass ein
/// zweiter Prozess (CLI neben laufendem Agent) denselben Vorgang sieht.
class PairingState {
  const PairingState({
    this.code,
    this.expiresAt,
    this.failedAttempts = 0,
    this.lockedUntil,
  });

  /// Kein Vorgang offen.
  static const PairingState none = PairingState();

  /// Sechsstelliger Code, `null` wenn kein Vorgang offen ist.
  final String? code;

  /// Zeitpunkt, ab dem [code] nicht mehr gilt.
  final DateTime? expiresAt;

  /// Fehlversuche seit dem letzten gültigen Code.
  final int failedAttempts;

  /// Sperre nach zu vielen Fehlversuchen.
  final DateTime? lockedUntil;

  bool get isEmpty =>
      code == null &&
      expiresAt == null &&
      failedAttempts == 0 &&
      lockedUntil == null;

  PairingState copyWith({
    String? code,
    DateTime? expiresAt,
    int? failedAttempts,
    DateTime? lockedUntil,
    bool clearCode = false,
    bool clearLock = false,
  }) {
    return PairingState(
      code: clearCode ? null : (code ?? this.code),
      expiresAt: clearCode ? null : (expiresAt ?? this.expiresAt),
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockedUntil: clearLock ? null : (lockedUntil ?? this.lockedUntil),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (code != null) 'code': code,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    'failedAttempts': failedAttempts,
    if (lockedUntil != null) 'lockedUntil': lockedUntil!.toIso8601String(),
  };

  static PairingState fromJson(Map<String, Object?> json) => PairingState(
    code: readString(json['code']),
    expiresAt: readDateTime(json['expiresAt']),
    failedAttempts: readInt(json['failedAttempts']) ?? 0,
    lockedUntil: readDateTime(json['lockedUntil']),
  );

  @override
  String toString() =>
      'PairingState(${code == null ? 'kein Code' : 'Code offen'}, '
      '$failedAttempts Fehlversuche)';
}

/// Gesamte Konfiguration des Agenten (`config.json`).
class AgentConfig {
  AgentConfig({
    this.schemaVersion = currentSchemaVersion,
    this.port = defaultAgentPort,
    List<String>? tokenHashes,
    List<PrinterConfig>? printers,
    this.terminal,
    this.updateChannel = defaultUpdateChannel,
    this.pairing = PairingState.none,
  }) : tokenHashes = List<String>.unmodifiable(tokenHashes ?? const <String>[]),
       printers = List<PrinterConfig>.unmodifiable(
         printers ?? const <PrinterConfig>[],
       );

  final int schemaVersion;

  /// Port der lokalen API (Standard 27182, Fallback 27183–27189).
  final int port;

  /// SHA-256-Hashes der ausgegebenen Tokens — Klartext-Tokens werden nie gespeichert.
  final List<String> tokenHashes;

  final List<PrinterConfig> printers;

  final TerminalConfig? terminal;

  final String updateChannel;

  /// Offener Kopplungsvorgang (leer, wenn keiner läuft).
  final PairingState pairing;

  AgentConfig copyWith({
    int? schemaVersion,
    int? port,
    List<String>? tokenHashes,
    List<PrinterConfig>? printers,
    TerminalConfig? terminal,
    bool clearTerminal = false,
    String? updateChannel,
    PairingState? pairing,
  }) {
    return AgentConfig(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      port: port ?? this.port,
      tokenHashes: tokenHashes ?? this.tokenHashes,
      printers: printers ?? this.printers,
      terminal: clearTerminal ? null : (terminal ?? this.terminal),
      updateChannel: updateChannel ?? this.updateChannel,
      pairing: pairing ?? this.pairing,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'port': port,
    'tokenHashes': tokenHashes,
    'printers': printers.map((p) => p.toJson()).toList(),
    'terminal': terminal?.toJson(),
    'updateChannel': updateChannel,
    if (!pairing.isEmpty) 'pairing': pairing.toJson(),
  };

  static AgentConfig fromJson(Map<String, Object?> json) {
    final terminalJson = readMap(json['terminal']);
    final pairingJson = readMap(json['pairing']);
    return AgentConfig(
      pairing: pairingJson == null
          ? PairingState.none
          : PairingState.fromJson(pairingJson),
      schemaVersion: readInt(json['schemaVersion']) ?? currentSchemaVersion,
      port: readInt(json['port']) ?? defaultAgentPort,
      tokenHashes: readStringList(json['tokenHashes']),
      printers: readMapList(
        json['printers'],
      ).map(PrinterConfig.fromJson).toList(),
      terminal: terminalJson == null
          ? null
          : TerminalConfig.fromJson(terminalJson),
      updateChannel: readString(json['updateChannel']) ?? defaultUpdateChannel,
    );
  }

  @override
  String toString() =>
      'AgentConfig(v$schemaVersion, port $port, ${tokenHashes.length} Token, '
      '${printers.length} Drucker)';
}

/// Liest einen String, wenn der Wert einer ist.
String? readString(Object? value) => value is String ? value : null;

/// Liest eine ganze Zahl; akzeptiert auch numerische Strings.
int? readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Liest einen Zeitpunkt aus einer ISO-8601-Zeichenkette.
DateTime? readDateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

/// Liest eine Map mit String-Schlüsseln.
Map<String, Object?>? readMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, dynamic v) => MapEntry('$key', v as Object?));
  }
  return null;
}

/// Liest eine Liste von Strings; Fremdtypen werden übersprungen.
List<String> readStringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList();
}

/// Liest eine Liste von Maps; Fremdtypen werden übersprungen.
List<Map<String, Object?>> readMapList(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  final result = <Map<String, Object?>>[];
  for (final entry in value) {
    final map = readMap(entry);
    if (map != null) result.add(map);
  }
  return result;
}
