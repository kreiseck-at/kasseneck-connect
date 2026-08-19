import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../config/model.dart';
import '../config/store.dart';
import '../log/logger.dart';

/// Gültigkeit eines Kopplungscodes.
const Duration pairingCodeLifetime = Duration(minutes: 10);

/// Sperre nach zu vielen Fehlversuchen.
const Duration pairingLockDuration = Duration(seconds: 60);

/// Fehlversuche bis zur Sperre.
const int pairingMaxFailures = 5;

/// Seite der Kasse, die den Code gegen einen Token tauscht.
const String pairingPageBaseUrl = 'https://kasse.kasseneck.at/connect';

/// Umgebungsvariable, mit der das Öffnen des Browsers unterbleibt
/// (Tests, Serverbetrieb, CLI).
const String noBrowserEnvVar = 'KASSENECK_CONNECT_NO_BROWSER';

/// Grund, warum eine Kopplung scheiterte.
enum PairFailure {
  /// Code falsch oder gar kein Vorgang offen.
  invalid(errorCode: 'pair_invalid', message: 'Kopplungscode stimmt nicht.'),

  /// Code war älter als [pairingCodeLifetime].
  expired(
    errorCode: 'pair_expired',
    message: 'Kopplungscode ist abgelaufen. Bitte einen neuen anfordern.',
  ),

  /// Zu viele Fehlversuche.
  locked(
    errorCode: 'pair_locked',
    message: 'Zu viele Fehlversuche. Bitte eine Minute warten.',
  );

  const PairFailure({required this.errorCode, required this.message});

  /// Code der API-Fehlerantwort.
  final String errorCode;

  /// Deutscher Klartext für die Kasse.
  final String message;
}

/// SHA-256-Hash eines Tokens in Hex — nur der landet in der Konfiguration.
String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

/// Adresse der Kopplungsseite mit Code und Port im Fragment.
///
/// Das Fragment (`#`) wird vom Browser nicht an den Server geschickt — der Code
/// bleibt zwischen Agent und Kassen-Frontend.
String pairingPageUrl(String code, int port) =>
    '$pairingPageBaseUrl#code=$code&port=$port';

/// Kopplung zwischen Agent und Kasse.
///
/// Ablauf: [newCode] erzeugt einen sechsstelligen Code und legt ihn in der
/// `config.json` ab; die Kasse schickt ihn an `POST /v1/pair`; [verify] prüft
/// ihn und [issueToken] gibt einen Token aus, von dem nur der SHA-256-Hash
/// gespeichert wird.
///
/// Zustand liegt bewusst in der Konfigurationsdatei und nicht im Speicher:
/// `kasseneck-connect pair` läuft als **zweiter Prozess** neben dem Agenten,
/// erzeugt dort den Code — und der laufende Agent liest ihn bei `POST /v1/pair`
/// aus der Datei.
class Pairing {
  Pairing({
    required this.store,
    required this.log,
    DateTime Function()? clock,
    Random? random,
    this.codeLifetime = pairingCodeLifetime,
    this.lockDuration = pairingLockDuration,
    this.maxFailures = pairingMaxFailures,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final ConfigStore store;
  final AgentLog log;
  final Duration codeLifetime;
  final Duration lockDuration;
  final int maxFailures;

  final DateTime Function() _clock;
  final Random _random;

  /// Erzeugt einen neuen Code, hinterlegt ihn und hebt eine Sperre auf.
  Future<String> newCode() async {
    final code = _random.nextInt(1000000).toString().padLeft(6, '0');
    final now = _clock();
    await store.mutate(
      (current) => current.copyWith(
        pairing: PairingState(code: code, expiresAt: now.add(codeLifetime)),
      ),
    );
    return code;
  }

  /// Prüft [code]. `null` heißt: angenommen, der Vorgang ist verbraucht.
  ///
  /// Fehlversuche werden gezählt; ab [maxFailures] ist die Kopplung für
  /// [lockDuration] gesperrt — auch für den richtigen Code.
  Future<PairFailure?> verify(String code) async {
    final now = _clock();
    PairFailure? failure;

    await store.mutate((current) {
      final state = current.pairing;
      final lockedUntil = state.lockedUntil;

      if (lockedUntil != null && lockedUntil.isAfter(now)) {
        failure = PairFailure.locked;
        return current;
      }

      // Abgelaufene Sperre fällt weg, die Fehlversuche beginnen von vorn.
      final unlocked = lockedUntil == null
          ? state
          : state.copyWith(clearLock: true, failedAttempts: 0);

      final expiresAt = unlocked.expiresAt;
      if (unlocked.code != null &&
          expiresAt != null &&
          !expiresAt.isAfter(now)) {
        failure = PairFailure.expired;
        return current.copyWith(pairing: unlocked.copyWith(clearCode: true));
      }

      if (unlocked.code != null && unlocked.code == code) {
        return current.copyWith(pairing: PairingState.none);
      }

      failure = PairFailure.invalid;
      final attempts = unlocked.failedAttempts + 1;
      if (attempts >= maxFailures) {
        return current.copyWith(
          pairing: unlocked.copyWith(
            failedAttempts: attempts,
            lockedUntil: now.add(lockDuration),
          ),
        );
      }
      return current.copyWith(
        pairing: unlocked.copyWith(failedAttempts: attempts),
      );
    });

    if (failure != null) {
      log.warn('Kopplung abgelehnt (${failure!.errorCode}).');
    }
    return failure;
  }

  /// Erzeugt einen Token (32 Zufallsbytes, base64url ohne Polster), speichert
  /// nur dessen Hash und liefert den Klartext genau einmal zurück.
  Future<String> issueToken() async {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    await store.mutate(
      (current) => current.copyWith(
        tokenHashes: <String>[...current.tokenHashes, hashToken(token)],
      ),
    );
    log.info('Kasse gekoppelt — neuer Token ausgegeben.');
    return token;
  }

  /// Entfernt den Hash von [token]. `false`, wenn er gar nicht bekannt war.
  Future<bool> revokeToken(String token) async {
    final hash = hashToken(token);
    var removed = false;
    await store.mutate((current) {
      if (!current.tokenHashes.contains(hash)) return current;
      removed = true;
      return current.copyWith(
        tokenHashes: current.tokenHashes
            .where((entry) => entry != hash)
            .toList(),
      );
    });
    if (removed) log.info('Token widerrufen.');
    return removed;
  }

  /// Öffnet die Kopplungsseite im Standardbrowser.
  ///
  /// Schlägt das fehl (kein Desktop, kein Browser, Rechte), bleibt es bei einem
  /// Logeintrag — der Code steht auch im Log und in `kasseneck-connect pair`.
  Future<void> openPairingPage(
    String code,
    int port, {
    String? operatingSystem,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    if (env[noBrowserEnvVar] == '1') return;

    final url = pairingPageUrl(code, port);
    final os = operatingSystem ?? Platform.operatingSystem;
    final String executable;
    final List<String> arguments;
    switch (os) {
      case 'macos':
        executable = 'open';
        arguments = <String>[url];
      case 'windows':
        executable = 'cmd';
        arguments = <String>['/c', 'start', '', url];
      default:
        executable = 'xdg-open';
        arguments = <String>[url];
    }

    try {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) {
        log.warn('Browser ließ sich nicht öffnen (Code ${result.exitCode}).');
      }
    } on ProcessException catch (e) {
      log.warn('Browser ließ sich nicht öffnen: ${e.message}');
    }
  }
}
