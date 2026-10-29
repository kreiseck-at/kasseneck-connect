import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'api/context.dart';
import 'api/routes_bluetooth.dart';
import 'api/routes_events.dart';
import 'api/routes_printers.dart';
import 'api/routes_terminal.dart';
import 'api/server.dart';
import 'bluetooth/bridge.dart';
import 'bluetooth/helper.dart';
import 'config/model.dart';
import 'config/store.dart';
import 'events/bus.dart';
import 'log/logger.dart';
import 'pairing/pairing.dart';
import 'printers/discovery.dart';
import 'printers/queue.dart';
import 'printers/registry.dart';
import 'process_runner.dart';
import 'terminal/warmhalten.dart';
import 'tls/certificates.dart';
import 'tls/trust.dart';
import 'version.dart';

/// Wie viele Ports der Agent ab dem Wunschport durchprobiert
/// (HTTP 27182 … 27189, HTTPS 27190 … 27197).
const int portFallbackRange = 8;

/// So lange darf das höfliche Schließen dauern, bevor hart geschlossen wird.
const Duration gracefulStopTimeout = Duration(seconds: 2);

/// Wie oft der Agent die Zertifikate prüft (und bei Bedarf erneuert). Dazu
/// kommt die Prüfung bei jedem Start; erneuert wird 30 Tage vor Ablauf, ein
/// Tag Takt reicht also auch, wenn der Rechner viel schläft.
const Duration tlsCheckPeriod = Duration(days: 1);

/// So lange gilt die Antwort auf „vertraut?“ für den Status: die Kasse fragt
/// ihn bei jedem Laden, `security` soll nicht jedes Mal laufen.
const Duration trustCacheDuration = Duration(minutes: 1);

/// Der laufende Agent: lokaler HTTP-Server auf 127.0.0.1 samt Kopplung, am
/// Mac zusätzlich ein HTTPS-Zugang mit derselben Anfragekette.
///
/// Gebunden wird ausschließlich die Loopback-Adresse — aus dem LAN ist der
/// Agent damit gar nicht erreichbar.
class Agent {
  Agent({
    required this.store,
    required this.log,
    this.preferredPort = defaultAgentPort,
    DateTime Function()? clock,
    Pairing? pairing,
    List<RouteRegistrar> extraRoutes = const <RouteRegistrar>[],
    bool? openBrowser,
    Map<String, String>? environment,
    EventBus? events,
    PrinterRegistry? registry,
    PrintQueue? queue,
    PrinterDiscovery? discovery,
    BluetoothHelper? bluetoothHelper,
    this.https = false,
    this.preferredHttpsPort = defaultHttpsPort,
    this.tlsCheckInterval = tlsCheckPeriod,
    ProcessRunner? runProcess,
    ProcessStarter? startProcess,
    LocalCertificates? certificates,
  }) : _clock = clock ?? DateTime.now,
       _pairing = pairing,
       _extraRoutes = extraRoutes,
       _openBrowser = openBrowser,
       _environment = environment,
       _events = events,
       _registry = registry,
       _queue = queue,
       _discovery = discovery,
       _bluetoothHelper = bluetoothHelper,
       _startProcess =
           startProcess ??
           (runProcess == null
               ? Process.start
               : processStarterFrom(runProcess)),
       _certificates =
           certificates ??
           LocalCertificates(
             directory: store.paths.directory,
             run: runProcess ?? Process.run,
             log: log,
           );

  final ConfigStore store;
  final AgentLog log;

  /// Wunschport; von dort an wird bis [portFallbackRange] Ports weit gesucht.
  /// `0` bindet einen freien Port des Systems (Tests).
  final int preferredPort;

  /// Zweiter Zugang über HTTPS — Safari lässt eine Seite unter `https://`
  /// nicht an `http://127.0.0.1`. Bisher nur am Mac; `run` schaltet ihn dort
  /// ein. Standard aus: Tests und andere Einbettungen binden so nie 27190 und
  /// fragen nie den Schlüsselbund.
  final bool https;

  /// Wunschport des HTTPS-Zugangs, Suche wie bei [preferredPort].
  final int preferredHttpsPort;

