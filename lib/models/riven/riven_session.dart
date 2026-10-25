import 'dart:convert';

/// Which Riven surface the session talks to — determines how requests are
/// authenticated and whether a silent re-login is possible.
enum RivenAuthMethod {
  /// The Riven web frontend: better-auth `POST /api/auth/sign-in/username`
  /// with stored username/password, then the frontend's `/api/v1` proxy with
  /// the session cookie.
  frontend,

  /// The Riven backend directly, with its API key on every request. There is
  /// no session to expire: a rejected key means the key was rotated, and the
  /// only way forward is to reconnect with the new one.
  apiKey,
}

/// An authenticated Riven session for one profile: instance URL, how it
/// authenticates, and the credentials needed to keep doing so.
///
/// [secret] is the plaintext password ([RivenAuthMethod.frontend]) or API key
/// ([RivenAuthMethod.apiKey]) while in memory; the store protects it with
/// CredentialVault before persisting. Empty after an unrecoverable decrypt
/// failure — a frontend session then lives until its cookie expires and the
/// user must reconnect.
class RivenSession {
  final String baseUrl;
  final RivenAuthMethod method;

  /// Frontend username; empty for API-key sessions.
  final String identifier;
  final String secret;

  /// `riven.session_token` cookie value; empty for API-key sessions.
  final String cookie;

  /// better-auth user id the cookie belongs to; empty for API-key sessions.
  /// A silent re-login must land on the same user.
  final String userId;
  final String displayName;

  /// Backend version reported by `GET /api/v1` at sign-in.
  final String version;
  final int createdAt;

  const RivenSession({
    required this.baseUrl,
    required this.method,
    required this.identifier,
    required this.secret,
    required this.cookie,
    required this.userId,
    required this.displayName,
    required this.version,
    required this.createdAt,
  });

  RivenSession copyWith({String? secret, String? cookie, String? displayName, String? version}) => RivenSession(
    baseUrl: baseUrl,
    method: method,
    identifier: identifier,
    secret: secret ?? this.secret,
    cookie: cookie ?? this.cookie,
    userId: userId,
    displayName: displayName ?? this.displayName,
    version: version ?? this.version,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'base_url': baseUrl,
    'method': method.name,
    'identifier': identifier,
    'secret': secret,
    'cookie': cookie,
    'user_id': userId,
    'display_name': displayName,
    'version': version,
    'created_at': createdAt,
  };

  factory RivenSession.fromJson(Map<String, Object?> json) => RivenSession(
    baseUrl: json['base_url'] as String,
    // An unknown method must not fall back to another (an API key would be
    // posted as a password); the store's decode try/catch drops the session.
    method:
        RivenAuthMethod.values.asNameMap()[json['method']] ??
        (throw ArgumentError('Unknown Riven auth method: ${json['method']}')),
    identifier: json['identifier'] as String? ?? '',
    secret: json['secret'] as String? ?? '',
    cookie: json['cookie'] as String? ?? '',
    userId: json['user_id'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    version: json['version'] as String? ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );

  String encode() => jsonEncode(toJson());

  static RivenSession decode(String raw) => RivenSession.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}
