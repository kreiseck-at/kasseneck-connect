import 'dart:io';

/// Startet ein Programm und wartet auf das Ergebnis — in Tests austauschbar.
///
/// Alle Stellen, die von außen etwas aufrufen (Browser öffnen, `launchctl`,
/// `schtasks`, `systemctl`), gehen über diesen Typ. Im Test steht dort ein
/// Doppelgänger, der die Aufrufe nur mitschreibt: kein Testlauf darf am
/// echten System herumschrauben.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
