import 'dart:async';

import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../models/riven/riven_item.dart';
import '../../models/riven/riven_session.dart';
import '../../models/riven/riven_web_item.dart';
import '../../utils/app_logger.dart';
import '../trackers/future_coalescer.dart';
import 'riven_auth_service.dart';
import 'riven_constants.dart';
import 'riven_exceptions.dart';
import 'riven_http_client.dart';

/// Authenticated Riven API client, scoped to one [RivenSession].
///
/// When the frontend bounces a request to its login page (the cookie expired
/// or was signed out elsewhere) it re-logins silently via
/// [RivenAuthService.reauth] with the stored password, swaps the cookie, and
/// replays the request once — the bounce happens before the frontend proxies
/// anything, so even a write never reached the backend. Concurrent re-auths
/// coalesce within this client binding so a burst of in-flight rejections
/// triggers a single sign-in.
class RivenClient {
  final FutureCoalescer<void> _reauth = FutureCoalescer();
  bool _disposed = false;
  int _cookieGeneration = 0;

  RivenSession _session;
  final RivenHttpClient _http;
  final RivenAuthService _auth;

  /// Fired when the session can't be recovered (rejected credentials, a
  /// rotated API key, no stored password). The owning provider clears local
  /// state.
  final void Function() onSessionInvalidated;

  /// Fired when re-auth or a version read changes the session so the owner
  /// persists it.
  final void Function(RivenSession session)? onSessionUpdated;

  RivenClient(
    RivenSession session, {
    required this.onSessionInvalidated,
    this.onSessionUpdated,
    RivenAuthService? authService,
    http.Client? httpClient,
  }) : _session = session,
       _http = RivenHttpClient(
         baseUrl: session.baseUrl,
         httpClient: httpClient,
         cookie: session.method == RivenAuthMethod.frontend ? session.cookie : null,
         apiKey: session.method == RivenAuthMethod.apiKey ? session.secret : null,
       ),
       _auth = authService ?? RivenAuthService();

  RivenSession get session => _session;

  void dispose() {
    _disposed = true;
    _http.dispose();
  }

  // ---------- Instance ----------

  /// Re-read the backend version and adopt it when it changed. Doubles as the
  /// bind-time session check: an expired cookie re-logins here, off the
  /// critical path, instead of on the first status lookup a screen waits on.
  Future<void> refreshVersion() async {
    // The backend mounts its root at `/api/v1/`; only the frontend's proxy
    // takes the bare path (see `RivenAuthService`).
    final data = await _request('GET', _session.method == RivenAuthMethod.apiKey ? '/' : '');
    final version = data is Map<String, dynamic> ? data['version'] : null;
    if (version is! String || version == _session.version || _disposed) return;
    _adopt(_session.copyWith(version: version));
  }

  // ---------- Items ----------

  /// The movie or show Riven tracks for these ids, or null when it tracks
  /// none of them.
  ///
  /// Riven keys movies by TMDB and shows by TVDB; a show indexed through TVDB
  /// carries no TMDB id at all. IMDb is the shared fallback, for the catalog
  /// rows that never resolved the native id. `GET /items?search=` filters the
  /// list rather than looking one item up, so a miss is an empty page — not
  /// the 500 the single-item route answers it with.
  Future<RivenItem?> findItem(MediaKind kind, {int? tmdbId, int? tvdbId, String? imdbId}) async {
    final type = _itemType(kind);
    if (type == null) return null;
    final searches = [
      if (kind == MediaKind.movie && tmdbId != null) 'tmdb_$tmdbId',
      if (kind == MediaKind.show && tvdbId != null) 'tvdb_$tvdbId',
      if (imdbId != null && imdbId.startsWith('tt')) imdbId,
    ];
    for (final search in searches) {
      final page = await getItems(search: search, type: type, limit: 1);
      if (page.items.firstOrNull case final RivenItem item) return item;
    }
    return null;
  }

  /// One page of tracked movies and shows, newest request first, optionally
  /// narrowed to [states].
  Future<RivenItemPage> getItems({
    String? search,
    String? type,
    List<RivenItemState>? states,
    int page = 1,
    int limit = 50,
  }) async {
    final data = await _request(
      'GET',
      '/items',
      query: {
        'page': page,
        'limit': limit,
        // Seasons and episodes are a show's own bookkeeping; the queue lists
        // what was asked for.
        'type': type ?? const ['movie', 'show'],
        if (states != null && states.isNotEmpty) 'states': [for (final state in states) state.wire],
        'search': ?search,
      },
    );
    return RivenItemPage.fromJson(data as Map<String, dynamic>);
  }

