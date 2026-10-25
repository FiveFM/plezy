import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../i18n/app_locale_utils.dart';
import '../i18n/strings.g.dart';
import '../models/catalog/catalog_item.dart';
import '../models/riven/riven_item.dart';
import '../services/riven/riven_client.dart';
import '../services/riven/riven_exceptions.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'catalog_source_logo.dart';
import 'loading_indicator_box.dart';
import 'overlay_sheet.dart';

/// What the Riven item sheet did before closing itself; the opener re-reads
/// the item and reports it on its own scaffold, since the sheet is unmounting.
enum RivenItemAction { retried, reset, removed }

String rivenStateLabel(RivenItemState state) => switch (state) {
  RivenItemState.unknown => t.riven.states.unknown,
  RivenItemState.unreleased => t.riven.states.unreleased,
  RivenItemState.ongoing => t.riven.states.ongoing,
  RivenItemState.requested => t.riven.states.requested,
  RivenItemState.indexed => t.riven.states.indexed,
  RivenItemState.scraped => t.riven.states.scraped,
  RivenItemState.downloaded => t.riven.states.downloaded,
  RivenItemState.symlinked => t.riven.states.symlinked,
  RivenItemState.completed => t.riven.states.completed,
  RivenItemState.partiallyCompleted => t.riven.states.partiallyCompleted,
  RivenItemState.failed => t.riven.states.failed,
  RivenItemState.paused => t.riven.states.paused,
};

IconData rivenStateIcon(RivenItemState state) => switch (state) {
  RivenItemState.completed || RivenItemState.partiallyCompleted || RivenItemState.ongoing => Symbols.cloud_done_rounded,
  RivenItemState.failed => Symbols.error_rounded,
  RivenItemState.paused => Symbols.pause_circle_rounded,
  RivenItemState.unreleased => Symbols.event_upcoming_rounded,
  RivenItemState.unknown => Symbols.help_rounded,
  RivenItemState.requested ||
  RivenItemState.indexed ||
  RivenItemState.scraped ||
  RivenItemState.downloaded ||
  RivenItemState.symlinked => Symbols.downloading_rounded,
};

/// Error-colored for a failure, primary once the file is in the library,
/// ambient otherwise.
Color? rivenStateColor(RivenItemState state, ColorScheme colors) => switch (state) {
  RivenItemState.failed => colors.error,
  _ when state.isAvailable => colors.primary,
  _ => null,
};

/// The snackbar text for an action the sheet completed.
String rivenItemActionMessage(RivenItemAction action) => switch (action) {
  RivenItemAction.retried => t.riven.retryStarted,
  RivenItemAction.reset => t.riven.resetStarted,
  RivenItemAction.removed => t.riven.removed,
};

/// Open the sheet for a title Riven tracks: where it is in the pipeline and
/// the actions that make sense from there. Resolves with what was done, or
/// null when dismissed.
Future<RivenItemAction?> showRivenItemSheet(
  BuildContext context, {
  required RivenClient client,
  required RivenItem item,
  required String title,
}) async {
  final action = await OverlaySheetController.showAdaptive<RivenItemAction>(
    context,
    showDragHandle: true,
    builder: (_) => RivenItemSheet(client: client, item: item, title: title),
  );
  if (action != null && context.mounted) showSuccessSnackBar(context, rivenItemActionMessage(action));
  return action;
}

class RivenItemSheet extends StatefulWidget {
  final RivenClient client;
  final RivenItem item;

  /// The caller's title for the item: the catalog's localized one where it
  /// has it, which Riven's own (indexer-language) title need not match.
  final String title;

  const RivenItemSheet({super.key, required this.client, required this.item, required this.title});

  @override
  State<RivenItemSheet> createState() => _RivenItemSheetState();
}

class _RivenItemSheetState extends State<RivenItemSheet> {
  RivenItemAction? _running;
  String? _errorText;

  RivenItemState get _state => widget.item.state;

  /// Retry re-runs the pipeline from scraping; there is nothing to retry
  /// once the file is in the library, and nothing to find for a title that
  /// has not been released.
  bool get _canRetry => !_state.isAvailable && _state != RivenItemState.unreleased;

  /// Reset blacklists the release Riven settled on, which only exists once
  /// something reached the library.
  bool get _canReset => _state.isAvailable;

  Future<void> _run(RivenItemAction action) async {
    if (_running != null) return;
    if (action == RivenItemAction.removed) {
      final confirmed = await showConfirmDialog(
        context,
        title: t.riven.removeConfirm(title: widget.title),
        message: t.riven.removeConfirmBody,
        confirmText: t.riven.remove,
        isDestructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _running = action;
      _errorText = null;
    });
    try {
      final id = widget.item.id;
      await switch (action) {
        RivenItemAction.retried => widget.client.retryItem(id),
        RivenItemAction.reset => widget.client.resetItem(id),
        RivenItemAction.removed => widget.client.removeItem(id),
      };
      if (!mounted) return;
      // The sheet may be hosted by an OverlaySheetHost (no route of its own),
      // so a bare Navigator.pop would pop the screen underneath instead.
      OverlaySheetController.closeAdaptive(context, action);
    } catch (e) {
      appLogger.w('Riven: ${action.name} failed for item ${widget.item.id}', error: e);
      if (!mounted) return;
      setState(() {
        _running = null;
        _errorText = t.riven.actionFailed(error: rivenErrorReason(e));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requestedAt = widget.item.requestedAt;
    final mutedStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7));
    final actions = <(RivenItemAction, String, IconData)>[
      if (_canRetry) (RivenItemAction.retried, t.riven.retry, Symbols.refresh_rounded),
      if (_canReset) (RivenItemAction.reset, t.riven.reset, Symbols.find_replace_rounded),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CatalogSourceLogo(CatalogSourceId.riven, size: 22),
              const SizedBox(width: 10),
              Text(t.riven.title, style: theme.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 2),
          Text(widget.title, style: mutedStyle, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          Row(
            children: [
              AppIcon(rivenStateIcon(_state), fill: 1, color: rivenStateColor(_state, theme.colorScheme)),
              const SizedBox(width: 10),
              Expanded(child: Text(rivenStateLabel(_state), style: theme.textTheme.titleMedium)),
            ],
          ),
          if (requestedAt != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: Text(
                t.riven.requestedOn(
                  date: DateFormat.yMMMd(LocaleSettings.currentLocale.intlLocaleName).format(requestedAt),
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ),
          ],
          const SizedBox(height: 20),
          for (final (index, (action, label, icon)) in actions.indexed) ...[
            FocusableButton(
              autofocus: index == 0,
              useBackgroundFocus: true,
              onPressed: _running == null ? () => unawaited(_run(action)) : null,
              child: FilledButton.tonalIcon(
                onPressed: _running == null ? () => unawaited(_run(action)) : null,
                icon: _running == action ? const LoadingIndicatorBox() : AppIcon(icon, fill: 1),
                label: Text(label),
              ),
            ),
            const SizedBox(height: 8),
          ],
          FocusableButton(
            autofocus: actions.isEmpty,
            useBackgroundFocus: true,
            onPressed: _running == null ? () => unawaited(_run(RivenItemAction.removed)) : null,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: _running == null ? () => unawaited(_run(RivenItemAction.removed)) : null,
              icon: _running == RivenItemAction.removed
                  ? const LoadingIndicatorBox()
                  : AppIcon(Symbols.delete_rounded, fill: 1, color: theme.colorScheme.error),
              label: Text(t.riven.remove),
            ),
          ),
          if (_errorText case final String error) ...[
            const SizedBox(height: 12),
            Text(error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
