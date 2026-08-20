import 'dart:io';
import 'package:kasseneck_connect/kasseneck_connect.dart';

Future<void> main() async {
  final log = AgentLog(Directory.systemTemp.createTempSync('hps-pay-'));
  final bridge = HpsBridge(log: log);
  final txId = '${DateTime.now().millisecondsSinceEpoch}00003'.substring(0, 18);
  try {
    final antwort = await bridge.payment(
      host: '192.168.0.187', port: 8080, tid: '3600335',
      amountCents: 100, transactionId: txId, reference: 'Bruecken-Fix-Test',
    );
    print('ANTWORT: $antwort');
  } on HpsWegFehler catch (e) {
    print('FEHLER: ${e.code} — ${e.message}');
  }
}
