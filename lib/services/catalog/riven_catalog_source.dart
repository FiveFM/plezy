import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';
import '../../models/catalog/catalog_metadata.dart';
import '../../models/riven/riven_item.dart';
import '../../models/riven/riven_web_item.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../riven/riven_client.dart';
import 'catalog_source.dart';

/// The Explore shelves Riven fills, in display order: where each requested
/// title stands, then what the Riven web app offers to discover — the
/// trending feeds of its home page and TMDB's popular lists — then what is
/// still unreleased.
///
/// Library shelves are one `GET /api/v1/items` state filter each, newest
/// request first. Discovery shelves come from the web app's TMDB and AniList
/// proxies, so a session straight to the backend has only the library ones.
enum RivenCatalogHub {
  inProgress,
  needsAttention,
  recentlyAdded,
  trendingMovies,
  trendingShows,
  trendingAnime,
  popularMovies,
  popularShows,
  comingSoon;

  /// The item states a library shelf filters on; null for a discovery shelf.
  List<RivenItemState>? get states => switch (this) {
    RivenCatalogHub.inProgress => const [
      RivenItemState.requested,
      RivenItemState.indexed,
      RivenItemState.scraped,
      RivenItemState.downloaded,
      RivenItemState.symlinked,
    ],
    RivenCatalogHub.needsAttention => const [RivenItemState.failed, RivenItemState.paused, RivenItemState.unknown],
    RivenCatalogHub.recentlyAdded => const [
      RivenItemState.completed,
      RivenItemState.partiallyCompleted,
      RivenItemState.ongoing,
    ],
    RivenCatalogHub.comingSoon => const [RivenItemState.unreleased],
    RivenCatalogHub.trendingMovies ||
    RivenCatalogHub.trendingShows ||
    RivenCatalogHub.trendingAnime ||
    RivenCatalogHub.popularMovies ||
    RivenCatalogHub.popularShows => null,
  };

  bool get needsWebApp => states == null;

  /// The discovery shelves reuse the Explore row titles other sources give
  /// the same feeds.
  String get title => switch (this) {
    RivenCatalogHub.inProgress => t.riven.hubs.inProgress,
    RivenCatalogHub.needsAttention => t.riven.hubs.needsAttention,
    RivenCatalogHub.recentlyAdded => t.riven.hubs.recentlyAdded,
    RivenCatalogHub.trendingMovies => t.explore.rows.trendingMovies,
    RivenCatalogHub.trendingShows => t.explore.rows.trendingShows,
    RivenCatalogHub.trendingAnime => t.explore.rows.trendingAnime,
    RivenCatalogHub.popularMovies => t.explore.rows.popularMovies,
    RivenCatalogHub.popularShows => t.explore.rows.popularShows,
    RivenCatalogHub.comingSoon => t.riven.hubs.comingSoon,
  };
}

/// [CatalogSource] backed by a Riven install: what it tracks and, through
/// its web app, what there is to request.
///
/// Wraps the [RivenClient] owned by `RivenAccountProvider` (not owned here —
/// never disposed by this class). Riven has no watchlist: its shelves are
/// provider hubs ([RivenCatalogHub]), and requesting a title happens from the
/// detail screen through the account's client.
class RivenCatalogSource implements CatalogSource, CatalogHubSource {
  final RivenClient client;
  final WatchlistChangeNotifier _watchlistChanges = WatchlistChangeNotifier();

  RivenCatalogSource(this.client);

  @override
  CatalogSourceId get id => CatalogSourceId.riven;

  @override
  String get displayName => 'Riven';

  /// Every shelf is a hub, so library and discovery shelves interleave in
  /// [RivenCatalogHub] order; the fixed rows always render ahead of hubs.
  @override
  List<CatalogRowId> get supportedRows => const [];

  @override
  bool get supportsWatchlist => false;

  @override
  Listenable get watchlistChanges => _watchlistChanges;

  @override
  Future<CatalogPage> fetchRow(CatalogRowId row, {int page = 1, int limit = 25}) =>
      throw ArgumentError('Riven does not serve ${row.name}');

  /// The shelves this session can fill.
  List<RivenCatalogHub> get hubs => [
    for (final hub in RivenCatalogHub.values)
      if (!hub.needsWebApp || client.hasWebApp) hub,
  ];

