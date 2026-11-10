/// Typisiertes Konfigurationsmodell des Agenten.
///
/// Alle `fromJson`-Fabriken sind bewusst tolerant: fehlende oder unbrauchbare
/// Felder fallen auf den Standardwert zurück, damit eine von Hand verpfuschte
/// oder ältere `config.json` den Agenten nicht am Start hindert.
library;

import '../bluetooth/uuids.dart';
import 'neuerungen.dart';

/// Aktuelle Schemaversion der `config.json`.
const int currentSchemaVersion = 1;

/// Standardport der lokalen API.
const int defaultAgentPort = 27182;

/// Standardport des HTTPS-Zugangs (Ausweich bis 27197). Eigene Portreihe,
/// damit HTTP auf 27182 ff. für bestehende Kassen unverändert bleibt.
const int defaultHttpsPort = 27190;

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

/// Woher die Kennung eines Druckers stammt (`identitySource`).
enum KennungsQuelle {
  /// TXT-Eintrag des mDNS-Dienstes.
  mdns('mdns'),

  /// Antwort auf `GS I` über TCP 9100.
  escpos('escpos'),

  /// Geräteinfo über ePOS.
  epos('epos'),

  /// MAC-Adresse aus der ARP-Tabelle.
  arp('arp');

  const KennungsQuelle(this.wireName);

  final String wireName;

  static KennungsQuelle? fromWireName(Object? value) {
    for (final quelle in values) {
      if (quelle.wireName == value) return quelle;
    }
    return null;
  }
}

/// Ein konfigurierter Drucker.
///
/// Ab 1.5.0 trägt er seine Kennung (Modell, Seriennummer, MAC). Kennung ist
/// die Seriennummer, sonst die MAC; das Modell allein ist keine, denn zwei
/// gleiche Drucker in einem Laden sind üblich.
class PrinterConfig {
  PrinterConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    int? port,
    this.devid,
    this.model,
    this.modelSource,
    this.serial,
    this.mac,
    this.identifiedAt,
    this.identitySource,
    this.statusCapableAt,
    Map<String, Object?>? extras,
  }) : port = port ?? kind.defaultPort,
       extras = Map<String, Object?>.unmodifiable(
         extras ?? const <String, Object?>{},
       );

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

  /// Modellname, wie das Gerät ihn nennt (`TM-m30III`).
  final String? model;

  /// Woher [model] stammt. Nur ein über `GS I 67` gelesenes Modell
  /// ([KennungsQuelle.escpos]) kann ein im Gerätetest bewiesenes sein
  /// (`printers/bewiesen.dart`).
  final KennungsQuelle? modelSource;

  /// Seriennummer aus `GS I 68` oder mDNS.
  final String? serial;

  /// MAC-Adresse, klein mit Doppelpunkten (`00:26:ab:00:00:01`).
  final String? mac;

  /// Wann die Kennung ermittelt wurde.
  final DateTime? identifiedAt;

  /// Woher die Kennung stammt.
  final KennungsQuelle? identitySource;

  /// Seit wann der Drucker nachweislich auf `DLE EOT` antwortet. Schweigt ein
  /// solcher Drucker, ist er nicht bereit (Gerätetest TM-T20III: mit offenem
  /// Deckel oder ohne Papier beantwortet er `DLE EOT` gar nicht) – bei einem,
  /// der nie geantwortet hat, heißt Schweigen nur „unbekannt“.
  final DateTime? statusCapableAt;

  /// Felder, die diese Fassung nicht kennt (aus einer neueren Fassung); sie
  /// überleben das Schreiben unverändert.
  final Map<String, Object?> extras;

  /// Ob der Drucker eine Kennung hat (Seriennummer oder MAC).
  bool get hatKennung => serial != null || mac != null;

  PrinterConfig copyWith({
    String? id,
    String? name,
    PrinterKind? kind,
    String? host,
    int? port,
    String? devid,
    String? model,
    KennungsQuelle? modelSource,
    String? serial,
    String? mac,
    DateTime? identifiedAt,
    KennungsQuelle? identitySource,
    DateTime? statusCapableAt,
  }) {
    return PrinterConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      devid: devid ?? this.devid,
      model: model ?? this.model,
      modelSource: modelSource ?? this.modelSource,
      serial: serial ?? this.serial,
      mac: mac ?? this.mac,
      identifiedAt: identifiedAt ?? this.identifiedAt,
      identitySource: identitySource ?? this.identitySource,
      statusCapableAt: statusCapableAt ?? this.statusCapableAt,
      extras: extras,
    );
  }

  /// Die Felder, die schon 1.4.2 an die Kasse gab – unverändert in Form und
  /// Reihenfolge (`GET /v1/printers`, `PUT /v1/printers`, Status).
  Map<String, Object?> toApiJson() => <String, Object?>{
    'id': id,
    'name': name,
    'kind': kind.wireName,
    'host': host,
    'port': port,
    if (devid != null) 'devid': devid,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    ...extras,
    ...toApiJson(),
    if (model != null) 'model': model,
    if (modelSource != null) 'modelSource': modelSource!.wireName,
    if (serial != null) 'serial': serial,
    if (mac != null) 'mac': mac,
    if (identifiedAt != null)
      'identifiedAt': identifiedAt!.toUtc().toIso8601String(),
    if (identitySource != null) 'identitySource': identitySource!.wireName,
    if (statusCapableAt != null)
      'statusCapableAt': statusCapableAt!.toUtc().toIso8601String(),
  };

  static const Set<String> _bekannteFelder = <String>{
    'id',
    'name',
    'kind',
    'host',
    'port',
    'devid',
    'model',
    'modelSource',
    'serial',
    'mac',
    'identifiedAt',
    'identitySource',
    'statusCapableAt',
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
      model: _kennungsText(json['model']),
      modelSource: KennungsQuelle.fromWireName(json['modelSource']),
      serial: _kennungsText(json['serial']),
      mac: normalizeMac(readString(json['mac'])),
      identifiedAt: readDateTime(json['identifiedAt'])?.toUtc(),
      identitySource: KennungsQuelle.fromWireName(json['identitySource']),
      statusCapableAt: readDateTime(json['statusCapableAt'])?.toUtc(),
      extras: _unbekannte(json, _bekannteFelder),
    );
  }

  @override
  String toString() => 'PrinterConfig($id, ${kind.wireName}, $host:$port)';
}

