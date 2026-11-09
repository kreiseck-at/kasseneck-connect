import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lokales_netz.dart';
import 'driver.dart';

/// Voreingestelltes Zeitlimit für den Verbindungsaufbau.
const Duration defaultConnectTimeout = Duration(seconds: 5);

/// Baut eine TCP-Verbindung auf (wie `Socket.connect`; Tests ersetzen das).
typedef SocketConnector =
    Future<Socket> Function(String host, int port, {Duration? timeout});

/// Roher ESC/POS-Bytestrom über TCP 9100 („RAW"/JetDirect).
///
/// Das Gerät antwortet auf diesem Weg nicht — gedruckt ist, was der Drucker
/// entgegengenommen hat. Deshalb gilt der Auftrag als erledigt, sobald die
/// Bytes vollständig hinausgeschrieben und die Verbindung sauber geschlossen
/// ist.
class Tcp9100Printer implements PrinterDriver {
  Tcp9100Printer(
    this.host,
    this.port, {
    this.connectTimeout = defaultConnectTimeout,
    String? betriebssystem,
    SocketConnector? verbinden,
  }) : betriebssystem = betriebssystem ?? Platform.operatingSystem,
       _verbinden = verbinden ?? Socket.connect;

  final String host;
  final int port;

  /// Zeitlimit für den Verbindungsaufbau (immer höchstens das Auftragslimit).
  final Duration connectTimeout;

  /// Betriebssystem für den Hinweis auf die Freigabe „Lokales Netzwerk“
  /// (macOS); Tests setzen es fest.
  final String betriebssystem;

  final SocketConnector _verbinden;

  /// Verbindung des laufenden Versuchs — nur damit [abort] sie wegwerfen kann.
  Socket? _current;

  @override
  Future<void> print(
    Uint8List bytes, {
    Duration timeout = defaultPrintTimeout,
  }) async {
    final watch = Stopwatch()..start();
    final socket = await _connect(timeout);
    _current = socket;

    // Der Drucker schickt auf 9100 nichts; gelesen wird trotzdem, damit ein
    // Fehler auf der Verbindung nicht als unbehandelt im Zone-Handler landet.
    final drain = socket.listen((_) {}, onError: (Object _) {});

    // Ab dem ersten `add` weiß niemand mehr, wie viel der Drucker schon
    // gesehen hat — ein zweiter Versuch könnte einen zweiten Bon bedeuten.
    var sent = false;
    try {
      socket.add(bytes);
      sent = true;
      await socket.flush().timeout(_remaining(timeout, watch));
      await socket.close().timeout(_remaining(timeout, watch));
    } on TimeoutException {
      throw PrinterFailure(
        errorPrintTimeout,
        sent
            ? unconfirmedPrintMessage
            : 'Der Drucker $host:$port hat den Auftrag nicht rechtzeitig '
                  'angenommen.',
        mayHavePrinted: sent,
      );
    } on SocketException catch (e) {
      throw PrinterFailure(
        errorPrinterOffline,
        sent
            ? unconfirmedPrintMessage
            : 'Die Verbindung zum Drucker $host:$port ist abgebrochen.',
        detail: socketGrund(e),
        mayHavePrinted: sent,
      );
    } finally {
      unawaited(drain.cancel());
      socket.destroy();
      _current = null;
    }
  }

  @override
  Future<void> abort() async {
    _current?.destroy();
    _current = null;
  }

  @override
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout}) async {
    try {
      final socket = await _verbinden(
        host,
        port,
        timeout: _shorter(connectTimeout, timeout),
      );
      socket.destroy();
      return PrinterState.online;
    } on SocketException {
      return PrinterState.offline;
    } on TimeoutException {
      return PrinterState.offline;
    }
  }

  Future<Socket> _connect(Duration timeout) async {
    try {
      return await _verbinden(
        host,
        port,
        timeout: _shorter(connectTimeout, timeout),
      );
    } on SocketException catch (e) {
      // Der Code bleibt printer_offline (Vertrag mit der Kasse); am Mac
      // kommt bei „No route to host“ der Hinweis auf die Freigabe dazu.
      throw PrinterFailure(
        errorPrinterOffline,
        mitLokalesNetzHinweis(
          'Der Drucker $host:$port ist nicht erreichbar.',
          e,
          betriebssystem: betriebssystem,
        ),
        detail: socketGrund(e),
      );
    }
  }

  /// Rest des Auftragslimits; nie null oder negativ.
  static Duration _remaining(Duration timeout, Stopwatch watch) {
    final left = timeout - watch.elapsed;
    return left > Duration.zero ? left : const Duration(milliseconds: 1);
  }

  static Duration _shorter(Duration a, Duration b) => a < b ? a : b;
}