  /// One request per shelf, concurrently. A shelf that fails is left out so
  /// the others still render; only when every shelf fails does the load fail.
  @override
  Future<List<CatalogHub>> fetchHubs({int limit = 25}) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final loaded = await Future.wait([
      for (final hub in hubs)
        () async {
          try {
            return CatalogHub(
              id: hub.name,
              title: hub.title,
              page: await _fetch(hub, page: 1, limit: limit),
            );
          } catch (error, stackTrace) {
            appLogger.w('Riven: ${hub.name} shelf failed', error: error);
            firstError ??= error;
            firstStackTrace ??= stackTrace;
            return null;
          }
        }(),
    ]);
    final fetched = [...loaded.nonNulls];
    if (fetched.isEmpty && firstError != null) Error.throwWithStackTrace(firstError!, firstStackTrace!);
    return fetched;
  }

  @override
  Future<CatalogPage> fetchHub(String id, {int page = 1, int limit = 25}) {
    final hub = RivenCatalogHub.values.asNameMap()[id];
    if (hub == null || !hubs.contains(hub)) throw ArgumentError('Unknown Riven shelf: $id');
    return _fetch(hub, page: page, limit: limit);
  }

  /// TMDB and AniList pages are a fixed 20 items; [limit] only sizes the
  /// library shelves. Trending answers carry no paging, so a full page is
  /// read as "there is more".
  Future<CatalogPage> _fetch(RivenCatalogHub hub, {required int page, required int limit}) async {
    if (hub.states case final List<RivenItemState> states) {
      final result = await client.getItems(states: states, page: page, limit: limit);
      return CatalogPage(
        items: [
          for (final item in result.items)
            if (toCatalogItem(item) case final CatalogItem catalogItem) catalogItem,
        ],
        hasMore: result.hasMore,
        totalResults: result.totalItems,
      );
    }
    if (hub == RivenCatalogHub.trendingAnime) {
      final anime = await client.getTrendingAnime(page: page);
      return CatalogPage(
        items: [
          for (final item in anime)
            if (fromAnime(item) case final CatalogItem catalogItem) catalogItem,
        ],
        hasMore: anime.length >= _webPageSize,
      );
    }
    final result = await switch (hub) {
      RivenCatalogHub.trendingMovies => client.getTrending(MediaKind.movie, page: page),
      RivenCatalogHub.trendingShows => client.getTrending(MediaKind.show, page: page),
      RivenCatalogHub.popularMovies => client.getPopular(MediaKind.movie, page: page),
      RivenCatalogHub.popularShows => client.getPopular(MediaKind.show, page: page),
      _ => throw StateError('${hub.name} is not a TMDB shelf'),
    };
    return _tmdbCatalogPage(result);
  }

  static const _webPageSize = 20;

  CatalogPage _tmdbCatalogPage(RivenTmdbPage result) => CatalogPage(
    items: [
      for (final item in result.results)
        if (fromTmdb(item) case final CatalogItem catalogItem) catalogItem,
    ],
    hasMore: switch ((result.page, result.totalPages)) {
      (final int page, final int totalPages) => page < totalPages,
      _ => result.results.length >= _webPageSize,
    },
    totalResults: result.totalResults,
  );

  /// Through the web app, TMDB's movie and show search — the same search its
  /// Explore page runs — merged by popularity; it finds what Riven already
  /// tracks too. A bare backend searches only Riven's own titles (`?search=`
  /// matches titles, and IMDb/TMDB/TVDB ids in their `tt…`/`tmdb_…`/`tvdb_…`
  /// forms).
  @override
  Future<List<CatalogItem>> search(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (!client.hasWebApp) {
      final result = await client.getItems(search: trimmed, limit: limit);
      return [
        for (final item in result.items)
          if (toCatalogItem(item) case final CatalogItem catalogItem) catalogItem,
      ];
    }
    final movies = client.searchTmdb(MediaKind.movie, trimmed);
    final shows = client.searchTmdb(MediaKind.show, trimmed);
    final results = [...(await movies).results, ...(await shows).results]
      ..sort((a, b) => (b.popularity ?? 0).compareTo(a.popularity ?? 0));
    return [
      for (final item in results)
        if (fromTmdb(item) case final CatalogItem catalogItem) catalogItem,
    ].take(limit).toList();
  }

  /// Fills in the ids a request needs, which the discovery feeds leave out:
  /// Riven takes shows by TVDB id, TMDB lists carry only their own, and the
  /// AniList feed carries only AniList's. The web app's resolver maps them
  /// (AniList → TMDB → TVDB). Riven stores no overview, cast or
  /// recommendations, so there is nothing else to add; a failed lookup keeps
  /// the row item as it is.
  @override
  Future<CatalogDetail> fetchDetail(CatalogItem item, {int castLimit = 20, int relatedLimit = 20}) async {
    if (!client.hasWebApp) return CatalogDetail(item: item);
    try {
      var tmdb = item.ids.tmdb;
      final anilist = item.ids.anilist;
      if (tmdb == null && anilist != null) {
        tmdb = await client.resolveAnimeTmdbId(anilist, movie: item.kind == MediaKind.movie);
      }
      int? tvdb;
      if (item.kind == MediaKind.show && item.ids.tvdb == null && tmdb != null) {
        tvdb = await client.resolveTvdbId(tmdb);
      }
      if (tmdb == item.ids.tmdb && tvdb == null) return CatalogDetail(item: item);
      return CatalogDetail(
        item: item.enrichedWith(
          CatalogItem(
            source: CatalogSourceId.riven,
            kind: item.kind,
            title: '',
            ids: CatalogItemIds(tmdb: tmdb, tvdb: tvdb),
          ),
        ),
      );
    } catch (error) {
      appLogger.w('Riven: id lookup failed for ${item.identityKey}', error: error);
      return CatalogDetail(item: item);
    }
  }

  /// Riven keys movies by TMDB id and shows by TVDB id; anything else cannot
  /// be one of its items. The watchlist action stays hidden regardless
  /// ([supportsWatchlist] is false).
  @override
  Future<CatalogItemIds?> resolveItemIds(MediaKind kind, ExternalIds external) async {
    final keyed = switch (kind) {
      MediaKind.movie => external.tmdb != null,
      MediaKind.show => external.tvdb != null,
      _ => false,
    };
    return keyed ? CatalogItemIds(tmdb: external.tmdb, tvdb: external.tvdb, imdb: external.imdb) : null;
  }

  // Riven has no watchlist: membership is always unknown and mutations are
  // programming errors (the action is hidden when supportsWatchlist is false).

  @override
  Future<void> ensureWatchlistLoaded() => Future.value();

  @override
  bool? isOnWatchlist(MediaKind kind, CatalogItemIds ids) => null;

  @override
  Future<void> addToWatchlist(MediaKind kind, CatalogItemIds ids) => throw UnsupportedError('Riven has no watchlist');

  @override
  Future<void> removeFromWatchlist(MediaKind kind, CatalogItemIds ids) =>
      throw UnsupportedError('Riven has no watchlist');

  /// The catalog form of a tracked movie or show; null for the seasons and
  /// episodes a show tracks internally, and for untitled rows.
  @visibleForTesting
  static CatalogItem? toCatalogItem(RivenItem item) {
    final kind = item.kind;
    final title = item.title?.trim();
    if ((kind != MediaKind.movie && kind != MediaKind.show) || title == null || title.isEmpty) return null;
    final airedAt = item.airedAt;
    return CatalogItem(
      source: CatalogSourceId.riven,
      kind: kind,
      title: title,
      year: airedAt?.year,
      releaseDate: airedAt,
      rating: item.rating,
      genres: _genres(item.genres),
      certification: _nonEmpty(item.contentRating),
      ids: CatalogItemIds(
        tmdb: int.tryParse(item.tmdbId ?? ''),
        tvdb: int.tryParse(item.tvdbId ?? ''),
        imdb: _nonEmpty(item.imdbId),
      ),
      posterUrl: _nonEmpty(item.posterUrl),
      posterVariants: _tmdbVariants(item.posterUrl, _posterWidths),
      serverState: _serverState(item.state),
    );
  }

  /// The catalog form of a TMDB list entry; null for the people and
  /// companies search mixes in, and for untitled entries.
  @visibleForTesting
  static CatalogItem? fromTmdb(RivenTmdbItem item) {
    final kind = switch (item.mediaType) {
      'movie' => MediaKind.movie,
      'tv' => MediaKind.show,
      _ => null,
    };
    final title = _nonEmpty(item.title);
    if (kind == null || title == null) return null;
    final originalTitle = _nonEmpty(item.originalTitle);
    final language = _nonEmpty(item.originalLanguage)?.toLowerCase();
    return CatalogItem(
      source: CatalogSourceId.riven,
      kind: kind,
      title: title,
      year: item.year,
      overview: _nonEmpty(item.overview),
      rating: item.voteAverage,
      votes: item.voteCount,
      ids: CatalogItemIds(tmdb: item.id),
      posterUrl: _nonEmpty(item.posterUrl),
      backdropUrl: _nonEmpty(item.backdropUrl),
      posterVariants: _tmdbVariants(item.posterUrl, _posterWidths),
      backdropVariants: _tmdbVariants(item.backdropUrl, _backdropWidths),
      releaseDate: DateTime.tryParse(item.releaseDate ?? item.firstAirDate ?? ''),
      originalTitle: originalTitle == title ? null : originalTitle,
      languages: language == null ? null : [language],
    );
  }

  /// The catalog form of an AniList trending entry. Films are movies; every
  /// other format is a series as far as Riven is concerned.
  @visibleForTesting
  static CatalogItem? fromAnime(RivenAnimeItem item) {
    final title = _nonEmpty(item.title);
    if (title == null) return null;
    final poster = _nonEmpty(item.posterUrl);
    return CatalogItem(
      source: CatalogSourceId.riven,
      kind: item.format == 'MOVIE' ? MediaKind.movie : MediaKind.show,
      title: title,
      year: item.year,
      ids: CatalogItemIds(anilist: item.id),
      posterUrl: poster,
      posterVariants: _anilistVariants(poster),
      format: _anilistFormat(item.format),
    );
  }

  /// Riven's state in the vocabulary the catalog cards already badge: a file
  /// in the library is available, a title moving through the pipeline is
  /// requested or processing, and a failure is a failed request. Paused and
  /// unknown claim nothing.
  static CatalogServerState? _serverState(RivenItemState state) => switch (state) {
    RivenItemState.completed => const CatalogServerState(availability: CatalogAvailability.available),
    RivenItemState.partiallyCompleted ||
    RivenItemState.ongoing => const CatalogServerState(availability: CatalogAvailability.partiallyAvailable),
    RivenItemState.requested ||
    RivenItemState.indexed ||
    RivenItemState.unreleased => const CatalogServerState(request: CatalogRequestState.approved),
    RivenItemState.scraped ||
    RivenItemState.downloaded ||
    RivenItemState.symlinked => const CatalogServerState(request: CatalogRequestState.processing),
    RivenItemState.failed => const CatalogServerState(request: CatalogRequestState.failed),
    RivenItemState.paused || RivenItemState.unknown => null,
  };

  /// AniList `format`, as the AniList catalog source maps it.
  static CatalogFormat? _anilistFormat(String? format) => switch (format) {
    null => null,
    'TV' => CatalogFormat.tv,
    'TV_SHORT' => CatalogFormat.tvShort,
    'MOVIE' => CatalogFormat.movie,
    'SPECIAL' => CatalogFormat.special,
    'OVA' => CatalogFormat.ova,
    'ONA' => CatalogFormat.ona,
    'MUSIC' => CatalogFormat.music,
    _ => CatalogFormat.other,
  };

  /// Riven lowercases indexer genres (`science fiction`); title-case them back
  /// for display.
  static List<String>? _genres(List<String>? raw) {
    final genres = [
      for (final genre in raw ?? const <String>[])
        if (_nonEmpty(genre) case final String value)
          value.split(' ').map((word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1)).join(' '),
    ];
    return genres.isEmpty ? null : genres;
  }

  static const _posterWidths = [92, 154, 185, 342, 500, 780];
  static const _backdropWidths = [300, 780, 1280];

  static final RegExp _tmdbImage = RegExp(r'^(https://image\.tmdb\.org/t/p/)[^/]+(/.+)$');

  /// Riven and its web app hand out one sized TMDB URL (`…/t/p/w500/x.jpg`);
  /// TMDB serves the same file at every size, so publish the others for the
  /// surface to pick from. TheTVDB artwork comes in one size only.
  static Map<int, String>? _tmdbVariants(String? url, List<int> widths) {
    final match = url == null ? null : _tmdbImage.firstMatch(url);
    if (match == null) return null;
    final base = match.group(1)!;
    final file = match.group(2)!;
    return {for (final width in widths) width: '${base}w$width$file'};
  }

  /// The AniList proxy hands out AniList's `large` cover, which lives under
  /// `/cover/medium/` at 230px; the same file under `/cover/large/` is the
  /// 460px `extraLarge`.
  static Map<int, String>? _anilistVariants(String? url) {
    if (url == null || !url.contains('/cover/medium/')) return null;
    return {230: url, 460: url.replaceFirst('/cover/medium/', '/cover/large/')};
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  void dispose() {
    _watchlistChanges.dispose();
  }
}