/// Ein konfiguriertes Zahlungsterminal (v1.1: `hobex`).
///
/// Der Agent merkt es sich beim ersten erfolgreichen Kontakt (Wachhalten).
/// Ab 1.5.0 mit TID und dem Zeitpunkt, zu dem eine Antwort des Terminals diese
/// TID unter dieser Adresse zuletzt bestätigt hat – nur eine bestätigte Adresse
/// darf Ziel einer Umleitung sein.
class TerminalConfig {
  TerminalConfig({
    this.kind = 'hobex',
    required this.host,
    this.port = 8080,
    this.tid,
    this.mac,
    this.confirmedAt,
    this.serial,
    Map<String, Object?>? extras,
  }) : extras = Map<String, Object?>.unmodifiable(
         extras ?? const <String, Object?>{},
       );

  final String kind;
  final String host;
  final int port;

  /// Terminal-ID, falls das Terminal mehrere führt.
  final String? tid;

  /// MAC-Adresse des Terminals, klein mit Doppelpunkten.
  final String? mac;

  /// Wann eine Antwort des Terminals [tid] unter [host]:[port] zuletzt
  /// bestätigt hat.
  final DateTime? confirmedAt;

  /// Seriennummer des Terminals (`sn` der Diagnose); zusätzliche Kennung.
  final String? serial;

  /// Felder einer neueren Fassung; sie überleben das Schreiben.
  final Map<String, Object?> extras;

