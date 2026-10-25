import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/riven/riven_item.dart';
import 'package:plezy/models/riven/riven_session.dart';
import 'package:plezy/services/riven/riven_auth_service.dart';
import 'package:plezy/services/riven/riven_client.dart';
import 'package:plezy/services/riven/riven_constants.dart';
import 'package:plezy/services/riven/riven_exceptions.dart';
import 'package:plezy/services/riven/riven_http_client.dart';

RivenSession _session({
  RivenAuthMethod method = RivenAuthMethod.frontend,
  String secret = 'hunter2',
  String cookie = 'old-cookie',
}) => RivenSession(
  baseUrl: 'https://riven.example.com',
  method: method,
  identifier: method == RivenAuthMethod.frontend ? 'alice' : '',
  secret: secret,
  cookie: method == RivenAuthMethod.frontend ? cookie : '',
  userId: method == RivenAuthMethod.frontend ? 'user-1' : '',
  displayName: method == RivenAuthMethod.frontend ? 'Alice' : '',
  version: '1.0.0',
  createdAt: 0,
);

http.Response _json(Object? body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...?headers});

/// The frontend hook's answer to a cookie that names no live session.
http.Response _loginBounce() => http.Response('', 307, headers: {'location': '/auth/login'});

Map<String, Object?> _item({
  String id = '6702',
  String state = 'Completed',
  String type = 'movie',
  String? tmdb = '1368337',
  String? tvdb,
  String? imdb = 'tt33764258',
}) => {
  'id': id,
  'title': 'The Odyssey',
  'poster_path': 'https://image.tmdb.org/t/p/w500/a.jpg',
  'type': type,
  'imdb_id': imdb,
  'tvdb_id': tvdb,
  'tmdb_id': tmdb,
  'state': state,
  'requested_at': '2026-10-17 18:39:38.729835',
};

Map<String, Object?> _page(List<Map<String, Object?>> items) => {
  'success': true,
  'items': items,
  'page': 1,
  'limit': 50,
  'total_items': items.length,
  'total_pages': items.isEmpty ? 0 : 1,
};

/// Answers better-auth's username sign-in with a fresh cookie, then the
/// session read and the API root — both of which must carry that cookie.
MockClient _signInMock({String userId = 'user-1', void Function(http.Request)? onSignIn}) =>
    MockClient((request) async {
      switch (request.url.path) {
        case '/api/auth/sign-in/username':
          onSignIn?.call(request);
          return _json(
            {'token': 'opaque', 'user': {}},
            headers: {
              'set-cookie':
                  '${RivenConstants.sessionCookieName}=fresh.sig%3D; Max-Age=604800; Path=/; HttpOnly; SameSite=Lax, '
                  'riven.session_data=cache; Max-Age=60; Path=/',
            },
          );
        case '/api/auth/get-session':
          expect(request.headers['Cookie'], '${RivenConstants.sessionCookieName}=fresh.sig%3D');
          return _json({
            'session': {},
            'user': {'id': userId, 'username': 'alice', 'displayUsername': 'Alice', 'name': 'alice'},
          });
        case '/api/v1':
          expect(request.headers['Cookie'], '${RivenConstants.sessionCookieName}=fresh.sig%3D');
          return _json({'message': RivenConstants.backendRootMessage, 'version': '1.1.0'});
      }
      fail('Unexpected ${request.method} ${request.url}');
    });

