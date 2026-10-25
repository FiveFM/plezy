import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/models/catalog/catalog_metadata.dart';
import 'package:plezy/models/riven/riven_item.dart';
import 'package:plezy/models/riven/riven_session.dart';
import 'package:plezy/models/riven/riven_web_item.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/riven_catalog_source.dart';
import 'package:plezy/services/riven/riven_client.dart';
import 'package:plezy/utils/external_ids.dart';

const _frontend = RivenSession(
  baseUrl: 'https://riven.example.com',
  method: RivenAuthMethod.frontend,
  identifier: 'alice',
  secret: '',
  cookie: 'cookie',
  userId: 'user-1',
  displayName: 'Alice',
  version: '1.0.0',
  createdAt: 0,
);

const _backend = RivenSession(
  baseUrl: 'http://riven.lan:8080',
  method: RivenAuthMethod.apiKey,
  identifier: '',
  secret: 'key',
  cookie: '',
  userId: '',
  displayName: '',
  version: '1.0.0',
  createdAt: 0,
);

Map<String, Object?> _item({
  String id = '1',
  String title = 'The Odyssey',
  String type = 'movie',
  String state = 'Completed',
  String? tmdb = '1368337',
  String? tvdb,
  String? poster = 'https://image.tmdb.org/t/p/w500/abc.jpg',
}) => {
  'id': id,
  'title': title,
  'type': type,
  'state': state,
  'tmdb_id': tmdb,
  'tvdb_id': tvdb,
  'imdb_id': 'tt33764258',
  'poster_path': poster,
  'aired_at': '2026-07-15 00:00:00',
  'genres': ['science fiction', 'action'],
  'rating': 8.0,
  'content_rating': 'PG-13',
  'requested_at': '2026-10-17 18:39:38.729835',
};

/// An entry as the web app's `transformTMDBList` shapes it.
Map<String, Object?> _tmdb({
  int id = 250923,
  String title = 'Nobody Wants This',
  String mediaType = 'tv',
  Object? year = 2024,
  double popularity = 50,
}) => {
  'id': id,
  'title': title,
  'poster_path': 'https://image.tmdb.org/t/p/w500/poster.jpg',
  'media_type': mediaType,
  'year': year,
  'vote_average': 7.3,
  'vote_count': 304,
  'popularity': popularity,
  'indexer': 'tmdb',
  'original_language': 'en',
  'overview': 'A podcaster and a rabbi fall in love.',
  'backdrop_path': 'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
  'genre_ids': [35, 18],
  'first_air_date': '2024-09-26',
  'original_title': title,
};

http.Response _json(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...?headers});

http.Response _page(List<Map<String, Object?>> items, {int page = 1, int totalPages = 1, int? totalItems}) => _json({
  'success': true,
  'items': items,
  'page': page,
  'limit': 25,
  'total_items': totalItems ?? items.length,
  'total_pages': totalPages,
});

http.Response _anime(List<Map<String, Object?>> media) => _json({
  'data': {
    'Page': {'media': media},
  },
});

/// Answers the library list per state filter and every web app feed with one
/// title, so each shelf the session can fill comes back non-empty.
Future<http.Response> _everyShelf(http.Request request) async {
  final path = request.url.path;
  if (path == '/api/v1/items') return _page([_item()]);
  if (path == '/api/anilist/trending') {
    return _anime([
      {'id': 195539, 'title': 'Cyberpunk: Edgerunners 2', 'media_type': 'ONA', 'year': 2026},
    ]);
  }
  if (path.startsWith('/api/tmdb/')) {
    return _json({
      'results': [_tmdb()],
    });
  }
  return fail('Unexpected ${request.url}');
}