  TerminalConfig copyWith({
    String? kind,
    String? host,
    int? port,
    String? tid,
    String? mac,
    DateTime? confirmedAt,
    String? serial,
  }) {
    return TerminalConfig(
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      tid: tid ?? this.tid,
      mac: mac ?? this.mac,
      confirmedAt: confirmedAt ?? this.confirmedAt,
      serial: serial ?? this.serial,
      extras: extras,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...extras,
    'kind': kind,
    'host': host,
    'port': port,
    if (tid != null) 'tid': tid,
    if (mac != null) 'mac': mac,
    if (confirmedAt != null)
      'confirmedAt': confirmedAt!.toUtc().toIso8601String(),
    if (serial != null) 'serial': serial,
  };

  static const Set<String> _bekannteFelder = <String>{
    'kind',
    'host',
    'port',
    'tid',
    'mac',
    'confirmedAt',
    'serial',
  };

  static TerminalConfig fromJson(Map<String, Object?> json) => TerminalConfig(
    kind: readString(json['kind']) ?? 'hobex',
    host: readString(json['host']) ?? '',
    port: readInt(json['port']) ?? 8080,
    tid: readString(json['tid']),
    mac: normalizeMac(readString(json['mac'])),
    confirmedAt: readDateTime(json['confirmedAt'])?.toUtc(),
    serial: _kennungsText(json['serial']),
    extras: _unbekannte(json, _bekannteFelder),
  );

  @override
  String toString() => 'TerminalConfig($kind, $host:$port)';
}

/// Art eines Eintrags in `relocations` ([AdressWechsel]).
enum GeraeteArt {
  /// Ein Drucker ist unter eine neue Adresse gezogen (`from`/`to`: Adressen).
  drucker('printer'),

  /// Das Terminal ist unter eine neue Adresse gezogen.
  terminal('terminal'),

  /// Unter der Adresse eines Druckers steht dauerhaft ein anderer, und der
  /// alte ist nirgends zu finden: Connect hat die Kennung übernommen
  /// (`from`/`to`: alte und neue Seriennummer, die Adresse bleibt).
  ersetzt('replaced');

  const GeraeteArt(this.wireName);

  final String wireName;

  static GeraeteArt? fromWireName(Object? value) {
    for (final art in values) {
      if (art.wireName == value) return art;
    }
    return null;
  }
}

/// Wie viele Adresswechsel die `config.json` aufhebt (Diagnose: „die letzten
/// 20“). Mehr hilft dem Support nicht, und die Datei soll klein bleiben.
const int adressWechselLimit = 20;

/// Ein stiller Adresswechsel eines Druckers oder Terminals (`relocations`).
///
/// Nur für Log und Diagnose; die Kasse zeigt ihn nie.
class AdressWechsel {
  const AdressWechsel({
    required this.at,
    required this.art,
    required this.kennung,
    required this.von,
    required this.nach,
  });

  final DateTime at;
  final GeraeteArt art;

  /// Drucker-ID bzw. TID.
  final String kennung;

  /// Alte und neue Adresse (`host:port`); bei [GeraeteArt.ersetzt] alte und
  /// neue Seriennummer.
  final String von;
  final String nach;

  /// Form in `config.json` und Diagnose – englisch wie das Ereignis
  /// `printer.relocated` (`kind`, `from`, `to`).
  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'kind': art.wireName,
    if (art == GeraeteArt.terminal) 'tid': kennung else 'id': kennung,
    'from': von,
    'to': nach,
  };

  /// `null` bei einem unbrauchbaren Eintrag (er wird übersprungen).
  static AdressWechsel? fromJson(Map<String, Object?> json) {
    final at = readDateTime(json['at']);
    final art = GeraeteArt.fromWireName(json['kind']);
    final von = readString(json['from']);
    final nach = readString(json['to']);
    if (at == null || art == null || von == null || nach == null) return null;
    final kennung = readString(
      art == GeraeteArt.terminal ? json['tid'] : json['id'],
    );
    if (kennung == null) return null;
    return AdressWechsel(
      at: at.toUtc(),
      art: art,
      kennung: kennung,
      von: von,
      nach: nach,
    );
  }
}

