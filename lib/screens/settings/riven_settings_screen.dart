import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/riven/riven_session.dart';
import '../../providers/riven_account_provider.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'riven_queue_screen.dart';

/// Connected-state settings for Riven: who is signed in, which install, the
/// queue, and disconnect.
class RivenSettingsScreen extends StatelessWidget {
  const RivenSettingsScreen({super.key});

  Future<void> _disconnect(BuildContext context, RivenAccountProvider account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.riven.disconnectConfirm,
      message: t.riven.disconnectConfirmBody,
      confirmText: t.common.disconnect,
      isDestructive: true,
    );
    if (!confirmed) return;
    await account.disconnect();
    // build()'s post-frame handler pops the screen once the provider rebuilds
    // with isConnected == false — don't pop here too.
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RivenAccountProvider>(
      builder: (context, account, _) {
        final session = account.session;
        // Safety net: if the session got invalidated in the background, bail
        // out — the Services hub row is the entry point for reconnecting.
        if (session == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
          return SettingsPage(title: Text(t.riven.title), children: const []);
        }

        final isFrontend = session.method == RivenAuthMethod.frontend;
        return SettingsPage(
          title: Text(t.riven.title),
          children: [
            SettingsGroup(
              children: [
                ListTile(
                  leading: AppIcon(isFrontend ? Symbols.account_circle_rounded : Symbols.key_rounded, fill: 1),
                  title: Text(isFrontend ? t.services.connectedAs(username: session.displayName) : t.riven.apiKey),
                  subtitle: Text(isFrontend ? t.riven.frontendInstance : t.riven.backendInstance),
                ),
                ListTile(
                  leading: const AppIcon(Symbols.dns_rounded, fill: 1),
                  title: Text(
                    session.version.isNotEmpty ? t.riven.versionLabel(version: session.version) : t.riven.title,
                  ),
                  subtitle: Text(session.baseUrl),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                SettingNavigationTile(
                  icon: Symbols.downloading_rounded,
                  title: t.riven.queue,
                  subtitle: t.riven.queueSubtitle,
                  destinationBuilder: (_) => const RivenQueueScreen(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                FocusableListTile(
                  leading: AppIcon(Symbols.link_off_rounded, fill: 1, color: Theme.of(context).colorScheme.error),
                  title: Text(t.common.disconnect, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () => unawaited(_disconnect(context, account)),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
