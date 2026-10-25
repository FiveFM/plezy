import 'dart:async';

import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';
import '../../models/riven/riven_session.dart';
import '../../utils/app_logger.dart';
import '../../utils/url_utils.dart';
import 'riven_constants.dart';
import 'riven_exceptions.dart';
import 'riven_http_client.dart';

/// A reachable Riven install: the URL that answered, the credential it takes,
/// and — for a bare backend, which reports it unauthenticated — its version.
typedef RivenReachableInstance = ({String baseUrl, RivenAuthMethod method, String? version});

/// The better-auth user behind a frontend session cookie.
typedef _RivenUser = ({String id, String displayName});

/// Sign-in flows against a Riven install. A frontend sign-in ends with a
/// captured `riven.session_token` cookie and the better-auth user read back
/// through `GET /api/auth/get-session`; an API-key sign-in with the backend
/// accepting the key. Both confirm `/api/v1` answers before a [RivenSession]
/// is handed out, so a frontend whose backend is down fails here rather than
/// on the first request.
class RivenAuthService {
  final http.Client Function()? httpClientFactory;

  RivenAuthService({this.httpClientFactory});

  RivenHttpClient _client(String baseUrl, {String? cookie, String? apiKey}) =>
      RivenHttpClient(baseUrl: baseUrl, httpClient: httpClientFactory?.call(), cookie: cookie, apiKey: apiKey);

  /// Schemeless-input guesses, TLS first: a bare host is usually a public
  /// frontend behind a reverse proxy, and [probeFirstReachable] must be able
  /// to prefer the TLS candidate before a plaintext one wins the race. Then
  /// the two default install ports, frontend before backend.
  static const List<BaseUrlGuess> _schemelessGuesses = [
    (scheme: 'https', port: null),
    (scheme: 'http', port: null),
    (scheme: 'http', port: RivenConstants.defaultFrontendPort),
    (scheme: 'http', port: RivenConstants.defaultBackendPort),
  ];

  /// Expands a user-typed install address into probe candidates: an explicit
  /// scheme is authoritative, otherwise TLS, plain HTTP, and the default
  /// install ports are all tried. Guesses are for discovery only — only the
  /// candidate that answered is persisted.
  static List<String> expandUrlCandidates(String input) => expandBaseUrlCandidates(input, guesses: _schemelessGuesses);

  /// Probes every [expandUrlCandidates] guess for [input] and returns the
  /// first reachable install.
  ///
  /// TLS wins by construction, as in the Seerr connect flow: probes all start
  /// together, but a plaintext success is held while any `https` candidate is
  /// still in flight. The sign-in that follows posts a password or API key to
  /// whichever URL wins here, so a slow-but-working TLS endpoint must beat a
  /// fast plaintext one; each probe already bounds the hold at
  /// [RivenConstants.probeTimeout].
  ///
  /// When nothing answers, the failure that reached a *server* is reported in
  /// preference to a transport error, so "that is not Riven" isn't masked by
  /// "could not reach https://…" from a candidate the user never meant.
  Future<RivenReachableInstance> probeFirstReachable(String input) async {
    final candidates = expandUrlCandidates(input);
    if (candidates.isEmpty) {
      throw RivenUrlException('Not a usable Riven URL: "$input"', display: t.riven.invalidUrl);
    }
    if (candidates.length == 1) return probe(candidates.single);

    final completer = Completer<RivenReachableInstance>();
    final failures = List<(Object, StackTrace)?>.filled(candidates.length, null);
    var pending = candidates.length;
    var pendingSecure = candidates.where(_isSecure).length;
    RivenReachableInstance? heldPlaintext;

    void settle() {
      if (completer.isCompleted) return;
      final held = heldPlaintext;
      if (held != null && pendingSecure == 0) {
        appLogger.d('Riven: no TLS candidate answered, accepting the plaintext URL');
        completer.complete(held);
        return;
      }
      if (pending == 0) {
        final (error, stackTrace) = _mostInformativeFailure(failures);
        completer.completeError(error, stackTrace);
      }
    }

    for (final (index, candidate) in candidates.indexed) {
      final secure = _isSecure(candidate);
      unawaited(
        probe(candidate).then(
          (instance) {
            pending -= 1;
            if (secure) pendingSecure -= 1;
            if (completer.isCompleted) return;
            if (secure) {
              completer.complete(instance);
              return;
            }
            heldPlaintext ??= instance;
            settle();
          },
          onError: (Object error, StackTrace stackTrace) {
            failures[index] = (error, stackTrace);
            pending -= 1;
            if (secure) pendingSecure -= 1;
            settle();
          },
        ),
      );
    }
    return completer.future;
  }