/// Ein vom Kunden zugelassenes Bluetooth-Gerät (Waage, Lesegerät …).
///
/// Nur zugelassene Geräte darf die Kasse über die Brücke ansprechen; die
/// Kennung ist die CoreBluetooth-UUID des Geräts auf diesem Rechner.
class BluetoothDeviceConfig {
  BluetoothDeviceConfig({
    required String id,
    required this.name,
    required this.approvedAt,
  }) : id = id.toLowerCase();

  /// CoreBluetooth-Kennung, immer klein geschrieben.
  final String id;

  /// Name aus dem Scan; fehlt er, steht hier die Kennung.
  final String name;

  /// Zeitpunkt der Zulassung.
  final DateTime approvedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'approvedAt': approvedAt.toUtc().toIso8601String(),
  };

  /// Liest einen Eintrag; `null` bei ungültiger Kennung oder fehlendem bzw.
  /// kaputtem Zeitpunkt (der Eintrag wird dann beim Laden übersprungen).
  static BluetoothDeviceConfig? fromJson(Map<String, Object?> json) {
    final id = readString(json['id']);
    if (id == null || !isValidDeviceId(id)) return null;
    final approvedAt = readDateTime(json['approvedAt']);
    if (approvedAt == null) return null;
    final name = readString(json['name']);
    return BluetoothDeviceConfig(
      id: id,
      // Unbenannte Geräte melden im Scan keinen Namen.
      name: (name == null || name.isEmpty) ? id.toLowerCase() : name,
      approvedAt: approvedAt.toUtc(),
    );
  }

  @override
  String toString() => 'BluetoothDeviceConfig($id, $name)';
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
///
/// Felder, die diese Fassung nicht kennt (geschrieben von einer neueren),
/// stehen in [extras] und gehen beim Schreiben unverändert mit – sonst
/// löschte ein Zurückgehen auf eine ältere Fassung sie beim nächsten Speichern.
class AgentConfig {
  AgentConfig({
    this.schemaVersion = currentSchemaVersion,
    this.port = defaultAgentPort,
    this.httpsPort = defaultHttpsPort,
    List<String>? tokenHashes,
    List<PrinterConfig>? printers,
    this.terminal,
    this.updateChannel = defaultUpdateChannel,
    this.pairing = PairingState.none,
    this.allowDevOrigins = false,
    List<BluetoothDeviceConfig>? bluetoothDevices,
    this.installationId,
    List<String>? disabledFeatures,
    List<AdressWechsel>? relocations,
    Map<String, Object?>? extras,
  }) : tokenHashes = List<String>.unmodifiable(tokenHashes ?? const <String>[]),
       printers = List<PrinterConfig>.unmodifiable(
         printers ?? const <PrinterConfig>[],
       ),
       bluetoothDevices = List<BluetoothDeviceConfig>.unmodifiable(
         bluetoothDevices ?? const <BluetoothDeviceConfig>[],
       ),
       disabledFeatures = List<String>.unmodifiable(
         disabledFeatures ?? const <String>[],
       ),
       relocations = List<AdressWechsel>.unmodifiable(
         relocations ?? const <AdressWechsel>[],
       ),
       extras = Map<String, Object?>.unmodifiable(
         extras ?? const <String, Object?>{},
       );

  final int schemaVersion;

  /// Port der lokalen API (Standard 27182, Fallback 27183–27189).
  final int port;

  /// Port des HTTPS-Zugangs (Standard 27190, Fallback 27191–27197); der
  /// Agent merkt sich hier, wo er zuletzt lauschte.
  final int httpsPort;

  /// SHA-256-Hashes der ausgegebenen Tokens — Klartext-Tokens werden nie gespeichert.
  final List<String> tokenHashes;

  final List<PrinterConfig> printers;

  final TerminalConfig? terminal;

  final String updateChannel;

  /// Offener Kopplungsvorgang (leer, wenn keiner läuft).
  final PairingState pairing;

  /// Lässt zusätzlich `http://localhost:<port>` und `http://127.0.0.1:<port>`
  /// als Herkunft zu — nur für die Entwicklung der Kasse.
  ///
  /// Standard `false`: auf einem Kundenrechner darf keine beliebige lokale
  /// Webseite den Agenten ansprechen.
  final bool allowDevOrigins;