  /// Takt der Zertifikatsprüfung ([checkTls]); im Test kürzer.
  final Duration tlsCheckInterval;

  final DateTime Function() _clock;
  final Pairing? _pairing;
  final List<RouteRegistrar> _extraRoutes;
  final bool? _openBrowser;
  final Map<String, String>? _environment;
  final EventBus? _events;
  final PrinterRegistry? _registry;
  final PrintQueue? _queue;
  final PrinterDiscovery? _discovery;

  /// Zugang zum Bluetooth-Hilfsprogramm; ohne ihn der dieses Rechners
  /// ([platformBluetoothHelper]). [stop] beendet ihn – auch einen
  /// hereingereichten: ein Hilfsprogramm ohne Agenten hielte nur Geräte fest.
  final BluetoothHelper? _bluetoothHelper;

  /// Für `security verify-cert` (Vertrauen): mit Zeitgrenze, ein hängender
  /// Aufruf wird beendet. Ohne eigenen Starter, aber mit eigenem Runner
  /// (Tests) läuft er über den Runner — nie am System vorbei.
  final ProcessStarter _startProcess;

  /// Genau eine Instanz je Agent: sie hält die Sperrdatei der Zertifikate.
  /// Ein zweiter Prozess (`zertifikat-vertrauen`) hat seine eigene; die
  /// Sperre ordnet beide.
  final LocalCertificates _certificates;

  HttpServer? _server;
  Handler? _handler;

  /// HTTPS-Zugang samt der Kette, mit der er gebunden ist — daran erkennt
  /// [checkTls] ein erneuertes Serverzertifikat oder eine neue Stelle.
  HttpServer? _httpsServer;
  List<int>? _httpsChain;
  TlsFiles? _tlsFiles;
  Timer? _tlsTimer;
  Future<void>? _tlsCheck;
  bool? _trusted;
  DateTime? _trustCheckedAt;

  AgentContext? _context;
  TerminalWarmhalter? _warmhalter;
  PrinterRegistry? _printers;
  BluetoothBridge? _bluetooth;
  List<RouteRegistrar> _routes = const <RouteRegistrar>[];

  /// Ob der Bus dem Agenten gehört. Einen von außen hereingereichten Bus
  /// (Tests, spätere Etappen) darf [stop] nicht schließen — der Besitzer
  /// entscheidet über sein Lebensende.
  bool _ownsEvents = false;

  /// Druckerverwaltung des laufenden Agenten (erst nach [start] gültig).
  PrinterRegistry get printers {
    final registry = _printers;
    if (registry == null) {
      throw StateError('Der Agent läuft nicht — zuerst start() aufrufen.');
    }
    return registry;
  }

  /// Ereignisbus des laufenden Agenten (erst nach [start] gültig).
  EventBus get events => context.events;

  /// Port, auf dem der Agent tatsächlich lauscht (erst nach [start] gültig).
  int get port => _server?.port ?? 0;

  /// Port des HTTPS-Zugangs; `null`, solange er nicht lauscht.
  int? get httpsPort => _httpsServer?.port;

  /// Zustand für die Endpunkte (erst nach [start] gültig).
  AgentContext get context {
    final ctx = _context;
    if (ctx == null) {
      throw StateError('Der Agent läuft nicht — zuerst start() aufrufen.');
    }
    return ctx;
  }

