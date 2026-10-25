/// Constants for the Riven (rivenmedia/riven) REST API and the Riven web
/// frontend (rivenmedia/riven-frontend) that usually sits in front of it.
abstract final class RivenConstants {
  /// Every backend endpoint lives under this prefix. The frontend proxies the
  /// same paths, behind its own login, to the backend it holds the API key
  /// for — so one client speaks to either once authenticated.
  static const String apiPath = '/api/v1';

  /// The frontend's better-auth mount point.
  static const String authPath = '/api/auth';

  /// The page the frontend redirects every protected route to when the
  /// request carries no live session.
  static const String loginPagePath = '/auth/login';

  /// The frontend's TMDB and AniList proxies, which carry its own API keys.
  static const String tmdbPath = '/api/tmdb';
  static const String anilistPath = '/api/anilist';

  /// The frontend's id resolver: `GET /details/{indexer}/{type}/{id}` answers
  /// with a redirect to `/details/media/{id}/{tv|movie}` carrying the mapped
  /// id — TVDB from `tmdb/tv`, TMDB from `anilist` — or 404 when it has none.
  static const String detailsPath = '/details';

  /// better-auth session cookie, named by the frontend's `cookiePrefix`.
  static const String sessionCookieName = 'riven.session_token';

  /// Header the backend reads its API key from.
  static const String apiKeyHeader = 'x-api-key';

  /// Body of the backend's unauthenticated `GET /api/v1` answer, the one
  /// response that tells a Riven backend apart from anything else serving JSON.
  static const String backendRootMessage = 'Riven is running!';

  /// Default ports of a Riven install, tried for schemeless input that names
  /// no port of its own: the frontend container, then the backend's.
  static const int defaultFrontendPort = 3000;
  static const int defaultBackendPort = 8080;

  static const Duration probeTimeout = Duration(seconds: 8);
  static const Duration authTimeout = Duration(seconds: 20);
  static const Duration requestTimeout = Duration(seconds: 30);

  /// How often a detail screen re-reads a title Riven is still working on.
  /// Riven exposes state changes as server-sent events, but the frontend's
  /// `/api/v1` proxy buffers every answer as JSON, so a stream cannot reach a
  /// client signed in through it.
  static const Duration statePollInterval = Duration(seconds: 10);
}
