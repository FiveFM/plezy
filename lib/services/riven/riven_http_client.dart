import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';
import '../../utils/abortable_http_request.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../utils/platform_http_client_io.dart'
    as platform;
import '../../utils/url_utils.dart';
import '../trackers/tracker_http_client.dart';
import 'riven_constants.dart';
import 'riven_exceptions.dart';

/// HTTP response paired with its decoded JSON body. `data` is null for
/// no-content responses and non-JSON bodies.
class RivenResponse {
  final http.Response response;
  final dynamic data;
  const RivenResponse(this.response, this.data);

  int get statusCode => response.statusCode;
}

/// Verdict of [RivenHttpClient.classify]: what a 3xx/401/403 answer means,
/// and whether Riven is the one answering.
///
/// Riven refuses in three shapes, none of them ambiguous:
///
///   * The frontend's `hooks.server.ts` guards every protected route —
///     `/api/v1/*` included — with a 307 to its login page when the cookie
///     names no live session. The hook runs before any route, so the request
///     never reached the backend and is safe to replay after a re-login.
///   * The backend's `resolve_api_key` answers 401 `{"detail": …}` for a
///     missing or wrong `x-api-key`.
///   * better-auth rejects a sign-in with `{"code": …, "message": …}` (401
///     for a wrong password, 422 for a malformed username).
///
/// Anything else carrying a 3xx/401/403 was not Riven: an SSO redirect, an
/// HTTP Basic challenge, Cloudflare Access, a forward-auth wall.
enum RivenRejection {
  /// Success or an ordinary API failure, without authentication evidence.
  none,

  /// The frontend sent the request to its login page: re-login and replay.
  session,

  /// The backend refused the API key, or better-auth the credentials.
  credentials,

  /// Something in front of Riven answered. Never a reason to touch the
  /// stored session.
  intermediary,
}

/// Thin wrapper around `package:http` for Riven API calls.
///
/// Carries whichever credential the session uses — the frontend's
/// `riven.session_token` cookie, captured from the sign-in `Set-Cookie` and
/// replayed as `Cookie:`, or the backend's `x-api-key` — and never follows
/// redirects, since the frontend's only redirect is the login bounce
/// [classify] needs to see.
class RivenHttpClient {
  final String baseUrl;
  final http.Client _http;
  final String? _apiKey;
  String? _cookie;

  RivenHttpClient({required String baseUrl, http.Client? httpClient, String? cookie, String? apiKey})
    : baseUrl = normalizeBaseUrl(baseUrl),
      _http = httpClient ?? platform.createPlatformClient(),
      _cookie = (cookie?.isNotEmpty ?? false) ? cookie : null,
      _apiKey = (apiKey?.isNotEmpty ?? false) ? apiKey : null;

  /// Current `riven.session_token` value (no `name=` prefix); null until a
  /// sign-in response is captured or [cookie] was seeded.
  String? get cookie => _cookie;

  set cookie(String? value) => _cookie = (value?.isNotEmpty ?? false) ? value : null;

  void dispose() => _http.close();

  /// Parse `Set-Cookie` from [response] and keep the session token. Returns
  /// true when a cookie was captured.
  ///
  /// `package:http` joins multiple `Set-Cookie` headers into one
  /// comma-delimited string. The token is URL-encoded and can't contain a
  /// literal comma, and better-auth's `session_data` cache cookie that rides
  /// along has a different name, so splitting on `,` and scanning each chunk
  /// for the `riven.session_token=` prefix is safe.
  bool captureSessionCookie(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return false;
    const prefix = '${RivenConstants.sessionCookieName}=';
    for (final chunk in raw.split(',')) {
      final trimmed = chunk.trimLeft();
      if (!trimmed.startsWith(prefix)) continue;
      final afterName = trimmed.substring(prefix.length);
      final end = afterName.indexOf(';');
      final value = (end == -1 ? afterName : afterName.substring(0, end)).trim();
      if (value.isEmpty) continue;
      _cookie = value;
      return true;
    }
    return false;
  }