  /// Startet den Server, merkt sich den Port und stößt bei Bedarf die
  /// Kopplung an (Code erzeugen, loggen, Browser öffnen).
  Future<void> start() async {
    if (_server != null) return;

    // Der Druckstapel gehört zum Agenten: Registry, Warteschlange und Suche
    // hängen alle am selben Ereignisbus, den A4 an `/v1/events` weiterreicht.
    final bus = _events ?? EventBus();
    _ownsEvents = _events == null;
    final registry =
        _registry ?? PrinterRegistry(store: store, log: log, events: bus);
    final queue =
        _queue ?? PrintQueue(registry: registry, events: bus, log: log);
    _printers = registry;

    // Die Brücke steht ab hier, Bluetooth selbst startet erst mit dem ersten
    // Gerätezugriff bzw. der ersten Suche: der Start des Agenten (Anmeldung,
    // Autostart) soll macOS nie nach der Bluetooth-Freigabe fragen lassen.
    final bluetooth = BluetoothBridge(
      store: store,
      log: log,
      events: bus,
      helper:
          _bluetoothHelper ??
          platformBluetoothHelper(log, environment: _environment),
    );
    _bluetooth = bluetooth;

    final ctx = AgentContext(
      store: store,
      log: log,
      startedAt: _clock(),
      clock: _clock,
      pairing: _pairing,
      events: bus,
      printers: registry.summaries,
      environment: _environment,
      bluetooth: bluetooth,
    );
    _context = ctx;
    _warmhalter = TerminalWarmhalter(store: store, log: log);
    _warmhalter!.startAus(await store.load());
    _routes = <RouteRegistrar>[
      eventRoutes(),
      terminalRoutes(warmhalter: _warmhalter),
      printerRoutes(
        registry: registry,
        queue: queue,
        discovery: _discovery ?? PrinterDiscovery(log: log),
      ),
      bluetoothRoutes(bridge: bluetooth),
      ..._extraRoutes,
    ];

    // Eine Anfragekette für beide Zugänge: Herkunft, Token und Routen gelten
    // über HTTPS genauso wie über HTTP.
    _handler = buildHandler(
      ctx,
      extraRoutes: _routes,
      environment: _environment,
    );
    final server = await _bind(preferredPort);
    _server = server;
    ctx.port = server.port;
    log.info(
      '$agentName $agentVersion lauscht auf http://127.0.0.1:${server.port}',
    );

    final config = await store.load();
    if (config.port != server.port) {
      await store.mutate((current) => current.copyWith(port: server.port));
    }

    if (https) {
      await _startHttps();
      _tlsTimer = Timer.periodic(
        tlsCheckInterval,
        (_) => unawaited(checkTls()),
      );
    }

    if (config.tokenHashes.isEmpty) {
      final code = await ctx.pairing.newCode();
      log.info('Kopplungscode $code (10 Minuten gültig).');
      if (_openBrowser ?? true) {
        await ctx.pairing.openPairingPage(code, server.port);
      }
    }
  }

  /// Hält den Server an: erst höflich (laufende Anfragen dürfen zu Ende
  /// gehen), nach [gracefulStopTimeout] mit Nachdruck.
  Future<void> stop() async {
    _warmhalter?.stop();
    _tlsTimer?.cancel();
    _tlsTimer = null;
    // Eine laufende Zertifikatsprüfung zu Ende gehen lassen: sie bände sonst
    // womöglich einen HTTPS-Zugang neu, nachdem hier alles zu ist.
    final pendingCheck = _tlsCheck;
    if (pendingCheck != null) await pendingCheck;

    final server = _server;
    final httpsServer = _httpsServer;
    final ctx = _context;
    final bluetooth = _bluetooth;
    _server = null;
    _httpsServer = null;
    _httpsChain = null;
    _tlsFiles = null;
    _context = null;
    _bluetooth = null;
    if (server == null) return;

    // Zuerst Bluetooth: die Brücke schreibt in den Bus, wartende Belegungen
    // und Aufrufe sollen sauber scheitern, und das Hilfsprogramm darf den
    // Agenten nicht überleben. Ein Fehler dabei hält das Anhalten nicht auf.
    if (bluetooth != null) {
      try {
        await bluetooth.close();
      } on Object catch (error) {
        log.error('Bluetooth ließ sich nicht sauber beenden', error);
      }
    }

    // Dann der Bus: die offenen WebSocket-Verbindungen hängen nach dem
    // Hijack nicht mehr am HttpServer und überlebten dessen `close()`. Mit dem
    // Bus endet ihr Abo, und `serveEvents` schließt daraufhin die Senke —
    // die Kasse sieht ein sauberes Ende statt einer Verbindung ins Nichts.
    if (ctx != null && _ownsEvents) {
      await ctx.events.close();
    }

    for (final open in <HttpServer?>[server, httpsServer].nonNulls) {
      try {
        await open.close().timeout(gracefulStopTimeout);
      } on TimeoutException {
        log.warn('Anfragen hängen — Server wird hart geschlossen.');
        await open.close(force: true);
      }
    }
    log.info('Agent angehalten.');
  }