void main() {
  group('RivenHttpClient', () {
    test('normalizes trailing slashes and scheme case off the base URL', () {
      expect(RivenHttpClient.normalizeBaseUrl(' HTTPS://riven.example.com// '), 'https://riven.example.com');
    });

    test('captures the session token out of a multi-cookie Set-Cookie header', () {
      final client = RivenHttpClient(baseUrl: 'https://riven.example.com');
      final response = http.Response(
        '',
        200,
        headers: {
          'set-cookie':
              'riven.session_data=cache; Path=/, ${RivenConstants.sessionCookieName}=abc.def%2B; Path=/; HttpOnly',
        },
      );
      expect(client.captureSessionCookie(response), isTrue);
      expect(client.cookie, 'abc.def%2B');
    });

    test('sends the cookie or the API key on authenticated requests only', () async {
      final seen = <(String?, String?)>[];
      MockClient mock() => MockClient((request) async {
        seen.add((request.headers['Cookie'], request.headers[RivenConstants.apiKeyHeader]));
        return _json({});
      });
      final cookieClient = RivenHttpClient(baseUrl: 'https://riven.example.com', cookie: 'abc', httpClient: mock());
      final keyClient = RivenHttpClient(baseUrl: 'https://riven.example.com', apiKey: 'key', httpClient: mock());
      await cookieClient.send('GET', '/items');
      await cookieClient.send('GET', '/', authenticated: false);
      await keyClient.send('GET', '/items');
      expect(seen, [('${RivenConstants.sessionCookieName}=abc', null), (null, null), (null, 'key')]);
    });

    test('classifies only the shapes Riven actually emits', () {
      RivenRejection classify(http.Response response) =>
          RivenHttpClient.classify(RivenResponse(response, _decode(response)));

      expect(classify(_loginBounce()), RivenRejection.session);
      expect(
        classify(http.Response('', 307, headers: {'location': 'https://host/riven/auth/login'})),
        RivenRejection.session,
        reason: 'a frontend served under a sub-path keeps its login bounce',
      );
      expect(
        classify(http.Response('', 302, headers: {'location': 'https://sso.example.com/login?rd=x'})),
        RivenRejection.intermediary,
      );
      expect(
        classify(_json({'detail': 'Invalid authentication credentials'}, status: 401)),
        RivenRejection.credentials,
      );
      expect(classify(http.Response('<html>401</html>', 401)), RivenRejection.intermediary);
      expect(classify(_json({'error': 'unauthorized'}, status: 403)), RivenRejection.intermediary);
      expect(classify(_json({'detail': 'boom'}, status: 500)), RivenRejection.none);
    });
  });

  group('RivenAuthService', () {
    test('expands schemeless input TLS first, then the default install ports', () {
      expect(RivenAuthService.expandUrlCandidates('riven.lan'), [
        'https://riven.lan',
        'http://riven.lan',
        'http://riven.lan:${RivenConstants.defaultFrontendPort}',
        'http://riven.lan:${RivenConstants.defaultBackendPort}',
      ]);
      expect(RivenAuthService.expandUrlCandidates('http://riven.lan:9000/'), ['http://riven.lan:9000']);
    });

    test('probe identifies a bare backend by its root answer', () async {
      final auth = RivenAuthService(
        httpClientFactory: () => MockClient((request) async {
          expect(request.url.path, '/api/v1/');
          return _json({'message': RivenConstants.backendRootMessage, 'version': '1.0.0'});
        }),
      );
      final instance = await auth.probe('http://riven.lan:8080');
      expect(instance.method, RivenAuthMethod.apiKey);
      expect(instance.version, '1.0.0');
    });

    test('probe identifies the frontend through better-auth, past its trailing-slash redirect', () async {
      final auth = RivenAuthService(
        httpClientFactory: () => MockClient((request) async {
          return switch (request.url.path) {
            '/api/v1/' => http.Response('', 308, headers: {'location': '/api/v1'}),
            '/api/auth/ok' => _json({'ok': true}),
            _ => fail('Unexpected ${request.url}'),
          };
        }),
      );
      final instance = await auth.probe('https://riven.example.com');
      expect(instance.method, RivenAuthMethod.frontend);
      expect(instance.baseUrl, 'https://riven.example.com');
    });

    test('probe reports an auth wall instead of "not Riven"', () async {
      final auth = RivenAuthService(
        httpClientFactory: () =>
            MockClient((request) async => http.Response('', 302, headers: {'location': 'https://sso.example.com/'})),
      );
      await expectLater(
        auth.probe('https://riven.example.com'),
        throwsA(isA<RivenUrlException>().having((e) => e.display, 'display', t.riven.behindAuthProxy)),
      );
    });

    test('probe rejects a server that is not Riven, with the status that disqualified it', () async {
      final auth = RivenAuthService(
        httpClientFactory: () => MockClient((request) async => http.Response('<html></html>', 200)),
      );
      await expectLater(
        auth.probe('https://example.com'),
        throwsA(isA<RivenUrlException>().having((e) => e.statusCode, 'statusCode', 200)),
      );
    });

    test('password sign-in captures the cookie and reads the user and version through it', () async {
      Map<String, dynamic>? body;
      final auth = RivenAuthService(
        httpClientFactory: () => _signInMock(onSignIn: (request) => body = jsonDecode(request.body)),
      );
      final session = await auth.signInWithPassword(
        baseUrl: 'https://riven.example.com/',
        username: 'alice',
        password: 'hunter2',
      );
      expect(body, {'username': 'alice', 'password': 'hunter2'});
      expect(session.method, RivenAuthMethod.frontend);
      expect(session.baseUrl, 'https://riven.example.com');
      expect(session.cookie, 'fresh.sig%3D');
      expect(session.userId, 'user-1');
      expect(session.displayName, 'Alice');
      expect(session.version, '1.1.0');
      expect(session.secret, 'hunter2');
    });

    test('a better-auth credential rejection is a sign-in rejection', () async {
      final auth = RivenAuthService(
        httpClientFactory: () => MockClient(
          (request) async =>
              _json({'code': 'INVALID_USERNAME_OR_PASSWORD', 'message': 'Invalid username or password'}, status: 401),
        ),
      );
      await expectLater(
        auth.signInWithPassword(baseUrl: 'https://riven.example.com', username: 'alice', password: 'nope'),
        throwsA(isA<RivenAuthException>().having((e) => e.display, 'display', t.riven.signInRejected)),
      );
    });

    test('API-key sign-in checks the key on /health and reads the version from the backend root', () async {
      final paths = <String>[];
      final auth = RivenAuthService(
        httpClientFactory: () => MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers[RivenConstants.apiKeyHeader], 'key');
          return request.url.path == '/api/v1/health'
              ? _json({'message': 'True'})
              : _json({'message': RivenConstants.backendRootMessage, 'version': '1.0.0'});
        }),
      );
      final session = await auth.signInWithApiKey(baseUrl: 'http://riven.lan:8080', apiKey: 'key');
      expect(paths, ['/api/v1/health', '/api/v1/']);
      expect(session.method, RivenAuthMethod.apiKey);
      expect(session.secret, 'key');
      expect(session.cookie, isEmpty);
      expect(session.version, '1.0.0');
    });

    test('a rejected API key is a sign-in failure', () async {
      final auth = RivenAuthService(
        httpClientFactory: () =>
            MockClient((request) async => _json({'detail': 'Invalid authentication credentials'}, status: 401)),
      );
      await expectLater(
        auth.signInWithApiKey(baseUrl: 'http://riven.lan:8080', apiKey: 'wrong'),
        throwsA(isA<RivenAuthException>().having((e) => e.display, 'display', t.riven.apiKeyRejected)),
      );
    });

    test('re-auth refuses a sign-in that lands on a different user', () async {
      final auth = RivenAuthService(httpClientFactory: () => _signInMock(userId: 'someone-else'));
      await expectLater(auth.reauth(_session()), throwsA(isA<RivenAuthException>()));
    });

    test('re-auth has nothing to offer an API-key session', () async {
      final auth = RivenAuthService(httpClientFactory: () => MockClient((request) async => fail('no request')));
      await expectLater(auth.reauth(_session(method: RivenAuthMethod.apiKey)), throwsA(isA<RivenAuthException>()));
    });
  });

  group('RivenItem', () {
    test('parses string ids, Python timestamps and state names', () {
      final item = RivenItem.fromJson(_item(state: 'PartiallyCompleted'));
      expect(item.id, 6702);
      expect(item.kind, MediaKind.movie);
      expect(item.state, RivenItemState.partiallyCompleted);
      expect(item.state.isAvailable, isTrue);
      expect(item.requestedAt, DateTime(2026, 10, 17, 18, 39, 38, 729, 835));
    });

    test('an unknown state is not polled and a missing timestamp is null', () {
      final item = RivenItem.fromJson({..._item(state: 'SomethingNew'), 'requested_at': 'None'});
      expect(item.state, RivenItemState.unknown);
      expect(item.state.isInProgress, isFalse);
      expect(item.requestedAt, isNull);
    });
  });

  group('RivenClient', () {
    RivenClient client(
      MockClient mock, {
      RivenSession? session,
      void Function()? onInvalidated,
      void Function(RivenSession)? onUpdated,
      RivenAuthService? auth,
    }) {
      final c = RivenClient(
        session ?? _session(),
        onSessionInvalidated: onInvalidated ?? () {},
        onSessionUpdated: onUpdated,
        authService: auth ?? RivenAuthService(httpClientFactory: () => MockClient((_) async => fail('no sign-in'))),
        httpClient: mock,
      );
      addTearDown(c.dispose);
      return c;
    }

    test('finds a movie by TMDB id, then falls back to IMDb', () async {
      final searches = <Map<String, List<String>>>[];
      final c = client(
        MockClient((request) async {
          expect(request.url.path, '/api/v1/items');
          searches.add(request.url.queryParametersAll);
          return _json(_page(request.url.queryParameters['search'] == 'tt33764258' ? [_item()] : []));
        }),
      );
      final item = await c.findItem(MediaKind.movie, tmdbId: 1368337, tvdbId: 99, imdbId: 'tt33764258');
      expect(item?.id, 6702);
      expect(searches.map((q) => q['search']), [
        ['tmdb_1368337'],
        ['tt33764258'],
      ]);
      expect(searches.first['type'], ['movie']);
      expect(searches.first['limit'], ['1']);
    });

    test('finds a show by TVDB id and never by TMDB', () async {
      final searches = <String?>[];
      final c = client(
        MockClient((request) async {
          searches.add(request.url.queryParameters['search']);
          return _json(_page([_item(type: 'show', tmdb: null, tvdb: '384541', state: 'Ongoing')]));
        }),
      );
      final item = await c.findItem(MediaKind.show, tmdbId: 105248, tvdbId: 384541);
      expect(searches, ['tvdb_384541']);
      expect(item?.state, RivenItemState.ongoing);
    });

    test('an untracked title is null, not an error', () async {
      final c = client(MockClient((request) async => _json(_page([]))));
      expect(await c.findItem(MediaKind.movie, tmdbId: 1, imdbId: 'tt1'), isNull);
      expect(await c.findItem(MediaKind.episode, tmdbId: 1), isNull);
    });

    test('adds movies by TMDB id and shows by TVDB id', () async {
      final bodies = <Object?>[];
      final c = client(
        MockClient((request) async {
          expect((request.method, request.url.path), ('POST', '/api/v1/items/add'));
          bodies.add(jsonDecode(request.body));
          return _json({'message': 'Added 1 item(s) to the queue'});
        }),
      );
      await c.addItem(MediaKind.movie, tmdbId: 1368337, tvdbId: 5);
      await c.addItem(MediaKind.show, tmdbId: 5, tvdbId: 384541);
      expect(bodies, [
        {
          'tmdb_ids': ['1368337'],
          'media_type': 'movie',
        },
        {
          'tvdb_ids': ['384541'],
          'media_type': 'tv',
        },
      ]);
      expect(() => c.addItem(MediaKind.show, tmdbId: 5), throwsArgumentError);
    });

    test('item actions send the id list Riven expects', () async {
      final calls = <String>[];
      final bodies = <Object?>[];
      final c = client(
        MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          bodies.add(jsonDecode(request.body));
          return _json({
            'message': 'ok',
            'ids': [6702],
          });
        }),
      );
      await c.retryItem(6702);
      await c.resetItem(6702);
      await c.removeItem(6702);
      expect(calls, ['POST /api/v1/items/retry', 'POST /api/v1/items/reset', 'DELETE /api/v1/items/remove']);
      expect(
        bodies,
        everyElement({
          'ids': ['6702'],
        }),
      );
    });

    test('a login bounce re-authenticates silently and replays the request once', () async {
      final cookies = <String?>[];
      RivenSession? updated;
      final c = client(
        MockClient((request) async {
          cookies.add(request.headers['Cookie']);
          return request.headers['Cookie'] == '${RivenConstants.sessionCookieName}=fresh.sig%3D'
              ? _json(_page([_item()]))
              : _loginBounce();
        }),
        auth: RivenAuthService(httpClientFactory: _signInMock),
        onUpdated: (session) => updated = session,
      );
      final item = await c.findItem(MediaKind.movie, tmdbId: 1368337);
      expect(item?.id, 6702);
      expect(cookies, [
        '${RivenConstants.sessionCookieName}=old-cookie',
        '${RivenConstants.sessionCookieName}=fresh.sig%3D',
      ]);
      expect(updated?.cookie, 'fresh.sig%3D');
      expect(c.session.cookie, 'fresh.sig%3D');
      expect(c.session.identifier, 'alice', reason: 'the binding keeps its own identity');
    });

    test('concurrent bounces share one sign-in', () async {
      var signIns = 0;
      final c = client(
        MockClient((request) async {
          return request.headers['Cookie'] == '${RivenConstants.sessionCookieName}=fresh.sig%3D'
              ? _json(_page([]))
              : _loginBounce();
        }),
        auth: RivenAuthService(httpClientFactory: () => _signInMock(onSignIn: (_) => signIns++)),
      );
      await Future.wait([
        c.findItem(MediaKind.movie, tmdbId: 1),
        c.findItem(MediaKind.movie, tmdbId: 2),
        c.findItem(MediaKind.movie, tmdbId: 3),
      ]);
      expect(signIns, 1);
    });

    test('a bounce right after re-auth unlinks the session', () async {
      var invalidated = false;
      final c = client(
        MockClient((request) async => _loginBounce()),
        auth: RivenAuthService(httpClientFactory: _signInMock),
        onInvalidated: () => invalidated = true,
      );
      await expectLater(c.findItem(MediaKind.movie, tmdbId: 1), throwsA(isA<RivenAuthException>()));
      expect(invalidated, isTrue);
    });

    test('rejected stored credentials unlink the session', () async {
      var invalidated = false;
      final c = client(
        MockClient((request) async => _loginBounce()),
        auth: RivenAuthService(
          httpClientFactory: () => MockClient(
            (request) async => _json({'code': 'INVALID_USERNAME_OR_PASSWORD', 'message': 'nope'}, status: 401),
          ),
        ),
        onInvalidated: () => invalidated = true,
      );
      await expectLater(c.findItem(MediaKind.movie, tmdbId: 1), throwsA(isA<RivenAuthException>()));
      expect(invalidated, isTrue);
    });

    test('a rotated API key unlinks the session', () async {
      var invalidated = false;
      final c = client(
        MockClient((request) async => _json({'detail': 'Invalid authentication credentials'}, status: 401)),
        session: _session(method: RivenAuthMethod.apiKey, secret: 'old-key'),
        onInvalidated: () => invalidated = true,
      );
      await expectLater(
        c.findItem(MediaKind.movie, tmdbId: 1),
        throwsA(isA<RivenAuthException>().having((e) => e.display, 'display', t.riven.apiKeyRejected)),
      );
      expect(invalidated, isTrue);
    });

    test("through the frontend, the backend refusing the frontend's own key is not this session's fault", () async {
      var invalidated = false;
      final c = client(
        MockClient((request) async => _json({'detail': 'Invalid authentication credentials'}, status: 401)),
        onInvalidated: () => invalidated = true,
      );
      await expectLater(c.findItem(MediaKind.movie, tmdbId: 1), throwsA(isA<RivenApiException>()));
      expect(invalidated, isFalse);
    });

    test('an auth wall is reported without touching the session', () async {
      var invalidated = false;
      final c = client(
        MockClient((request) async => http.Response('', 302, headers: {'location': 'https://sso.example.com/'})),
        onInvalidated: () => invalidated = true,
      );
      await expectLater(c.addItem(MediaKind.movie, tmdbId: 1), throwsA(isA<RivenProxyException>()));
      expect(invalidated, isFalse);
    });

    test("the web app's own routes re-login on a bounce like the API does", () async {
      final seen = <(String, String?)>[];
      final c = client(
        MockClient((request) async {
          seen.add((request.url.path, request.headers['Cookie']));
          return request.headers['Cookie'] == '${RivenConstants.sessionCookieName}=fresh.sig%3D'
              ? _json({'results': []})
              : _loginBounce();
        }),
        auth: RivenAuthService(httpClientFactory: _signInMock),
      );

      final page = await c.getTrending(MediaKind.movie);

      expect(page.results, isEmpty);
      expect(seen.map((call) => call.$1), ['/api/tmdb/movie/day/trending', '/api/tmdb/movie/day/trending']);
      expect(seen.last.$2, '${RivenConstants.sessionCookieName}=fresh.sig%3D');
    });

    test('the id resolver reads its redirect, and a wall in front of it is not a miss', () async {
      final c = client(
        MockClient((request) async {
          return switch (request.url.path) {
            '/details/tmdb/tv/105248' => http.Response('', 307, headers: {'location': '/details/media/384541/tv'}),
            '/details/tmdb/tv/1' => _json({'message': 'TVDB ID not found for this show'}, status: 404),
            _ => http.Response('', 302, headers: {'location': 'https://sso.example.com/'}),
          };
        }),
      );

      expect(await c.resolveTvdbId(105248), 384541);
      expect(await c.resolveTvdbId(1), isNull);
      await expectLater(c.resolveTvdbId(2), throwsA(isA<RivenProxyException>()));
    });

    test('version refresh adopts a changed backend version', () async {
      RivenSession? updated;
      final c = client(
        MockClient((request) async {
          expect(request.url.path, '/api/v1');
          return _json({'message': RivenConstants.backendRootMessage, 'version': '1.2.0'});
        }),
        onUpdated: (session) => updated = session,
      );
      await c.refreshVersion();
      expect(updated?.version, '1.2.0');
    });
  });

  group('rivenErrorReason', () {
    test('never surfaces a transport exception verbatim', () {
      expect(
        rivenErrorReason(http.ClientException('boom', Uri.parse('https://riven.example.com/api/v1/items'))),
        t.errors.reasonUnreachable,
      );
      expect(rivenErrorReason(TimeoutException('slow')), t.errors.reasonTimedOut);
      expect(rivenErrorReason(const RivenApiException('Item not found', statusCode: 404)), 'Item not found');
      expect(rivenErrorReason(StateError('x')), t.errors.reasonUnexpected);
    });
  });
}

Object? _decode(http.Response response) {
  try {
    return jsonDecode(response.body);
  } catch (_) {
    return null;
  }
}
