import '../../models/riven/riven_session.dart';
import '../../profiles/profile.dart';
import '../../utils/serial_future_queue.dart';
import '../base_shared_preferences_service.dart';
import '../credential_vault.dart';
import '../sensitive_prefs.dart';

/// Per-Plex-profile persistence for the Riven session, mirroring
/// `SeerrSessionStore`'s `user_{uuid}_{baseKey}` scoping.
///
/// The password or API key ([RivenSession.secret]) is CredentialVault-protected
/// at the store boundary; a failed decrypt degrades to an empty secret (a
/// frontend session keeps working until its cookie expires) rather than
/// dropping the session.
class RivenSessionStore {
  // Shared across profile-keyed provider/store lifetimes. Enqueue the entire
  // operation before any preferences/vault await so a new load or clear cannot
  // overtake an old provider's still-encrypting save.
  static final SerialFutureQueue _persistence = SerialFutureQueue();

  const RivenSessionStore();

  String _scopedKey(String userUuid) => profileScopedPrefsKey(userUuid, rivenSessionBaseKey);

  Future<RivenSession?> load(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    // Outside the try below on purpose: an unreadable credential must
    // reach the repair prompt, not be swallowed as 'no session'.
    final raw = readTolerantString(prefs, _scopedKey(userUuid));
    if (raw == null) return null;
    try {
      final session = RivenSession.decode(raw);
      if (session.secret.isEmpty) return session;
      return session.copyWith(secret: await CredentialVault.reveal(session.secret) ?? '');
    } catch (_) {
      return null;
    }
  });

  Future<void> save(String userUuid, RivenSession session) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final protected = session.secret.isEmpty
        ? session
        : session.copyWith(secret: await CredentialVault.protect(session.secret));
    await prefs.setString(_scopedKey(userUuid), protected.encode());
  });

  Future<void> clear(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_scopedKey(userUuid));
  });
}