  /// Prüft die Zertifikate und bindet den HTTPS-Zugang neu, wenn die Kette
  /// inzwischen eine andere ist — Serverzertifikat erneuert 30 Tage vor
  /// Ablauf, oder neu ausgestellt samt neuer Stelle, weil eine Datei fehlte.
  /// Der Agent startet dafür nicht neu, und der HTTP-Zugang bleibt
  /// unberührt. Ein beim Start gescheiterter HTTPS-Zugang wird hier
  /// nachgeholt.
  ///
  /// Läuft im Takt [tlsCheckInterval]; mehrere Aufrufe teilen sich einen
  /// Lauf. Wirft nie — Fehler landen im Log.
  Future<void> checkTls() {
    if (!https || _server == null) return Future<void>.value();
    return _tlsCheck ??= _checkTls().whenComplete(() => _tlsCheck = null);
  }

  Future<void> _checkTls() async {
    try {
      final files = await _certificates.ensure();
      if (_server == null) return;
      final chain = await _chain(files);
      final current = _httpsServer;
      if (current != null && _sameBytes(chain, _httpsChain)) {
        _tlsFiles = files;
      } else {
        // Kontext zuerst: passen Zertifikat und Schlüssel nicht zusammen,
        // bleibt der alte Zugang stehen. Dann bindet der neue auf demselben
        // Port, solange der alte noch lauscht (geteilter Port, siehe
        // [_bind]), und erst danach schließt der alte: keine Lücke, kein
        // Portwechsel. Offene Verbindungen (auch WebSockets) laufen auf dem
        // alten Server zu Ende.
        final context = await _securityContext(files, chain);
        await _serveHttps(
          files,
          chain,
          context,
          preferred: current?.port ?? preferredHttpsPort,
        );
        if (current != null) {
          await current.close();
          log.info(
            'HTTPS-Zugang mit neuem Serverzertifikat neu gebunden '
            '(Port $httpsPort).',
          );
        }
        await _rememberHttpsPort();
      }
      if (_httpsServer != null) await _warnIfUntrusted();
    } on Object catch (error) {
      log.error('HTTPS: Prüfung der Zertifikate gescheitert', error);
    }
  }

  /// Bindet den HTTPS-Zugang. Scheitert das (kein `openssl`, kein freier
  /// Port, unbrauchbare Zertifikate), bleibt es beim HTTP-Zugang — der lauscht
  /// da schon und wird nicht angefasst.
  Future<void> _startHttps() async {
    try {
      final files = await _certificates.ensure();
      final chain = await _chain(files);
      await _serveHttps(
        files,
        chain,
        await _securityContext(files, chain),
        preferred: preferredHttpsPort,
      );
      await _rememberHttpsPort();
    } on Object catch (error) {
      log.error('HTTPS-Zugang nicht verfügbar, HTTP läuft weiter', error);
      return;
    }
    await _warnIfUntrusted();
  }

  /// Die Kette aus [files], wie sie gerade auf der Platte liegt: Blatt, dann
  /// Stelle ([serverCertificateChain]).
  Future<List<int>> _chain(TlsFiles files) async => serverCertificateChain(
    await File(files.serverCertPath).readAsBytes(),
    await File(files.caCertPath).readAsBytes(),
  );

  /// Kontext aus [chain] (die Bytes, die gerade gelesen wurden) und dem
  /// Schlüssel daneben; wirft, wenn Serverzertifikat und Schlüssel nicht
  /// zusammenpassen.
  Future<SecurityContext> _securityContext(
    TlsFiles files,
    List<int> chain,
  ) async => SecurityContext()
    ..useCertificateChainBytes(chain)
    ..usePrivateKeyBytes(await File(files.serverKeyPath).readAsBytes());

