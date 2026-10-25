import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../models/riven/riven_session.dart';
import '../../providers/riven_account_provider.dart';
import '../../services/riven/riven_auth_service.dart';
import '../../services/riven/riven_exceptions.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';

/// Two-step Riven connect flow:
///   1. Probe the URL, racing https/http/default-port candidates for
///      schemeless input like the Seerr connect flow, to learn whether the
///      web app (better-auth login) or a bare backend (API key) answers.
///   2. Ask for the one credential that surface takes.
///
/// The finished [RivenSession] is handed to [RivenAccountProvider.adoptSession]
/// and the screen pops.
class RivenConnectScreen extends StatefulWidget {
  const RivenConnectScreen({super.key});

  @override
  State<RivenConnectScreen> createState() => _RivenConnectScreenState();
}

class _RivenConnectScreenState extends State<RivenConnectScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _secretController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'RivenConnect:Url');
  final _continueFocus = FocusNode(debugLabel: 'RivenConnect:Continue');
  final _changeServerFocus = FocusNode(debugLabel: 'RivenConnect:ChangeServer');
  final _usernameFocus = FocusNode(debugLabel: 'RivenConnect:Username');
  final _secretFocus = FocusNode(debugLabel: 'RivenConnect:Secret');
  final _formKey = GlobalKey<FormState>();

  RivenReachableInstance? _instance;

  @override
  void dispose() {
    _urlFocus.dispose();
    _continueFocus.dispose();
    _changeServerFocus.dispose();
    _usernameFocus.dispose();
    _secretFocus.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      setErrorText(t.addServer.required);
      return;
    }
    await runAsync<void>(() async {
      final account = context.read<RivenAccountProvider>();
      final reached = await account.authService.probeFirstReachable(input);
      if (!mounted) return;
      setState(() => _instance = reached);
      requestFocusAfterFrame(reached.method == RivenAuthMethod.frontend ? _usernameFocus : _secretFocus);
    }, errorMapper: _describeError);
  }

  Future<void> _signIn() async {
    final instance = _instance;
    if (instance == null || !(_formKey.currentState?.validate() ?? false)) return;
    await runAsync<void>(() async {
      final account = context.read<RivenAccountProvider>();
      final session = switch (instance.method) {
        RivenAuthMethod.frontend => await account.authService.signInWithPassword(
          baseUrl: instance.baseUrl,
          username: _usernameController.text.trim(),
          password: _secretController.text,
        ),
        RivenAuthMethod.apiKey => await account.authService.signInWithApiKey(
          baseUrl: instance.baseUrl,
          apiKey: _secretController.text.trim(),
        ),
      };
      await account.adoptSession(session);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    }, errorMapper: _describeError);
  }

  String _describeError(Object e) => switch (e) {
    RivenUrlException(:final message, :final display) => display ?? message,
    RivenAuthException(:final message, :final display) => display ?? message,
    RivenProxyException(:final display) => display,
    RivenApiException(:final message) => message,
    _ => t.addServer.couldNotReachServer(error: e.toString()),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instance = _instance;
    return FocusedScrollScaffold(
      title: Text(t.riven.connectTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: instance == null ? _buildUrlStep(theme) : _buildSignInStep(theme, instance),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildUrlStep(ThemeData theme) {
    return [
      FocusableTextFormField(
        controller: _urlController,
        focusNode: _urlFocus,
        autofocus: true,
        tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        onNavigateDown: () => _continueFocus.requestFocus(),
        textInputAction: TextInputAction.go,
        onFieldSubmitted: busy ? null : (_) => _probe(),
        decoration: InputDecoration(
          labelText: t.riven.serverUrl,
          // URL example — intentionally not localized.
          hintText: 'https://riven.example.com',
          helperText: t.riven.serverUrlHelper,
          prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
        ),
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _continueFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _urlFocus.requestFocus(),
        onPressed: busy ? null : _probe,
        child: FilledButton.icon(
          onPressed: busy ? null : _probe,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.travel_explore_rounded, fill: 1),
          label: Text(t.riven.checkServer),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  List<Widget> _buildSignInStep(ThemeData theme, RivenReachableInstance instance) {
    final isFrontend = instance.method == RivenAuthMethod.frontend;
    return [
      _buildInstanceCard(theme, instance),
      const SizedBox(height: 16),
      if (isFrontend) ...[
        FocusableTextFormField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: busy ? null : (_) => _secretFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: t.addServer.username,
            prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
          ),
          validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
        ),
        const SizedBox(height: 12),
      ],
      FocusableTextFormField(
        controller: _secretController,
        focusNode: _secretFocus,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !busy,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: busy ? null : (_) => _signIn(),
        decoration: InputDecoration(
          labelText: isFrontend ? t.addServer.password : t.riven.apiKey,
          helperText: isFrontend ? null : t.riven.apiKeyHelper,
          prefixIcon: AppIcon(isFrontend ? Symbols.lock_rounded : Symbols.key_rounded, fill: 1),
        ),
        validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
      ),
      const SizedBox(height: 16),
      FocusableButton(
        useBackgroundFocus: true,
        onPressed: busy ? null : _signIn,
        child: FilledButton.icon(
          onPressed: busy ? null : _signIn,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
          label: Text(isFrontend ? t.addServer.signIn : t.common.connect),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  Widget _buildInstanceCard(ThemeData theme, RivenReachableInstance instance) {
    final label = instance.method == RivenAuthMethod.frontend ? t.riven.frontendInstance : t.riven.backendInstance;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        children: [
          const AppIcon(Symbols.cloud_done_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                Text(
                  instance.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          FocusableButton(
            focusNode: _changeServerFocus,
            useBackgroundFocus: true,
            onPressed: busy ? null : _resetToUrlStep,
            child: TextButton(onPressed: busy ? null : _resetToUrlStep, child: Text(t.addServer.change)),
          ),
        ],
      ),
    );
  }

  void _resetToUrlStep() {
    setState(() {
      _instance = null;
      _usernameController.clear();
      _secretController.clear();
    });
  }
}