  /// Queue a title. Riven only accepts movies by TMDB id and shows by TVDB
  /// id, and answers an id it already tracks with "added 0" rather than an
  /// error.
  Future<void> addItem(MediaKind kind, {int? tmdbId, int? tvdbId}) async {
    final body = switch (kind) {
      MediaKind.movie when tmdbId != null => {
        'tmdb_ids': ['$tmdbId'],
        'media_type': 'movie',
      },
      MediaKind.show when tvdbId != null => {
        'tvdb_ids': ['$tvdbId'],
        'media_type': 'tv',
      },
      _ => throw ArgumentError('Riven takes movies by TMDB id and shows by TVDB id'),
    };
    await _request('POST', '/items/add', body: body);
  }

  /// Clear the scrape state and send the item back through the pipeline.
  Future<void> retryItem(int id) => _idAction('POST', '/items/retry', id);

  /// Blacklist the release Riven picked and start over, for a file that
  /// turned out broken or wrong.
  Future<void> resetItem(int id) => _idAction('POST', '/items/reset', id);

  /// Stop tracking the item and drop it from the library mount.
  Future<void> removeItem(int id) => _idAction('DELETE', '/items/remove', id);

  /// Riven's id-list routes all take `{"ids": ["…"]}` (`IdListPayload`).
  Future<void> _idAction(String method, String path, int id) async {
    await _request(
      method,
      path,
      body: {
        'ids': ['$id'],
      },
    );
  }

  static String? _itemType(MediaKind kind) => switch (kind) {
    MediaKind.movie => 'movie',
    MediaKind.show => 'show',
    _ => null,
  };

  // ---------- Web app (frontend sessions only) ----------

  /// Whether the session goes through the web app, whose TMDB/AniList proxies
  /// and id resolver back the discovery shelves. A bare backend has neither.
  bool get hasWebApp => _session.method == RivenAuthMethod.frontend;

  /// TMDB trending for [kind] over the web app's default window, a day.
  Future<RivenTmdbPage> getTrending(MediaKind kind, {int page = 1}) =>
      _tmdbPage('${RivenConstants.tmdbPath}/${_tmdbType(kind)}/day/trending', {'page': page});

  /// TMDB discover sorted by popularity: TMDB's own popular list.
  Future<RivenTmdbPage> getPopular(MediaKind kind, {int page = 1}) =>
      _tmdbPage('${RivenConstants.tmdbPath}/discover/${_tmdbType(kind)}', {'sort_by': 'popularity.desc', 'page': page});

  /// TMDB title search. Without `searchMode=search` the route ignores the
  /// query and answers with discover results.
  Future<RivenTmdbPage> searchTmdb(MediaKind kind, String query, {int page = 1}) => _tmdbPage(
    '${RivenConstants.tmdbPath}/search/${_tmdbType(kind)}',
    {'query': query, 'searchMode': 'search', 'page': page},
  );

  Future<RivenTmdbPage> _tmdbPage(String path, Map<String, Object?> query) async {
    final data = await _request('GET', path, query: query, web: true);
    return RivenTmdbPage.fromJson(data as Map<String, dynamic>);
  }

  /// AniList trending, 20 per page. The proxy passes AniList's GraphQL
  /// envelope through (`data.Page.media`) without its page info.
  Future<List<RivenAnimeItem>> getTrendingAnime({int page = 1}) async {
    final data = await _request('GET', '${RivenConstants.anilistPath}/trending', query: {'page': page}, web: true);
    final media = switch (data) {
      {'data': {'Page': {'media': final List<dynamic> media}}} => media,
      _ => const <dynamic>[],
    };
    return [
      for (final item in media)
        if (item is Map<String, dynamic>) RivenAnimeItem.fromJson(item),
    ];
  }

  /// The TVDB id of the show TMDB knows as [tmdbId] — the id Riven takes
  /// shows by — or null when the web app has no mapping.
  Future<int?> resolveTvdbId(int tmdbId) => _resolve('${RivenConstants.detailsPath}/tmdb/tv/$tmdbId');