  /// Zugelassene Bluetooth-Geräte (Obergrenze prüft die Brücke, nicht das Modell).
  final List<BluetoothDeviceConfig> bluetoothDevices;

  /// Kennung dieser Installation (UUID v4), beim ersten Start erzeugt und nie
  /// geändert. Die Kasse erkennt daran, mit welchem Connect sie spricht.
  final String? installationId;

  /// Abgeschaltete Neuerungen (Namen aus [Neuerung]); unbekannte Namen
  /// bleiben stehen, damit eine neuere Fassung sie wiederfindet.
  final List<String> disabledFeatures;

  /// Die letzten stillen Adresswechsel (höchstens [adressWechselLimit]).
  final List<AdressWechsel> relocations;

  /// Felder einer neueren Fassung (siehe Klassenbeschreibung).
  final Map<String, Object?> extras;

  /// Ob [neuerung] eingeschaltet ist (Vorgabe: ja).
  bool aktiv(Neuerung neuerung) =>
      !disabledFeatures.contains(neuerung.wireName);

  AgentConfig copyWith({
    int? schemaVersion,
    int? port,
    int? httpsPort,
    List<String>? tokenHashes,
    List<PrinterConfig>? printers,
    TerminalConfig? terminal,
    bool clearTerminal = false,
    String? updateChannel,
    PairingState? pairing,
    bool? allowDevOrigins,
    List<BluetoothDeviceConfig>? bluetoothDevices,
    String? installationId,
    List<String>? disabledFeatures,
    List<AdressWechsel>? relocations,
  }) {
    return AgentConfig(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      port: port ?? this.port,
      httpsPort: httpsPort ?? this.httpsPort,
      tokenHashes: tokenHashes ?? this.tokenHashes,
      printers: printers ?? this.printers,
      terminal: clearTerminal ? null : (terminal ?? this.terminal),
      updateChannel: updateChannel ?? this.updateChannel,
      pairing: pairing ?? this.pairing,
      allowDevOrigins: allowDevOrigins ?? this.allowDevOrigins,
      bluetoothDevices: bluetoothDevices ?? this.bluetoothDevices,
      installationId: installationId ?? this.installationId,
      disabledFeatures: disabledFeatures ?? this.disabledFeatures,
      relocations: relocations ?? this.relocations,
      extras: extras,
    );
  }

  /// Hängt [wechsel] an die Adresswechsel und behält die letzten
  /// [adressWechselLimit].
  AgentConfig mitAdressWechsel(AdressWechsel wechsel) {
    final liste = <AdressWechsel>[...relocations, wechsel];
    final rest = liste.length > adressWechselLimit
        ? liste.sublist(liste.length - adressWechselLimit)
        : liste;
    return copyWith(relocations: rest);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...extras,
    'schemaVersion': schemaVersion,
    if (installationId != null) 'installationId': installationId,
    'port': port,
    'httpsPort': httpsPort,
    'tokenHashes': tokenHashes,
    'printers': printers.map((p) => p.toJson()).toList(),
    'terminal': terminal?.toJson(),
    'updateChannel': updateChannel,
    if (!pairing.isEmpty) 'pairing': pairing.toJson(),
    'allowDevOrigins': allowDevOrigins,
    'bluetoothDevices': bluetoothDevices.map((d) => d.toJson()).toList(),
    if (disabledFeatures.isNotEmpty) 'disabledFeatures': disabledFeatures,
    if (relocations.isNotEmpty)
      'relocations': relocations.map((r) => r.toJson()).toList(),
  };

  static const Set<String> _bekannteFelder = <String>{
    'schemaVersion',
    'installationId',
    'port',
    'httpsPort',
    'tokenHashes',
    'printers',
    'terminal',
    'updateChannel',
    'pairing',
    'allowDevOrigins',
    'bluetoothDevices',
    'disabledFeatures',
    'relocations',
  };