  static bool _isSecure(String baseUrl) => baseUrl.startsWith('https://');

  /// The failure worth showing: one that came back from a server outranks a
  /// transport error, and the first candidate — the URL the user most likely
  /// meant — breaks the tie.
  static (Object, StackTrace) _mostInformativeFailure(List<(Object, StackTrace)?> failures) {
    for (final failure in failures) {
      if (failure != null && failure.$1 is RivenUrlException && (failure.$1 as RivenUrlException).statusCode != null) {
        return failure;
      }
    }
    return failures.firstWhere((failure) => failure != null)!;
  }

  /// The API root as each surface serves it without a redirect. The backend
  /// mounts it at `/api/v1/` and bounces the bare path there; the frontend's
  /// SvelteKit router strips the trailing slash with a 308 instead, and only
  /// the bare path reaches its proxy. Redirects are never followed, so asking
  /// either for the other's form reads as an intermediary.
  static String _rootPath(RivenAuthMethod method) => method == RivenAuthMethod.apiKey ? '/' : '';

  /// Identify what answers at [baseUrl], unauthenticated:
  ///
  ///   * a bare backend answers `GET /api/v1/` itself, with
  ///     [RivenConstants.backendRootMessage] and its version — it takes an
  ///     API key;
  ///   * the frontend answers better-auth's `GET /api/auth/ok` — it takes a
  ///     username and password.
  ///
  /// Throws [RivenUrlException] when unreachable, not Riven, or answered by
  /// an auth proxy instead.
  Future<RivenReachableInstance> probe(String baseUrl) async {
    final client = _client(baseUrl);
    try {
      final RivenResponse res;
      try {
        res = await client.send(
          'GET',
          _rootPath(RivenAuthMethod.apiKey),
          timeout: RivenConstants.probeTimeout,
          authenticated: false,
        );
      } catch (e) {
        throw RivenUrlException(
          'Could not reach $baseUrl: $e',
          display: t.riven.couldNotReach(url: baseUrl, error: e),
        );
      }
      final data = res.data;
      if (res.statusCode == 200 &&
          data is Map<String, dynamic> &&
          data['message'] == RivenConstants.backendRootMessage) {
        final version = data['version'];
        return (baseUrl: client.baseUrl, method: RivenAuthMethod.apiKey, version: version is String ? version : null);
      }
      // Asked before the redirect verdict below: the frontend answers the
      // backend's root form with its trailing-slash 308, which would otherwise
      // read as a wall.
      if (await _answersBetterAuth(client)) {
        return (baseUrl: client.baseUrl, method: RivenAuthMethod.frontend, version: null);
      }
      if (RivenHttpClient.classify(res) == RivenRejection.intermediary) {
        throw RivenUrlException(
          'Auth proxy in front of $baseUrl (HTTP ${res.statusCode})',
          display: t.riven.behindAuthProxy,
          statusCode: res.statusCode,
        );
      }
      throw RivenUrlException(
        'No Riven install at $baseUrl (HTTP ${res.statusCode})',
        display: t.riven.noInstanceAtUrl(url: baseUrl, status: res.statusCode),
        statusCode: res.statusCode,
      );
    } finally {
      client.dispose();
    }
  }

  Future<bool> _answersBetterAuth(RivenHttpClient client) async {
    try {
      final res = await client.sendAuth('GET', '/ok', timeout: RivenConstants.probeTimeout, authenticated: false);
      final data = res.data;
      return res.statusCode == 200 && data is Map<String, dynamic> && data['ok'] == true;
    } catch (e) {
      appLogger.d('Riven: better-auth probe failed', error: e);
      return false;
    }
  }

