import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../models/riven/riven_item.dart';
import '../../providers/riven_account_provider.dart';
import '../../services/riven/riven_client.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/riven_item_sheet.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// Every movie and show Riven has not finished, newest request first, each
/// opening the same item sheet the catalog detail screen does.
///
/// Finished titles stay out — that is the library — and so do airing shows
/// whose released episodes are all in: Riven lists those as [RivenItemState.ongoing]
/// for as long as the show runs, which would bury the titles that need a look.
class RivenQueueScreen extends StatefulWidget {
  const RivenQueueScreen({super.key});

  @override
  State<RivenQueueScreen> createState() => _RivenQueueScreenState();
}

class _RivenQueueScreenState extends State<RivenQueueScreen> {
  static const _queueStates = [
    RivenItemState.failed,
    RivenItemState.paused,
    RivenItemState.unknown,
    RivenItemState.requested,
    RivenItemState.indexed,
    RivenItemState.scraped,
    RivenItemState.downloaded,
    RivenItemState.symlinked,
    RivenItemState.unreleased,
  ];

  /// The client the visible pages came from. A reconnect replaces the
  /// provider's client; pages loaded through the old one are dropped.
  RivenClient? _client;
  List<RivenItem> _items = const [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loadFailed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = context.watch<RivenAccountProvider>().client;
    if (identical(client, _client)) return;
    _client = client;
    if (client == null) {
      // Disconnected underneath us; the settings screen pops itself too.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    // Assigned directly: this runs ahead of the build it triggers, where a
    // setState would be redundant at best.
    _loading = true;
    _loadFailed = false;
    unawaited(_loadPage(1));
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    await _loadPage(1);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    await _loadPage(_page + 1);
  }

  Future<void> _loadPage(int page) async {
    final client = _client;
    if (client == null) return;
    try {
      final result = await client.getItems(states: _queueStates, page: page);
      if (!mounted || !identical(client, _client)) return;
      setState(() {
        _items = page == 1 ? result.items : [..._items, ...result.items];
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      appLogger.w('Riven: queue page $page failed to load', error: e);
      if (!mounted || !identical(client, _client)) return;
      setState(() {
        // A failed "load more" keeps what is already on screen.
        _loadFailed = page == 1;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _openItem(RivenItem item) async {
    final client = _client;
    if (client == null) return;
    final action = await showRivenItemSheet(context, client: client, item: item, title: item.title ?? '');
    if (action != null && mounted) unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6));
    return SettingsPage(
      title: Text(t.riven.queue),
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: LoadingIndicatorBox()),
          )
        else if (_loadFailed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
            child: Column(
              children: [
                Text(t.riven.queueLoadFailed, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                FocusableButton(
                  autofocus: true,
                  onPressed: () => unawaited(_reload()),
                  child: OutlinedButton(onPressed: () => unawaited(_reload()), child: Text(t.common.retry)),
                ),
              ],
            ),
          )
        else if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
            child: Text(t.riven.queueEmpty, style: mutedStyle, textAlign: TextAlign.center),
          )
        else ...[
          SettingsGroup(
            children: [
              for (final (index, item) in _items.indexed)
                FocusableListTile(
                  autofocus: index == 0,
                  leading: AppIcon(
                    rivenStateIcon(item.state),
                    fill: 1,
                    color: rivenStateColor(item.state, theme.colorScheme),
                  ),
                  title: Text(item.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${rivenStateLabel(item.state)} · ${item.kind.label}'),
                  trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                  onTap: () => unawaited(_openItem(item)),
                ),
            ],
          ),
          if (_hasMore) ...[
            const SizedBox(height: 12),
            Center(
              child: FocusableButton(
                onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
                child: OutlinedButton.icon(
                  onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
                  icon: _loadingMore
                      ? const LoadingIndicatorBox()
                      : const AppIcon(Symbols.expand_more_rounded, fill: 1),
                  label: Text(t.riven.loadMore),
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}
