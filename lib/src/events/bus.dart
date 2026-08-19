import 'dart:async';

/// Ereignis: ein Druckauftrag ist fertig.
const String eventPrintDone = 'print.done';

/// Ereignis: ein Druckauftrag ist endgültig fehlgeschlagen.
const String eventPrintFailed = 'print.failed';

/// Ereignis: der bekannte Zustand eines Druckers hat sich geändert.
const String eventPrinterState = 'printer.state';

/// Ereignis: der Agent hält gleich an und kommt über den Autostart zurück
/// (ab v1.2 beim Selbstaustausch — die Kasse soll dann kurz keinen Druck
/// erwarten).
const String eventAgentRestarting = 'agent.restarting';

/// Ein Ereignis des Agenten, so wie es über `/v1/events` hinausgeht.
///
/// Die Daten werden beim Serialisieren **flach** neben `type` gelegt — genau
/// das Format, das die Kasse laut Spezifikation erwartet
/// (`{type: 'print.done', printerId: …, jobId: …}`).
class AgentEvent {
  const AgentEvent(this.type, [this.data = const <String, Object?>{}]);

  /// Art des Ereignisses, z. B. `print.done`.
  final String type;

  /// Nutzdaten; niemals Beleginhalte, nur IDs, Codes und Klartextmeldungen.
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{'type': type, ...data};

  @override
  String toString() => 'AgentEvent($type, $data)';
}

/// Verteilt Ereignisse an alle Zuhörer (WebSocket-Verbindungen, Tests).
///
/// Bewusst ein Broadcast-Stream ohne Puffer: wer nicht zuhört, verpasst das
/// Ereignis. Der Zustand des Agenten steht in `GET /v1/status`, die Ereignisse
/// sind nur die schnelle Benachrichtigung obendrauf.
class EventBus {
  final StreamController<AgentEvent> _controller =
      StreamController<AgentEvent>.broadcast();

  /// Alle Ereignisse ab dem Zeitpunkt des Abonnierens.
  Stream<AgentEvent> get stream => _controller.stream;

  /// Ob der Bus schon geschlossen wurde.
  bool get isClosed => _controller.isClosed;

  /// Meldet ein Ereignis; nach [close] verpufft es folgenlos.
  void emit(AgentEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// Bequemer Weg für die Melder im Agenten.
  void publish(String type, [Map<String, Object?> data = const {}]) =>
      emit(AgentEvent(type, data));

  Future<void> close() async {
    if (_controller.isClosed) return;
    await _controller.close();
  }
}