  /// better-auth `POST /api/auth/sign-in/username` — the call the frontend's
  /// own login form makes.
  Future<RivenSession> signInWithPassword({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final client = _client(baseUrl);
    try {
      final res = await client.sendAuth(
        'POST',
        '/sign-in/username',
        body: {'username': username, 'password': password},
        authenticated: false,
      );
      // better-auth's own rejections all carry its `code` (wrong password,
      // malformed username, banned user); a wall in front of it carries none.
      final data = res.data;
      if (res.statusCode >= 400 && res.statusCode < 500 && data is Map<String, dynamic> && data['code'] is String) {
        throw RivenAuthException(
          data['message'] as String? ?? data['code'] as String,
          statusCode: res.statusCode,
          display: t.riven.signInRejected,
        );
      }
      RivenHttpClient.throwForStatus(res);
      if (!client.captureSessionCookie(res.response)) {
        throw RivenAuthException('Riven did not issue a session cookie', display: t.riven.noSessionCookie);
      }
      final user = await _fetchUser(client);
      final version = await _fetchVersion(client, RivenAuthMethod.frontend);
      return RivenSession(
        baseUrl: client.baseUrl,
        method: RivenAuthMethod.frontend,
        identifier: username,
        secret: password,
        cookie: client.cookie!,
        userId: user.id,
        displayName: user.displayName.isNotEmpty ? user.displayName : username,
        version: version,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } finally {
      client.dispose();
    }
  }

  /// A bare backend with its `x-api-key`. `GET /api/v1/health` is the
  /// cheapest route behind the key.
  Future<RivenSession> signInWithApiKey({required String baseUrl, required String apiKey}) async {
    final client = _client(baseUrl, apiKey: apiKey);
    try {
      final res = await client.send('GET', '/health', timeout: RivenConstants.authTimeout);
      if (RivenHttpClient.classify(res) == RivenRejection.credentials) {
        throw RivenAuthException(
          'Riven rejected the API key',
          statusCode: res.statusCode,
          display: t.riven.apiKeyRejected,
        );
      }
      RivenHttpClient.throwForStatus(res);
      final version = await _fetchVersion(client, RivenAuthMethod.apiKey);
      return RivenSession(
        baseUrl: client.baseUrl,
        method: RivenAuthMethod.apiKey,
        identifier: '',
        secret: apiKey,
        cookie: '',
        userId: '',
        displayName: '',
        version: version,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } finally {
      client.dispose();
    }
  }

  /// Silent re-login using the credentials carried by [session]. Returns the
  /// refreshed session. API-key sessions have nothing to refresh: a rejected
  /// key is final.
  Future<RivenSession> reauth(RivenSession session) async {
    if (session.method != RivenAuthMethod.frontend || session.secret.isEmpty) {
      throw RivenAuthException('No stored credentials for silent re-auth', display: t.riven.noStoredCredentials);
    }
    final fresh = await signInWithPassword(
      baseUrl: session.baseUrl,
      username: session.identifier,
      password: session.secret,
    );
    if (fresh.userId != session.userId) {
      // The account was deleted and recreated under the same name. Never
      // combine another user's cookie with this binding's identity.
      throw RivenAuthException('Silent re-auth returned a different Riven user', display: t.riven.noUserInformation);
    }
    return session.copyWith(cookie: fresh.cookie, displayName: fresh.displayName, version: fresh.version);
  }

  /// Best-effort server-side sign-out; local cleanup must not depend on it.
  Future<void> signOut(RivenSession session) async {
    if (session.method != RivenAuthMethod.frontend || session.cookie.isEmpty) return;
    final client = _client(session.baseUrl, cookie: session.cookie);
    try {
      await client.sendAuth('POST', '/sign-out', body: const {});
    } catch (e) {
      appLogger.d('Riven: sign-out best-effort failed', error: e);
    } finally {
      client.dispose();
    }
  }

  /// The user behind the fresh cookie, via `GET /api/auth/get-session`, which
  /// answers a literal `null` for a cookie it does not know.
  Future<_RivenUser> _fetchUser(RivenHttpClient client) async {
    final res = await client.sendAuth('GET', '/get-session');
    RivenHttpClient.throwForStatus(res);
    final user = res.data is Map<String, dynamic> ? (res.data as Map<String, dynamic>)['user'] : null;
    if (user is! Map<String, dynamic>) {
      throw RivenAuthException('Riven rejected the fresh session cookie', display: t.riven.freshCookieRejected);
    }
    final id = user['id'];
    if (id is! String || id.isEmpty) {
      throw RivenAuthException('Riven did not return user information', display: t.riven.noUserInformation);
    }
    // `displayUsername` keeps the casing the user signed up with; `username`
    // is lowercased by the plugin.
    final name = [
      user['displayUsername'],
      user['username'],
      user['name'],
    ].whereType<String>().firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    return (id: id, displayName: name);
  }

  /// `GET /api/v1` through whichever credential [client] carries: proves the
  /// API is reachable with it and reports the backend version.
  Future<String> _fetchVersion(RivenHttpClient client, RivenAuthMethod method) async {
    final res = await client.send('GET', _rootPath(method), timeout: RivenConstants.authTimeout);
    if (RivenHttpClient.classify(res) == RivenRejection.session) {
      throw RivenAuthException(
        'Riven rejected the fresh session cookie',
        statusCode: res.statusCode,
        display: t.riven.freshCookieRejected,
      );
    }
    RivenHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! Map<String, dynamic> || data['message'] != RivenConstants.backendRootMessage) {
      throw RivenApiException('Riven did not answer at ${RivenConstants.apiPath}', statusCode: res.statusCode);
    }
    final version = data['version'];
    return version is String ? version : '';
  }
}
