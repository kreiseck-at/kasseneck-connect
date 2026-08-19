import 'dart:async';
import 'dart:io';

/// Verhalten des Fake-Druckers.
enum FakePrinterMode {
  /// Nimmt die Bytes entgegen und merkt sie sich.
  accept,

  /// Nimmt die Verbindung an, liest aber **nie** — der Sendepuffer läuft voll
  /// und der Schreibvorgang bleibt stehen (Zeitlimit prüfen).
  hang,

  /// Wirft die Verbindung sofort weg (Transportfehler prüfen).
  reset,
}

/// Fake-Bondrucker auf TCP 9100: nimmt rohe Bytes an und protokolliert sie.
class FakeTcpPrinter {
  FakeTcpPrinter._(this._server, this.mode);

  /// Startet den Fake auf einem freien Loopback-Port.
  static Future<FakeTcpPrinter> start({
    FakePrinterMode mode = FakePrinterMode.accept,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final printer = FakeTcpPrinter._(server, mode);
    printer._subscription = server.listen(printer._handle);
    return printer;
  }

  final ServerSocket _server;

  /// Verhalten dieses Fakes.
  final FakePrinterMode mode;

  final List<int> _received = <int>[];
  final List<Socket> _open = <Socket>[];
  final List<StreamSubscription<List<int>>> _reads =
      <StreamSubscription<List<int>>>[];
  StreamSubscription<Socket>? _subscription;
  int _connections = 0;

  int get port => _server.port;

  /// Alle bisher empfangenen Bytes (über alle Verbindungen).
  List<int> get received => List<int>.unmodifiable(_received);

  /// Wie oft sich jemand verbunden hat.
  int get connections => _connections;

  void _handle(Socket socket) {
    _connections++;
    switch (mode) {
      case FakePrinterMode.accept:
        _reads.add(
          socket.listen(
            _received.addAll,
            onError: (Object _) {},
            onDone: () => socket.destroy(),
          ),
        );
      case FakePrinterMode.hang:
        // Bewusst nicht lesen: die Verbindung steht, der Absender läuft voll.
        _open.add(socket);
      case FakePrinterMode.reset:
        socket.destroy();
    }
  }

  Future<void> stop() async {
    for (final read in _reads) {
      await read.cancel();
    }
    _reads.clear();
    for (final socket in _open) {
      socket.destroy();
    }
    _open.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _server.close();
  }
}