  /// Bindet [files] als HTTPS-Zugang.
  Future<void> _serveHttps(
    TlsFiles files,
    List<int> chain,
    SecurityContext context, {
    required int preferred,
  }) async {
    final server = await _bind(preferred, securityContext: context);
    _httpsServer = server;
    _httpsChain = chain;
    _tlsFiles = files;
    _trustCheckedAt = null;
    final ctx = _context;
    if (ctx != null) {
      ctx
        ..httpsPort = server.port
        ..tls = _tlsSummary;
    }
    log.info(
      '$agentName lauscht auf https://127.0.0.1:${server.port} '
      '(Zertifikat gültig bis '
      '${files.serverNotAfter.toUtc().toIso8601String().substring(0, 10)})',
    );
  }

  Future<void> _rememberHttpsPort() async {
    final port = httpsPort;
    if (port == null) return;
    final config = await store.load();
    if (config.httpsPort != port) {
      await store.mutate((current) => current.copyWith(httpsPort: port));
    }
  }

  /// Ohne Vertrauen erreicht Safari den HTTPS-Zugang nicht. Der Agent sagt
  /// das nur — eintragen tun es der Installer und `zertifikat-vertrauen`,
  /// nie ein Hintergrundprozess bei der Anmeldung.
  Future<void> _warnIfUntrusted() async {
    if (await _trust(force: true)) return;
    log.warn(
      'HTTPS: der lokalen Zertifizierungsstelle wird nicht vertraut — '
      'Safari erreicht Connect so nicht. Abhilfe: '
      '`kasseneck-connect zertifikat-vertrauen`.',
    );
  }

  /// Ob macOS der Stelle vertraut; die Antwort gilt [trustCacheDuration].
  /// Wirft nie: Start, Status und Prüfung hängen daran.
  Future<bool> _trust({bool force = false}) async {
    final files = _tlsFiles;
    if (files == null) return false;
    final checkedAt = _trustCheckedAt;
    final cached = _trusted;
    if (!force && checkedAt != null && cached != null) {
      final age = _clock().difference(checkedAt);
      if (!age.isNegative && age < trustCacheDuration) return cached;
    }
    bool trusted;
    try {
      trusted = await isLocalCaTrusted(
        files.caCertPath,
        start: _startProcess,
        serverCertPath: files.serverCertPath,
      );
    } on Object catch (error) {
      log.error('HTTPS: Vertrauen ließ sich nicht prüfen', error);
      trusted = false;
    }
    _trusted = trusted;
    _trustCheckedAt = _clock();
    return trusted;
  }

  Future<Map<String, Object?>?> _tlsSummary() async {
    final files = _tlsFiles;
    if (files == null || _httpsServer == null) return null;
    return <String, Object?>{
      'notAfter': files.serverNotAfter.toUtc().toIso8601String(),
      'trusted': await _trust(),
    };
  }

  /// Bindet den ersten freien Port ab [preferred] — mit [securityContext]
  /// als HTTPS-Zugang.
  ///
  /// HTTPS bindet geteilt (`shared`): so kann der erneuerte Zugang auf
  /// demselben Port lauschen, bevor der alte schließt. Gleich nach `close()`
  /// ist der Port sonst nicht immer frei (unter Linux belegt), und der Zugang
  /// wanderte still auf den nächsten. Geteilt wird nur innerhalb dieses
  /// Prozesses — ein fremder Prozess bekommt den Port auch mit `SO_REUSEPORT`
  /// nicht (geprüft unter macOS und Linux).
  Future<HttpServer> _bind(
    int preferred, {
    SecurityContext? securityContext,
  }) async {
    final handler = _handler!;
    final label = securityContext == null ? '' : 'HTTPS: ';
    final attempts = preferred == 0 ? 1 : portFallbackRange;
    Object? lastError;

    for (var offset = 0; offset < attempts; offset++) {
      final candidate = preferred == 0 ? 0 : preferred + offset;
      try {
        return await shelf_io.serve(
          handler,
          InternetAddress.loopbackIPv4,
          candidate,
          securityContext: securityContext,
          shared: securityContext != null,
        );
      } on SocketException catch (e) {
        lastError = e;
        log.warn('${label}Port $candidate ist belegt — nächster Versuch.');
      }
    }

    log.error('${label}Kein freier Port ab $preferred gefunden', lastError);
    throw StateError(
      'Kein freier Port zwischen $preferred und '
      '${preferred + portFallbackRange - 1}.',
    );
  }
}

bool _sameBytes(List<int> a, List<int>? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
