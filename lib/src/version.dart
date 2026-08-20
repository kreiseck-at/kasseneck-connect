/// Name der Binary, wie sie auf der Kommandozeile heißt.
const String agentName = 'kasseneck-connect';

/// Version des Agenten (SemVer). Muss mit `version:` in `pubspec.yaml`
/// übereinstimmen — sie wird über `GET /v1/status` und im Update-Feed verglichen.
const String agentVersion = '1.2.3';