  static AgentConfig fromJson(Map<String, Object?> json) {
    final terminalJson = readMap(json['terminal']);
    final pairingJson = readMap(json['pairing']);
    final installationId = readString(json['installationId']);
    return AgentConfig(
      pairing: pairingJson == null
          ? PairingState.none
          : PairingState.fromJson(pairingJson),
      allowDevOrigins: json['allowDevOrigins'] == true,
      schemaVersion: readInt(json['schemaVersion']) ?? currentSchemaVersion,
      // Port 0 (freier Port vom System) ist nur programmatisch sinnvoll; aus
      // der Datei gelesen wäre er ein Fehler und ergäbe bei jedem Start einen
      // anderen Port, den die Kasse nicht findet.
      port: _readPort(json['port']),
      httpsPort: _readPort(json['httpsPort'], fallback: defaultHttpsPort),
      tokenHashes: readStringList(json['tokenHashes']),
      printers: readMapList(
        json['printers'],
      ).map(PrinterConfig.fromJson).toList(),
      terminal: terminalJson == null
          ? null
          : TerminalConfig.fromJson(terminalJson),
      updateChannel: readString(json['updateChannel']) ?? defaultUpdateChannel,
      bluetoothDevices: readMapList(
        json['bluetoothDevices'],
      ).map(BluetoothDeviceConfig.fromJson).nonNulls.toList(),
      // Eine von Hand verdorbene Kennung gilt als fehlend; der Agent erzeugt
      // dann beim Start eine neue.
      installationId: installationId != null && isInstallationId(installationId)
          ? installationId.toLowerCase()
          : null,
      disabledFeatures: readStringList(json['disabledFeatures']),
      relocations: readMapList(
        json['relocations'],
      ).map(AdressWechsel.fromJson).nonNulls.toList(),
      extras: _unbekannte(json, _bekannteFelder),
    );
  }

  @override
  String toString() =>
      'AgentConfig(v$schemaVersion, port $port, https $httpsPort, '
      '${tokenHashes.length} Token, '
      '${printers.length} Drucker)';
}

/// Form einer Installationskennung (UUID, klein oder groß geschrieben).
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// Ob [value] eine brauchbare Installationskennung ist.
bool isInstallationId(String value) => _uuid.hasMatch(value);

/// Längste Kennungsangabe (Modell, Seriennummer), die gespeichert wird. Längeres
/// ist keine ordentliche Antwort eines Geräts.
const int kennungsTextMaxLength = 64;

String? _kennungsText(Object? value) {
  final text = readString(value)?.trim();
  if (text == null || text.isEmpty || text.length > kennungsTextMaxLength) {
    return null;
  }
  return text;
}

/// MAC-Adresse in der festen Schreibweise `00:26:ab:00:00:01`.
///
/// macOS lässt führende Nullen weg (`0:26:ab:0:0:1`), Windows trennt mit
/// Bindestrichen – verglichen wird nur die einheitliche Form. Unsinn, die
/// Rundsende-Adresse und die Null-Adresse ergeben `null`.
String? normalizeMac(String? value) {
  if (value == null) return null;
  final teile = value.trim().split(RegExp('[:-]'));
  if (teile.length != 6) return null;
  final normiert = <String>[];
  for (final teil in teile) {
    if (!RegExp(r'^[0-9a-fA-F]{1,2}$').hasMatch(teil)) return null;
    normiert.add(teil.toLowerCase().padLeft(2, '0'));
  }
  final mac = normiert.join(':');
  if (mac == 'ff:ff:ff:ff:ff:ff' || mac == '00:00:00:00:00:00') return null;
  return mac;
}

/// Die Felder aus [json], die nicht in [bekannt] stehen.
Map<String, Object?> _unbekannte(
  Map<String, Object?> json,
  Set<String> bekannt,
) => <String, Object?>{
  for (final eintrag in json.entries)
    if (!bekannt.contains(eintrag.key)) eintrag.key: eintrag.value,
};

/// Liest einen Port aus der Datei; 0 oder Unsinn ergibt [fallback].
int _readPort(Object? value, {int fallback = defaultAgentPort}) {
  final port = readInt(value);
  if (port == null || port <= 0 || port > 65535) return fallback;
  return port;
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
