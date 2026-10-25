import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';
import '../../models/catalog/catalog_metadata.dart';
import '../../models/riven/riven_item.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../riven/riven_client.dart';
import 'catalog_source.dart';

/// The Explore shelves Riven fills from its own library, in display order:
/// where each requested title stands rather than what to discover. Each
/// shelf is one `GET /api/v1/items` state filter, newest request first.
enum RivenCatalogHub {
  inProgress([
    RivenItemState.requested,
    RivenItemState.indexed,
    RivenItemState.scraped,
    RivenItemState.downloaded,
    RivenItemState.symlinked,
  ]),
  needsAttention([RivenItemState.failed, RivenItemState.paused, RivenItemState.unknown]),
  recentlyAdded([RivenItemState.completed, RivenItemState.partiallyCompleted, RivenItemState.ongoing]),
  comingSoon([RivenItemState.unreleased]);

  final List<RivenItemState> states;
  const RivenCatalogHub(this.states);

  String get title => switch (this) {
    RivenCatalogHub.inProgress => t.riven.hubs.inProgress,
    RivenCatalogHub.needsAttention => t.riven.hubs.needsAttention,
    RivenCatalogHub.recentlyAdded => t.riven.hubs.recentlyAdded,
    RivenCatalogHub.comingSoon => t.riven.hubs.comingSoon,
  };
}

/// [CatalogSource] backed by what a Riven install tracks.
///
/// Wraps the [RivenClient] owned by `RivenAccountProvider` (not owned here —
/// never disposed by this class). Riven has no discovery feed and no
/// watchlist: its shelves are provider hubs ([RivenCatalogHub]) over its own
/// item list, and requesting new titles happens from any source's detail
/// screen through the account's client.
class RivenCatalogSource implements CatalogSource, CatalogHubSource {
  final RivenClient client;
  final WatchlistChangeNotifier _watchlistChanges = WatchlistChangeNotifier();

  RivenCatalogSource(this.client);

  @override
  CatalogSourceId get id => CatalogSourceId.riven;

  @override
  String get displayName => 'Riven';

  /// Every shelf is a hub: the fixed rows name discovery feeds Riven lacks.
  @override
  List<CatalogRowId> get supportedRows => const [];

  @override
  bool get supportsWatchlist => false;

  @override
  Listenable get watchlistChanges => _watchlistChanges;

  @override
  Future<CatalogPage> fetchRow(CatalogRowId row, {int page = 1, int limit = 25}) =>
      throw ArgumentError('Riven does not serve ${row.name}');

  /// One request per shelf, concurrently. A shelf that fails is left out so
  /// the others still render; only when every shelf fails does the load fail.
  @override
  Future<List<CatalogHub>> fetchHubs({int limit = 25}) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final loaded = await Future.wait([
      for (final hub in RivenCatalogHub.values)
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
    final hubs = [...loaded.nonNulls];
    if (hubs.isEmpty && firstError != null) Error.throwWithStackTrace(firstError!, firstStackTrace!);
    return hubs;
  }

  @override
  Future<CatalogPage> fetchHub(String id, {int page = 1, int limit = 25}) {
    final hub = RivenCatalogHub.values.asNameMap()[id];
    if (hub == null) throw ArgumentError('Unknown Riven shelf: $id');
    return _fetch(hub, page: page, limit: limit);
  }

  Future<CatalogPage> _fetch(RivenCatalogHub hub, {required int page, required int limit}) async {
    final result = await client.getItems(states: hub.states, page: page, limit: limit);
    return CatalogPage(
      items: [
        for (final item in result.items)
          if (toCatalogItem(item) case final CatalogItem catalogItem) catalogItem,
      ],
      hasMore: result.hasMore,
      totalResults: result.totalItems,
    );
  }

  /// Riven's own title search (`?search=` matches titles, and IMDb/TMDB/TVDB
  /// ids in their `tt…`/`tmdb_…`/`tvdb_…` forms) — what it tracks, not the
  /// wider catalog.
  @override
  Future<List<CatalogItem>> search(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final result = await client.getItems(search: trimmed, limit: limit);
    return [
      for (final item in result.items)
        if (toCatalogItem(item) case final CatalogItem catalogItem) catalogItem,
    ];
  }

  /// Riven stores no overview, artwork beyond the poster, cast or
  /// recommendations, so there is nothing to enrich the row item with. The
  /// detail screen still resolves library copies and Riven's live state by id.
  @override
  Future<CatalogDetail> fetchDetail(CatalogItem item, {int castLimit = 20, int relatedLimit = 20}) async =>
      CatalogDetail(item: item);

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
      posterVariants: _tmdbPosterVariants(item.posterUrl),
      serverState: _serverState(item.state),
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

  static final RegExp _tmdbImage = RegExp(r'^(https://image\.tmdb\.org/t/p/)[^/]+(/.+)$');

  /// Riven stores movie posters as one sized TMDB URL (`…/t/p/w500/x.jpg`);
  /// TMDB serves the same file at every size, so publish the others for the
  /// card to pick from. TheTVDB artwork comes in one size only.
  static Map<int, String>? _tmdbPosterVariants(String? url) {
    final match = url == null ? null : _tmdbImage.firstMatch(url);
    if (match == null) return null;
    final base = match.group(1)!;
    final file = match.group(2)!;
    return {
      for (final width in const [92, 154, 185, 342, 500, 780]) width: '${base}w$width$file',
    };
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