  /// The TMDB id of the anime AniList knows as [anilistId], or null when the
  /// web app has no mapping. The resolver only takes AniList's `TV` and
  /// `MOVIE` formats apart, so those two stand for every series and film.
  Future<int?> resolveAnimeTmdbId(int anilistId, {required bool movie}) =>
      _resolve('${RivenConstants.detailsPath}/anilist/${movie ? 'MOVIE' : 'TV'}/$anilistId');

  static final RegExp _resolvedDetails = RegExp(r'/details/media/(\d+)/(?:tv|movie)$');

  /// Reads the resolver's verdict off its redirect without following it: the
  /// target page is HTML, the id is in its path. A miss is a 404 (TMDB) or a
  /// JSON error body (AniList).
  Future<int?> _resolve(String path) async {
    final res = await _exchange('GET', path, web: true);
    final location = res.response.headers['location'];
    final match = location == null ? null : _resolvedDetails.firstMatch(Uri.tryParse(location)?.path ?? '');
    if (res.statusCode >= 300 && res.statusCode < 400 && match != null) return int.parse(match.group(1)!);
    if (res.statusCode == 404 || (res.statusCode == 200 && res.data is Map<String, dynamic>)) return null;
    RivenHttpClient.throwForStatus(res);
    return null;
  }

  static String _tmdbType(MediaKind kind) => switch (kind) {
    MediaKind.movie => 'movie',
    MediaKind.show => 'tv',
    _ => throw ArgumentError('TMDB lists hold movies and shows, not ${kind.name}'),
  };

  // ---------- Internals ----------

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    bool web = false,
  }) async {
    final res = await _exchange(method, path, query: query, body: body, web: web);
    RivenHttpClient.throwForStatus(res);
    return res.data;
  }

  /// One request with the session's auth handling — silent re-login and one
  /// replay on a login bounce, unlinking on a rejected API key — but no
  /// status verdict, for callers that read a redirect as the answer.
  /// [web] addresses [path] from the instance root instead of `/api/v1`.
  Future<RivenResponse> _exchange(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    bool web = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      _ensureActive();
      final cookieGeneration = _cookieGeneration;
      final res = web
          ? await _http.sendWeb(path, query: query)
          : await _http.send(method, path, query: query, body: body);
      _ensureActive();
      switch (RivenHttpClient.classify(res)) {
        case RivenRejection.session:
          if (attempt == 0) {
            if (_isCurrentCookie(cookieGeneration)) {
              try {
                await _reauth.run(() => _doReauth(cookieGeneration));
              } on RivenAuthException {
                if (_isCurrentCookie(cookieGeneration)) onSessionInvalidated();
                rethrow;
              }
            }
            _ensureActive();
            // Replay once, with whichever cookie the re-login — ours or a
            // concurrent one — issued.
            continue;
          }
          if (_isCurrentCookie(cookieGeneration)) onSessionInvalidated();
          throw RivenAuthException(
            'Session rejected after successful re-auth',
            statusCode: res.statusCode,
            display: t.riven.sessionRejectedAfterReauth,
          );
        case RivenRejection.credentials when _session.method == RivenAuthMethod.apiKey:
          if (_isCurrentCookie(cookieGeneration)) onSessionInvalidated();
          throw RivenAuthException(
            'Riven rejected the API key',
            statusCode: res.statusCode,
            display: t.riven.apiKeyRejected,
          );
        // Through the frontend, a backend 401 means the frontend's own
        // BACKEND_API_KEY is wrong — a server misconfiguration this session
        // can't fix, so it surfaces as the API failure it is.
        case RivenRejection.credentials || RivenRejection.intermediary || RivenRejection.none:
          break;
      }
      return res;
    }
  }

  bool _isCurrentCookie(int generation) => !_disposed && generation == _cookieGeneration;

  void _ensureActive() {
    if (_disposed) throw StateError('Riven client is disposed');
  }

  Future<void> _doReauth(int cookieGeneration) async {
    if (!_isCurrentCookie(cookieGeneration)) return;
    appLogger.d('Riven: session expired, re-authenticating silently');
    final next = await _auth.reauth(_session);
    if (!_isCurrentCookie(cookieGeneration)) return;
    // Invalidate every read issued for the old cookie, even if the server
    // happened to issue the same value on the replacement sign-in.
    _cookieGeneration++;
    _adopt(next);
  }

  void _adopt(RivenSession next) {
    if (_disposed) return;
    _session = next;
    if (next.method == RivenAuthMethod.frontend) _http.cookie = next.cookie;
    onSessionUpdated?.call(next);
  }
}
