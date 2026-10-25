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
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/riven_catalog_source.dart';
import 'package:plezy/services/riven/riven_client.dart';
import 'package:plezy/utils/external_ids.dart';

const _session = RivenSession(
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

http.Response _page(List<Map<String, Object?>> items, {int page = 1, int totalPages = 1, int? totalItems}) =>
    http.Response(
      jsonEncode({
        'success': true,
        'items': items,
        'page': page,
        'limit': 25,
        'total_items': totalItems ?? items.length,
        'total_pages': totalPages,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

RivenCatalogSource _source(Future<http.Response> Function(http.Request request) handler) {
  final client = RivenClient(_session, onSessionInvalidated: () {}, httpClient: MockClient(handler));
  final source = RivenCatalogSource(client);
  addTearDown(() {
    source.dispose();
    client.dispose();
  });
  return source;
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  test('fills one shelf per state group, in display order', () async {
    final requested = <List<String>>[];
    final source = _source((request) async {
      final states = request.url.queryParametersAll['states']!;
      requested.add(states);
      return _page(states.contains('Completed') ? [_item()] : []);
    });

    final hubs = await source.fetchHubs(limit: 10);

    expect(requested, unorderedEquals([for (final hub in RivenCatalogHub.values) hub.states.map((s) => s.wire)]));
    expect(hubs.map((hub) => hub.id), [for (final hub in RivenCatalogHub.values) hub.name]);
    expect(hubs.map((hub) => hub.title), [
      t.riven.hubs.inProgress,
      t.riven.hubs.needsAttention,
      t.riven.hubs.recentlyAdded,
      t.riven.hubs.comingSoon,
    ]);
    final recent = hubs.firstWhere((hub) => hub.id == RivenCatalogHub.recentlyAdded.name);
    expect(recent.page.items.single.title, 'The Odyssey');
  });

  test('a failing shelf is left out while the others render', () async {
    final source = _source((request) async {
      final states = request.url.queryParametersAll['states']!;
      if (states.contains('Failed')) return http.Response('boom', 500);
      return _page([_item()]);
    });

    final hubs = await source.fetchHubs();

    expect(hubs.map((hub) => hub.id), isNot(contains(RivenCatalogHub.needsAttention.name)));
    expect(hubs, hasLength(RivenCatalogHub.values.length - 1));
  });

  test('every shelf failing fails the load', () async {
    final source = _source((request) async => http.Response('boom', 500));

    await expectLater(source.fetchHubs(), throwsA(anything));
  });

  test('View All pages one shelf through Riven paging', () async {
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

  test('maps a tracked movie to a catalog item the cards can badge', () {
    final item = RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(state: 'Downloaded')))!;

    expect(item.source, CatalogSourceId.riven);
    expect(item.kind, MediaKind.movie);
    expect(item.year, 2026);
    expect(item.genres, ['Science Fiction', 'Action']);
    expect(item.certification, 'PG-13');
    expect(item.ids.tmdb, 1368337);
    expect(item.ids.imdb, 'tt33764258');
    expect(item.posterUrl, 'https://image.tmdb.org/t/p/w500/abc.jpg');
    expect(item.posterVariants?[185], 'https://image.tmdb.org/t/p/w185/abc.jpg');
    expect(item.serverState?.request, CatalogRequestState.processing);
  });

  test('maps Riven states onto availability and request badges', () {
    CatalogServerState? state(String wire) =>
        RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(state: wire)))!.serverState;

    expect(state('Completed')?.availability, CatalogAvailability.available);
    expect(state('Ongoing')?.availability, CatalogAvailability.partiallyAvailable);
    expect(state('Indexed')?.request, CatalogRequestState.approved);
    expect(state('Unreleased')?.request, CatalogRequestState.approved);
    expect(state('Failed')?.request, CatalogRequestState.failed);
    expect(state('Paused'), isNull);
  });

  test('keeps a TheTVDB poster as is and drops what is not a movie or show', () {
    final show = RivenCatalogSource.toCatalogItem(
      RivenItem.fromJson(
        _item(
          type: 'show',
          tmdb: null,
          tvdb: '384541',
          poster: 'https://artworks.thetvdb.com/banners/series/384541/posters/a.jpg',
        ),
      ),
    )!;
    expect(show.kind, MediaKind.show);
    expect(show.ids.tvdb, 384541);
    expect(show.posterVariants, isNull);

    expect(RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(type: 'episode'))), isNull);
    expect(RivenCatalogSource.toCatalogItem(RivenItem.fromJson(_item(title: '  '))), isNull);
  });

  test("searches Riven's own titles", () async {
    final searches = <String?>[];
    final source = _source((request) async {
      searches.add(request.url.queryParameters['search']);
      return _page([_item()]);
    });

    expect(await source.search('  '), isEmpty);
    final results = await source.search(' odyssey ');

    expect(searches, ['odyssey']);
    expect(results.single.title, 'The Odyssey');
  });

  test('places only TMDB-keyed movies and TVDB-keyed shows', () async {
    final source = _source((request) async => fail('no request'));

    expect(await source.resolveItemIds(MediaKind.movie, const ExternalIds(tmdb: 1)), isNotNull);
    expect(await source.resolveItemIds(MediaKind.movie, const ExternalIds(tvdb: 1)), isNull);
    expect(await source.resolveItemIds(MediaKind.show, const ExternalIds(tvdb: 2)), isNotNull);
    expect(await source.resolveItemIds(MediaKind.show, const ExternalIds(tmdb: 2)), isNull);
    expect(() => source.fetchRow(CatalogRowId.trending), throwsArgumentError);
    expect(source.supportsWatchlist, isFalse);
  });
}