RivenCatalogSource _source(
  Future<http.Response> Function(http.Request request) handler, {
  RivenSession session = _frontend,
}) {
  final client = RivenClient(session, onSessionInvalidated: () {}, httpClient: MockClient(handler));
  final source = RivenCatalogSource(client);
  addTearDown(() {
    source.dispose();
    client.dispose();
  });
  return source;
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('shelves', () {
    test('through the web app: library shelves, then its discovery feeds, in display order', () async {
      final paths = <String>[];
      final source = _source((request) {
        paths.add(request.url.path);
        return _everyShelf(request);
      });

      final hubs = await source.fetchHubs(limit: 10);

      expect(hubs.map((hub) => hub.id), [for (final hub in RivenCatalogHub.values) hub.name]);
      expect(hubs.map((hub) => hub.title).take(6), [
        t.riven.hubs.inProgress,
        t.riven.hubs.needsAttention,
        t.riven.hubs.recentlyAdded,
        t.explore.rows.trendingMovies,
        t.explore.rows.trendingShows,
        t.explore.rows.trendingAnime,
      ]);
      expect(
        paths,
        containsAll([
          '/api/tmdb/movie/day/trending',
          '/api/tmdb/tv/day/trending',
          '/api/anilist/trending',
          '/api/tmdb/discover/movie',
          '/api/tmdb/discover/tv',
        ]),
      );
    });

    test('straight to the backend: only the library shelves', () async {
      final source = _source(_everyShelf, session: _backend);

      final hubs = await source.fetchHubs();

      expect(hubs.map((hub) => hub.id), [
        for (final hub in RivenCatalogHub.values)
          if (!hub.needsWebApp) hub.name,
      ]);
      expect(() => source.fetchHub(RivenCatalogHub.trendingMovies.name), throwsArgumentError);
    });

    test('each library shelf filters on its own states', () async {
      final requested = <List<String>>[];
      final source = _source((request) async {
        requested.add(request.url.queryParametersAll['states']!);
        return _page([]);
      }, session: _backend);

      await source.fetchHubs();

      expect(requested, unorderedEquals([for (final hub in source.hubs) hub.states!.map((s) => s.wire)]));
    });

    test('a failing shelf is left out while the others render', () async {
      final source = _source((request) async {
        if (request.url.path == '/api/anilist/trending') return http.Response('boom', 500);
        return _everyShelf(request);
      });

      final hubs = await source.fetchHubs();

      expect(hubs.map((hub) => hub.id), isNot(contains(RivenCatalogHub.trendingAnime.name)));
      expect(hubs, hasLength(RivenCatalogHub.values.length - 1));
    });

    test('every shelf failing fails the load', () async {
      final source = _source((request) async => http.Response('boom', 500));

      await expectLater(source.fetchHubs(), throwsA(anything));
    });

    test('View All pages a library shelf through Riven paging', () async {
      late Uri seen;
      final source = _source((request) async {
        seen = request.url;
        return _page([_item()], page: 2, totalPages: 3, totalItems: 201);
      });

      final page = await source.fetchHub(RivenCatalogHub.inProgress.name, page: 2, limit: 100);

      expect(seen.queryParameters['page'], '2');
      expect(seen.queryParameters['limit'], '100');
      expect(page.hasMore, isTrue);
      expect(page.totalResults, 201);
      expect(() => source.fetchHub('nope'), throwsArgumentError);
    });

    test('pages discovery feeds by TMDB paging, or by a full page where trending has none', () async {
      final source = _source((request) async {
        expect(request.url.queryParameters['page'], '3');
        if (request.url.path == '/api/tmdb/discover/movie') {
          expect(request.url.queryParameters['sort_by'], 'popularity.desc');
          return _json({
            'results': [_tmdb(mediaType: 'movie')],
            'page': 3,
            'total_pages': 3,
            'total_results': 41,
          });
        }
        return _json({'results': List.generate(20, (index) => _tmdb(id: index + 1))});
      });

      final popular = await source.fetchHub(RivenCatalogHub.popularMovies.name, page: 3);
      final trending = await source.fetchHub(RivenCatalogHub.trendingShows.name, page: 3);

      expect(popular.hasMore, isFalse);
      expect(popular.totalResults, 41);
      expect(trending.hasMore, isTrue);
      expect(trending.items, hasLength(20));
    });
  });

  group('mapping', () {
    test('a tracked movie becomes a catalog item the cards can badge', () {
      final item = RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(state: 'Downloaded')))!;

      expect(item.source, CatalogSourceId.riven);
      expect(item.kind, MediaKind.movie);
      expect(item.year, 2026);
      expect(item.genres, ['Science Fiction', 'Action']);
      expect(item.certification, 'PG-13');
      expect(item.ids.tmdb, 1368337);
      expect(item.ids.imdb, 'tt33764258');
      expect(item.posterVariants?[185], 'https://image.tmdb.org/t/p/w185/abc.jpg');
      expect(item.serverState?.request, CatalogRequestState.processing);
    });

    test('Riven states land on availability and request badges', () {
      CatalogServerState? state(String wire) =>
          RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(state: wire)))!.serverState;

      expect(state('Completed')?.availability, CatalogAvailability.available);
      expect(state('Ongoing')?.availability, CatalogAvailability.partiallyAvailable);
      expect(state('Indexed')?.request, CatalogRequestState.approved);
      expect(state('Unreleased')?.request, CatalogRequestState.approved);
      expect(state('Failed')?.request, CatalogRequestState.failed);
      expect(state('Paused'), isNull);
    });

    test('a TheTVDB poster stays as is, and only movies and shows map', () {
      final show = RivenCatalogSource.toCatalogItem(
        RivenItem.fromJson(
          _item(type: 'show', tmdb: null, tvdb: '384541', poster: 'https://artworks.thetvdb.com/banners/a.jpg'),
        ),
      )!;
      expect(show.kind, MediaKind.show);
      expect(show.ids.tvdb, 384541);
      expect(show.posterVariants, isNull);

      expect(RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(type: 'episode'))), isNull);
      expect(RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(title: '  '))), isNull);
    });

    test('a TMDB entry keeps its artwork sizes, overview and score', () {
      final item = RivenCatalogSource.fromTmdb(RivenTmdbItem.fromJson(_tmdb()))!;

      expect(item.kind, MediaKind.show);
      expect(item.ids.tmdb, 250923);
      expect(item.ids.tvdb, isNull, reason: 'resolved on detail open');
      expect(item.year, 2024);
      expect(item.overview, 'A podcaster and a rabbi fall in love.');
      expect(item.rating, 7.3);
      expect(item.votes, 304);
      expect(item.releaseDate, DateTime(2024, 9, 26));
      expect(item.originalTitle, isNull, reason: 'same as the title');
      expect(item.languages, ['en']);
      expect(item.posterVariants?[342], 'https://image.tmdb.org/t/p/w342/poster.jpg');
      expect(item.backdropVariants?[780], 'https://image.tmdb.org/t/p/w780/backdrop.jpg');
    });

    test("a TMDB entry without a date reads the web app's N/A as no year; people are skipped", () {
      expect(RivenCatalogSource.fromTmdb(RivenTmdbItem.fromJson(_tmdb(year: 'N/A')))!.year, isNull);
      expect(RivenCatalogSource.fromTmdb(RivenTmdbItem.fromJson(_tmdb(mediaType: 'person'))), isNull);
    });

    test('an AniList entry carries its AniList id and format', () {
      final series = RivenCatalogSource.fromAnime(
        const RivenAnimeItem(
          id: 195539,
          title: 'Cyberpunk: Edgerunners 2',
          posterUrl: 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx195539.png',
          format: 'ONA',
          year: 2026,
        ),
      )!;
      final film = RivenCatalogSource.fromAnime(const RivenAnimeItem(id: 1, title: 'Film', format: 'MOVIE'))!;

      expect(series.kind, MediaKind.show);
      expect(series.ids.anilist, 195539);
      expect(series.format, CatalogFormat.ona);
      expect(series.posterVariants?[460], 'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx195539.png');
      expect(film.kind, MediaKind.movie);
    });
  });

  group('search', () {
    test('through the web app: TMDB movies and shows, most popular first', () async {
      final queries = <Map<String, String>>[];
      final source = _source((request) async {
        queries.add(request.url.queryParameters);
        return request.url.path == '/api/tmdb/search/movie'
            ? _json({
                'results': [_tmdb(id: 1, title: 'The Odyssey', mediaType: 'movie', popularity: 10)],
              })
            : _json({
                'results': [
                  _tmdb(id: 2, title: 'The Odyssey (1997)', popularity: 30),
                  _tmdb(id: 3, title: 'Someone', mediaType: 'person', popularity: 99),
                ],
              });
      });

      expect(await source.search('  '), isEmpty);
      final results = await source.search(' odyssey ');

      expect(queries, everyElement(containsPair('searchMode', 'search')));
      expect(queries, everyElement(containsPair('query', 'odyssey')));
      expect(results.map((item) => item.title), ['The Odyssey (1997)', 'The Odyssey']);
    });

    test("straight to the backend: Riven's own titles", () async {
      final searches = <String?>[];
      final source = _source((request) async {
        expect(request.url.path, '/api/v1/items');
        searches.add(request.url.queryParameters['search']);
        return _page([_item()]);
      }, session: _backend);

      final results = await source.search('odyssey');

      expect(searches, ['odyssey']);
      expect(results.single.title, 'The Odyssey');
    });
  });

  group('detail', () {
    const tmdbShow = CatalogItem(
      source: CatalogSourceId.riven,
      kind: MediaKind.show,
      title: 'Nobody Wants This',
      ids: CatalogItemIds(tmdb: 250923),
    );

    test("resolves a TMDB show's TVDB id off the web app's redirect", () async {
      final source = _source((request) async {
        expect(request.url.path, '/details/tmdb/tv/250923');
        return http.Response('', 307, headers: {'location': 'https://riven.example.com/details/media/450093/tv'});
      });

      final detail = await source.fetchDetail(tmdbShow);

      expect(detail.item.ids.tmdb, 250923);
      expect(detail.item.ids.tvdb, 450093);
      expect(detail.item.title, 'Nobody Wants This');
    });

    test('resolves an anime through AniList → TMDB → TVDB', () async {
      final paths = <String>[];
      final source = _source((request) async {
        paths.add(request.url.path);
        return switch (request.url.path) {
          '/details/anilist/TV/195539' => http.Response('', 307, headers: {'location': '/details/media/105248/tv'}),
          '/details/tmdb/tv/105248' => http.Response('', 307, headers: {'location': '/details/media/384541/tv'}),
          _ => fail('Unexpected ${request.url}'),
        };
      });

      final detail = await source.fetchDetail(
        const CatalogItem(
          source: CatalogSourceId.riven,
          kind: MediaKind.show,
          title: 'Cyberpunk: Edgerunners 2',
          ids: CatalogItemIds(anilist: 195539),
        ),
      );

      expect(paths, ['/details/anilist/TV/195539', '/details/tmdb/tv/105248']);
      expect(detail.item.ids.anilist, 195539);
      expect(detail.item.ids.tmdb, 105248);
      expect(detail.item.ids.tvdb, 384541);
    });

    test('an unmapped title stays as it is', () async {
      final source = _source((request) async => _json({'message': 'TVDB ID not found for this show'}, status: 404));

      final detail = await source.fetchDetail(tmdbShow);

      expect(detail.item.ids.tvdb, isNull);
    });

    test('a library title, or any title straight to the backend, needs no lookup', () async {
      final noRequests = _source((request) async => fail('no request'));
      final library = RivenCatalogSource.toCatalogItem(
        RivenItem.fromJson(_item(type: 'show', tmdb: null, tvdb: '384541')),
      )!;
      expect((await noRequests.fetchDetail(library)).item.ids.tvdb, 384541);

      final backend = _source((request) async => fail('no request'), session: _backend);
      expect((await backend.fetchDetail(tmdbShow)).item.ids.tvdb, isNull);
    });
  });

  test('places only TMDB-keyed movies and TVDB-keyed shows, and has no watchlist', () async {
    final source = _source((request) async => fail('no request'));

    expect(await source.resolveItemIds(MediaKind.movie, const ExternalIds(tmdb: 1)), isNotNull);
    expect(await source.resolveItemIds(MediaKind.movie, const ExternalIds(tvdb: 1)), isNull);
    expect(await source.resolveItemIds(MediaKind.show, const ExternalIds(tvdb: 2)), isNotNull);
    expect(await source.resolveItemIds(MediaKind.show, const ExternalIds(tmdb: 2)), isNull);
    expect(() => source.fetchRow(CatalogRowId.trending), throwsArgumentError);
    expect(source.supportsWatchlist, isFalse);
  });
}
