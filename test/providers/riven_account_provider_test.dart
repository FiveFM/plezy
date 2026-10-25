import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/riven/riven_session.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/providers/riven_account_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/riven/riven_auth_service.dart';
import 'package:plezy/services/riven/riven_constants.dart';
import 'package:plezy/services/riven/riven_session_store.dart';
import 'package:plezy/services/sensitive_prefs.dart';

import '../test_helpers/http_fixtures.dart';
import '../test_helpers/prefs.dart';

const _userUuid = 'profile-1';

/// No secret, so the store round-trips it without the credential vault.
RivenSession _storedSession() => const RivenSession(
  baseUrl: 'https://riven.example.com',
  method: RivenAuthMethod.frontend,
  identifier: 'alice',
  secret: '',
  cookie: 'stored',
  userId: 'user-1',
  displayName: 'Alice',
  version: '1.0.0',
  createdAt: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RivenAccountProvider bind(MockClient mock, {RivenSession? stored}) {
    resetSharedPreferencesForTest(
      initialAsync: {profileScopedPrefsKey(_userUuid, rivenSessionBaseKey): (stored ?? _storedSession()).encode()},
    );
    final provider = RivenAccountProvider(authService: RivenAuthService(httpClientFactory: () => mock));
    addTearDown(provider.dispose);
    return provider;
  }

  test('a stored session re-reads the backend version on bind', () async {
    final paths = <String>[];
    final provider = bind(
      MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers['Cookie'], '${RivenConstants.sessionCookieName}=stored');
        return jsonResponse({'message': RivenConstants.backendRootMessage, 'version': '1.1.0'});
      }),
    );

    await provider.onActiveProfileChanged(_userUuid);
    // Binding exposes the stored snapshot at once; the refresh follows.
    expect(provider.session?.version, '1.0.0');
    expect(provider.displayName, 'Alice');
    await pumpEventQueue();

    expect(paths, ['/api/v1']);
    expect(provider.session?.version, '1.1.0');
    expect((await const RivenSessionStore().load(_userUuid))?.version, '1.1.0');
  });

  test('an unreachable install leaves the stored snapshot bound', () async {
    final provider = bind(MockClient((request) async => throw http.ClientException('connection refused')));

    await provider.onActiveProfileChanged(_userUuid);
    await pumpEventQueue();

    expect(provider.isConnected, isTrue);
    expect(provider.session?.cookie, 'stored');
  });

  test('a login bounce with no stored password unlinks the session', () async {
    final provider = bind(
      MockClient((request) async => http.Response('', 307, headers: {'location': RivenConstants.loginPagePath})),
    );

    await provider.onActiveProfileChanged(_userUuid);
    await pumpEventQueue();

    expect(provider.isConnected, isFalse);
    expect(provider.client, isNull);
    expect(await const RivenSessionStore().load(_userUuid), isNull);
  });

  test('an adopted session stores its password only as vault ciphertext', () async {
    CredentialVault.resetKeyForTesting();
    addTearDown(CredentialVault.resetKeyForTesting);
    final provider = bind(
      MockClient((request) async => jsonResponse({'message': RivenConstants.backendRootMessage, 'version': '1.0.0'})),
    );
    await provider.onActiveProfileChanged(_userUuid);
    await pumpEventQueue();

    await provider.adoptSession(_storedSession().copyWith(secret: 'hunter2', cookie: 'adopted'));

    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = prefs.getString(profileScopedPrefsKey(_userUuid, rivenSessionBaseKey));
    expect(raw, isNot(contains('hunter2')));
    final loaded = await const RivenSessionStore().load(_userUuid);
    expect(loaded?.secret, 'hunter2');
    expect(loaded?.cookie, 'adopted');
    expect(provider.client?.session.cookie, 'adopted');
  });

  test('disconnect clears the session and signs the cookie out', () async {
    final calls = <String>[];
    final provider = bind(
      MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/auth/sign-out') {
          expect(request.headers['Cookie'], '${RivenConstants.sessionCookieName}=stored');
          expect(request.headers['Origin'], 'https://riven.example.com');
          return jsonResponse({'success': true});
        }
        return jsonResponse({'message': RivenConstants.backendRootMessage, 'version': '1.0.0'});
      }),
    );
    await provider.onActiveProfileChanged(_userUuid);
    await pumpEventQueue();

    await provider.disconnect();

    expect(provider.isConnected, isFalse);
    expect(await const RivenSessionStore().load(_userUuid), isNull);
    expect(calls.last, 'POST /api/auth/sign-out');
  });

  test('an API-key session reports the install, having no user', () async {
    final provider = bind(
      MockClient((request) async {
        expect(request.headers[RivenConstants.apiKeyHeader], 'key');
        return jsonResponse({'message': RivenConstants.backendRootMessage, 'version': '1.0.0'});
      }),
      stored: const RivenSession(
        baseUrl: 'http://riven.lan:8080',
        method: RivenAuthMethod.apiKey,
        identifier: '',
        secret: 'key',
        cookie: '',
        userId: '',
        displayName: '',
        version: '1.0.0',
        createdAt: 0,
      ),
    );

    await provider.onActiveProfileChanged(_userUuid);
    await pumpEventQueue();

    expect(provider.displayName, 'riven.lan');
  });
}
