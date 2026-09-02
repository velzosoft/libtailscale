// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/material.dart';

import '../connect_form.dart';
import '../node_controller.dart';
import '../widgets/state_banner.dart';

/// Control-server preset, credential form, hostname, ephemeral switch and
/// the Connect / Disconnect / Log out buttons.
class ConnectScreen extends StatefulWidget {
  /// Creates the screen.
  const ConnectScreen({super.key, required this.controller});

  /// Owner of the form and the node.
  final NodeController controller;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _controlUrl;
  late final TextEditingController _authKey;
  late final TextEditingController _oauthId;
  late final TextEditingController _oauthSecret;
  late final TextEditingController _tags;
  late final TextEditingController _hostname;
  var _showSecrets = false;

  NodeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    final f = _c.form;
    _controlUrl = TextEditingController(text: f.controlUrl);
    _authKey = TextEditingController(text: f.authKey);
    _oauthId = TextEditingController(text: f.oauthClientId);
    _oauthSecret = TextEditingController(text: f.oauthClientSecret);
    _tags = TextEditingController(text: f.tags);
    _hostname = TextEditingController(text: f.hostname);
  }

  @override
  void dispose() {
    for (final c in [
      _controlUrl,
      _authKey,
      _oauthId,
      _oauthSecret,
      _tags,
      _hostname,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _update(ConnectForm next) => _c.updateForm(next);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) {
      final form = _c.form;
      final idle = _c.phase == ConsolePhase.idle;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StateBanner(controller: _c),
          _Section(
            title: 'Control server',
            children: [
              SegmentedButton<ControlServerPreset>(
                showSelectedIcon: false,
                segments: [
                  for (final preset in ControlServerPreset.values)
                    ButtonSegment(value: preset, label: Text(preset.label)),
                ],
                selected: {form.preset},
                onSelectionChanged: idle
                    ? (s) => _update(form.copyWith(preset: s.first))
                    : null,
              ),
              if (form.preset == ControlServerPreset.custom) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _controlUrl,
                  enabled: idle,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Control URL',
                    hintText: 'https://headscale.example.com',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _update(form.copyWith(controlUrl: v)),
                ),
              ],
            ],
          ),
          _Section(
            title: 'Credential',
            children: [
              DropdownMenu<CredentialKind>(
                initialSelection: form.credentialKind,
                enabled: idle,
                expandedInsets: EdgeInsets.zero,
                label: const Text('Method'),
                dropdownMenuEntries: [
                  for (final kind in CredentialKind.values)
                    DropdownMenuEntry(value: kind, label: kind.label),
                ],
                onSelected: (kind) {
                  if (kind != null) {
                    _update(form.copyWith(credentialKind: kind));
                  }
                },
              ),
              const SizedBox(height: 12),
              ..._credentialFields(form, idle),
            ],
          ),
          _Section(
            title: 'Node',
            children: [
              TextField(
                controller: _hostname,
                enabled: idle,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Hostname',
                  helperText: 'Also names the state directory.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _update(form.copyWith(hostname: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ephemeral'),
                subtitle: const Text(
                  'Removed from the tailnet when it disconnects.',
                ),
                value: form.ephemeral,
                onChanged: idle
                    ? (v) => _update(form.copyWith(ephemeral: v))
                    : null,
              ),
            ],
          ),
          if (_c.stateDir case final dir?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                'State directory: $dir',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (idle)
                FilledButton.icon(
                  key: const Key('connect-button'),
                  onPressed: _c.connect,
                  icon: const Icon(Icons.power),
                  label: const Text('Connect'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: _c.disconnect,
                  icon: const Icon(Icons.power_off),
                  label: Text(
                    _c.phase == ConsolePhase.connecting
                        ? 'Cancel'
                        : 'Disconnect',
                  ),
                ),
              if (_c.phase == ConsolePhase.connected)
                OutlinedButton.icon(
                  onPressed: () => _confirmLogout(context),
                  icon: const Icon(Icons.logout),
                  label: const Text('Log out'),
                ),
            ],
          ),
        ],
      );
    },
  );

  List<Widget> _credentialFields(ConnectForm form, bool idle) {
    final toggle = IconButton(
      tooltip: _showSecrets ? 'Hide' : 'Show',
      icon: Icon(_showSecrets ? Icons.visibility_off : Icons.visibility),
      onPressed: () => setState(() => _showSecrets = !_showSecrets),
    );
    switch (form.credentialKind) {
      case CredentialKind.authKey:
        return [
          TextField(
            key: const Key('auth-key-field'),
            controller: _authKey,
            enabled: idle,
            obscureText: !_showSecrets,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Auth key or pre-auth key',
              hintText: 'tskey-auth-…',
              border: const OutlineInputBorder(),
              suffixIcon: toggle,
            ),
            onChanged: (v) => _update(form.copyWith(authKey: v)),
          ),
        ];
      case CredentialKind.oauthClient:
        return [
          TextField(
            controller: _oauthId,
            enabled: idle,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'OAuth client id',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _update(form.copyWith(oauthClientId: v)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _oauthSecret,
            enabled: idle,
            obscureText: !_showSecrets,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'OAuth client secret',
              hintText: 'tskey-client-…',
              border: const OutlineInputBorder(),
              suffixIcon: toggle,
            ),
            onChanged: (v) => _update(form.copyWith(oauthClientSecret: v)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            enabled: idle,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'tag:demo, tag:mobile',
              helperText: 'The OAuth client must own these tags.',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _update(form.copyWith(tags: v)),
          ),
        ];
      case CredentialKind.interactive:
        return const [
          Text(
            'No key: the control server replies with a login URL, shown in '
            'the banner above while connecting. Approve it in a browser, or '
            'on Headscale run '
            'headscale auth register --auth-id <id from the URL> --user <user>.',
          ),
        ];
      case CredentialKind.existingState:
        return [
          Text(
            _c.savedStateExists
                ? 'Saved state found for "${form.hostname.trim()}": the node '
                      'reconnects with its stored key.'
                : 'No saved state for "${form.hostname.trim()}" yet. Connect '
                      'once with a key or interactively first.',
          ),
        ];
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'The node key is invalidated on the control server and the saved '
          'state cannot be reused. Disconnect instead to keep it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _c.logout();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}
