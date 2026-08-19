// Druckersuche auf diesem Rechner ausführen und ausdrucken, was passiert.
//
//   dart run tool/scan_debug.dart          # mDNS und Netzscan
//   dart run tool/scan_debug.dart --no-scan   # nur mDNS
//
// Gedacht für die Fehlersuche beim Kunden: das Werkzeug zeigt die
// Schnittstellen dieses Rechners, welche Netze der Scan davon abklopft und was
// er findet. Findet die Kasse keinen Drucker, steht hier, ob überhaupt im
// richtigen Netz gesucht wurde.
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

Future<void> main(List<String> args) async {
  final scan = !args.contains('--no-scan');

  stdout.writeln('IPv4-Schnittstellen dieses Rechners:');
  final all = await listLocalIpv4Interfaces();
  for (final interface in all) {
    stdout.writeln('  ${interface.name}\t${interface.address}');
  }
  if (all.isEmpty) stdout.writeln('  (keine)');

  stdout.writeln('\nDavon wird abgesucht:');
  for (final interface in scanInterfaces(all)) {
    stdout.writeln('  ${interface.name}\t${subnetOf(interface.address)}');
  }

  stdout.writeln('\nSuche läuft (scan: $scan) …');
  final clock = Stopwatch()..start();
  final result = await PrinterDiscovery().discover(scan: scan);

  stdout.writeln('\nAbgesuchte Netze:');
  for (final subnet in result.scanned) {
    stdout.writeln(
      '  ${subnet.interface}\t${subnet.subnet}\t${subnet.hosts} Adressen',
    );
  }
  if (result.scanned.isEmpty) stdout.writeln('  (keine)');

  stdout.writeln('\nGefundene Drucker:');
  for (final printer in result.printers) {
    final name = printer.name == null ? '' : '\t${printer.name}';
    stdout.writeln(
      '  ${printer.host}:${printer.port}\t${printer.kind.wireName}$name',
    );
  }
  if (result.printers.isEmpty) stdout.writeln('  (keine)');

  stdout.writeln('\nDauer: ${clock.elapsedMilliseconds} ms');
}