  /// Send a request under [RivenConstants.apiPath], returning the decoded
  /// JSON body. No status throws here: the caller runs [classify] over the
  /// answer so a session rejection can feed its silent re-auth path.
  Future<RivenResponse> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    Duration timeout = RivenConstants.requestTimeout,
    bool authenticated = true,
  }) => _send(
    method,
    '${RivenConstants.apiPath}$path',
    query: query,
    body: body,
    timeout: timeout,
    authenticated: authenticated,
  );

  /// Send a request to the frontend's better-auth routes under
  /// [RivenConstants.authPath]. Cookie-bearing calls also carry the instance
  /// as `Origin`: better-auth refuses a cookie-authenticated mutation whose
  /// origin it can't check.
  Future<RivenResponse> sendAuth(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = RivenConstants.authTimeout,
    bool authenticated = true,
  }) => _send(
    method,
    '${RivenConstants.authPath}$path',
    body: body,
    timeout: timeout,
    authenticated: authenticated,
    origin: authenticated && _cookie != null,
  );

  /// Send a GET to one of the frontend's own routes ([path] from the instance
  /// root): its TMDB/AniList proxies and id resolver. These exist only on the
  /// web app, behind the same login as its `/api/v1` proxy.
  Future<RivenResponse> sendWeb(
    String path, {
    Map<String, Object?>? query,
    Duration timeout = RivenConstants.requestTimeout,
  }) => _send('GET', path, query: query, timeout: timeout, authenticated: true);

  Future<RivenResponse> _send(
    String method,
    String fullPath, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    required Duration timeout,
    required bool authenticated,
    bool origin = false,
  }) async {
    if (!const {'GET', 'POST', 'DELETE'}.contains(method)) {
      throw ArgumentError('Unsupported HTTP method: $method');
    }
    final uri = _uri(fullPath, query);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (authenticated && _cookie != null) 'Cookie': '${RivenConstants.sessionCookieName}=$_cookie',
      if (authenticated && _apiKey != null) RivenConstants.apiKeyHeader: _apiKey,
      if (origin) 'Origin': baseUrl,
      if (body != null) 'Content-Type': 'application/json',
    };
    final sw = Stopwatch()..start();
    // Abortable so a timeout releases transport resources. A timed-out write
    // may already have committed server-side and must never be replayed.
    // Redirects are not followed: the frontend's login bounce is a verdict
    // [classify] reads, and following it would turn it into an HTML 200.
    final response = await sendAbortableHttpRequest(
      _http,
      method,
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
      timeout: timeout,
      operation: 'Riven $method $fullPath',
      followRedirects: false,
    );
    appLogger.d('Riven $method $fullPath -> ${response.statusCode} (${sw.elapsedMilliseconds}ms)');
    return RivenResponse(response, TrackerHttpClient.decodeJson(response.body));
  }

  Uri _uri(String fullPath, Map<String, Object?>? query) {
    final base = Uri.parse('$baseUrl$fullPath');
    final encoded = encodeQueryParameters(query);
    return encoded.isEmpty ? base : base.replace(query: encoded);
  }

  /// What [res] says about the caller's standing with Riven — and whether
  /// Riven is the one saying it. See [RivenRejection] for the shapes Riven
  /// actually emits; a JSON body alone proves nothing.
  static RivenRejection classify(RivenResponse res) {
    final code = res.statusCode;
    if (code >= 300 && code < 400) {
      final location = res.response.headers['location'];
      final path = location == null ? null : Uri.tryParse(location)?.path;
      // `endsWith` keeps a frontend served under a sub-path recognizable.
      return path != null && path.endsWith(RivenConstants.loginPagePath)
          ? RivenRejection.session
          : RivenRejection.intermediary;
    }
    if (code != 401 && code != 403) return RivenRejection.none;
    final data = res.data;
    if (data is Map<String, dynamic> && (data['detail'] is String || data['code'] is String)) {
      return RivenRejection.credentials;
    }
    return RivenRejection.intermediary;
  }

  /// Throw [RivenProxyException] when [classify] says something in front of
  /// Riven answered; no-op otherwise.
  static void throwIfIntermediary(RivenResponse res) {
    if (classify(res) != RivenRejection.intermediary) return;
    throw RivenProxyException(
      'An auth proxy answered instead of Riven (HTTP ${res.statusCode})',
      display: t.riven.behindAuthProxy,
      statusCode: res.statusCode,
    );
  }

  /// Throw the mapped exception for a 3xx/4xx/5xx response; no-op on success.
  /// Callers pick off the auth verdicts they care about via [classify] first.
  static void throwForStatus(RivenResponse res) {
    throwIfIntermediary(res);
    final code = res.statusCode;
    if (code >= 200 && code < 300) return;
    final data = res.data;
    // FastAPI reports `detail`; better-auth and the frontend's own SvelteKit
    // errors report `message`.
    final raw = data is Map<String, dynamic> ? data['detail'] ?? data['message'] : null;
    throw RivenApiException(raw is String && raw.isNotEmpty ? raw : 'HTTP $code', statusCode: code);
  }

  /// Trim whitespace and trailing slashes so session identity and request
  /// URLs agree on one canonical instance URL.
  static String normalizeBaseUrl(String input) {
    var v = canonicalizeBaseUrl(input);
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
