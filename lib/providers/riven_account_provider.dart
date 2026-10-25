import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mixins/disposable_change_notifier_mixin.dart';
import '../models/riven/riven_session.dart';
import '../services/riven/riven_auth_service.dart';
import '../services/riven/riven_client.dart';
import '../services/riven/riven_session_store.dart';
import '../services/trackers/future_coalescer.dart';
import '../utils/app_logger.dart';

/// Owns the active Riven session for the currently-selected profile,
/// mirroring `SeerrAccountProvider`'s rebind shape: `onActiveProfileChanged`
/// loads the profile's stored session and rebuilds the client.
///
/// There is no in-provider connect flow — the connect screen drives
/// [RivenAuthService] itself and hands the finished session to
/// [adoptSession].
class RivenAccountProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  RivenAccountProvider({RivenSessionStore? store, RivenAuthService? authService})
    : _store = store ?? const RivenSessionStore(),
      authService = authService ?? RivenAuthService();

  final RivenSessionStore _store;
  final RivenAuthService authService;

  final FutureCoalescer<void> _versionRefresh = FutureCoalescer();

  void _logPersistenceFailure(Object e) => appLogger.w('Riven: session persistence failed', error: e);

  RivenSession? _session;
  String _activeUserUuid = '';
  int _bindingGeneration = 0;
  RivenClient? _client;

  RivenSession? get session => _session;
  bool get isConnected => _session != null;

  /// Who the Services hub reports as connected: the frontend user, else
  /// the install's address for an API-key session, which has no user.
  String? get displayName {
    final session = _session;
    if (session == null) return null;
    return session.displayName.isNotEmpty ? session.displayName : Uri.tryParse(session.baseUrl)?.host;
  }

  /// Client for the detail screen and queue; null when disconnected. A
  /// reconnect replaces it, so surfaces compare identity before applying a
  /// response to the client they started with.
  RivenClient? get client => _client;

  /// Called whenever the active profile changes (or on initial load).
  Future<void> onActiveProfileChanged(String? newUserUuid) async {
    if (isDisposed) return;
    final userUuid = newUserUuid ?? '';
    final generation = ++_bindingGeneration;
    _activeUserUuid = userUuid;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    final loaded = await _store.load(userUuid);
    _setSessionAndRebind(userUuid, generation, loaded);
    if (_isCurrentBinding(userUuid, generation)) unawaited(refreshVersion());
  }

  /// Re-read the backend version on bind. Best-effort: while the install is
  /// unreachable the session keeps working on its snapshot, and an expired
  /// cookie re-logins (or unlinks) through the client's own path — here,
  /// rather than on the first status lookup a screen waits on.
  Future<void> refreshVersion() => _versionRefresh.run(_refreshVersion);

  Future<void> _refreshVersion() async {
    if (isDisposed) return;
    final client = _client;
    if (client == null) return;
    try {
      await client.refreshVersion();
    } catch (e, stackTrace) {
      appLogger.w('Riven: version refresh failed', error: e, stackTrace: stackTrace);
    }
  }

  /// Persist and bind a session the connect screen established.
  Future<void> adoptSession(RivenSession session) async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    // Retire the old client before persistence: its callbacks must not
    // enqueue session writes behind this explicit adoption.
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.save(userUuid, session);
    _setSessionAndRebind(userUuid, generation, session);
  }

  /// Sign out server-side (best effort) and clear local state.
  Future<void> disconnect() async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final session = _session;
    final generation = ++_bindingGeneration;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.clear(userUuid);
    if (session != null) await authService.signOut(session);
  }

  void _setSessionAndRebind(String userUuid, int generation, RivenSession? session) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    _versionRefresh.reset();
    _session = session;
    _client?.dispose();
    _client = session == null
        ? null
        : RivenClient(
            session,
            onSessionInvalidated: () => _handleSessionInvalidated(userUuid, generation),
            onSessionUpdated: (next) => _handleSessionUpdated(userUuid, generation, next),
            authService: authService,
            // The auth service's client factory is a test seam (null in
            // production); sharing it lets one MockClient serve both.
            httpClient: authService.httpClientFactory?.call(),
          );
    safeNotifyListeners();
  }

  bool _isCurrentBinding(String userUuid, int generation) {
    return !isDisposed && userUuid == _activeUserUuid && generation == _bindingGeneration;
  }

  void _handleSessionUpdated(String userUuid, int generation, RivenSession session) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    _session = session;
    unawaited(_store.save(userUuid, session).catchError(_logPersistenceFailure));
    safeNotifyListeners();
  }

  /// Called by [RivenClient] when the session can't be recovered: clear local
  /// state so the UI shows "not connected" and the user can re-link.
  void _handleSessionInvalidated(String userUuid, int generation) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    final nextGeneration = ++_bindingGeneration;
    unawaited(_store.clear(userUuid).catchError(_logPersistenceFailure));
    _setSessionAndRebind(userUuid, nextGeneration, null);
  }

  @override
  void dispose() {
    _client?.dispose();
    _client = null;
    super.dispose();
  }
}
