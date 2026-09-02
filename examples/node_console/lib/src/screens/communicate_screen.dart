// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/material.dart';

import '../chat_service.dart';
import '../http_probe.dart';
import '../node_controller.dart';
import '../widgets/key_value_list.dart';

/// Chat with a peer over TCP and fetch a URL over the tailnet.
class CommunicateScreen extends StatefulWidget {
  /// Creates the screen.
  const CommunicateScreen({super.key, required this.controller});

  /// Owner of the node and the chat service.
  final NodeController controller;

  @override
  State<CommunicateScreen> createState() => _CommunicateScreenState();
}

class _CommunicateScreenState extends State<CommunicateScreen> {
  final _host = TextEditingController();
  final _message = TextEditingController();
  final _url = TextEditingController(text: 'http://');
  var _sending = false;
  var _fetching = false;
  FetchResult? _fetchResult;
  String? _fetchError;

  NodeController get _c => widget.controller;
  ChatService get _chat => widget.controller.chat;

  @override
  void dispose() {
    _host.dispose();
    _message.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final host = _host.text.trim();
    final text = _message.text.trim();
    if (host.isEmpty || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _chat.send(host, text);
      _message.clear();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _fetch() async {
    final node = _c.node;
    final url = Uri.tryParse(_url.text.trim());
    if (node == null || _fetching) return;
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      setState(() => _fetchError = 'Enter a full URL, e.g. http://peer:8080/');
      return;
    }
    setState(() {
      _fetching = true;
      _fetchError = null;
    });
    try {
      final result = await fetchOverTailnet(node, url);
      if (mounted) setState(() => _fetchResult = result);
    } catch (e) {
      if (mounted) setState(() => _fetchError = '$e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_c, _chat]),
    builder: (context, _) {
      if (_c.phase != ConsolePhase.connected) {
        return const EmptyPlaceholder(
          icon: Icons.chat_bubble_outline,
          text:
              'Connect first. Then pick a peer, send a line, and fetch URLs '
              'over the tailnet.',
        );
      }
      final peers = _c.status?.peers ?? const [];
      final messages = _chat.messages;
      final scheme = Theme.of(context).colorScheme;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Icon(
                  _chat.listening ? Icons.hearing : Icons.hearing_disabled,
                  size: 18,
                  color: _chat.listening ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _chat.listening
                        ? 'Chat listener on port ${_chat.port}'
                        : (_chat.listenError ?? 'Listener stopped'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (!_chat.listening)
                  TextButton(
                    onPressed: _chat.ensureListening,
                    child: const Text('Restart'),
                  ),
                TextButton(onPressed: _chat.clear, child: const Text('Clear')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _host,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Peer (MagicDNS name or IP)',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: PopupMenuButton<String>(
                  tooltip: 'Pick a peer',
                  icon: const Icon(Icons.arrow_drop_down),
                  enabled: peers.isNotEmpty,
                  onSelected: (host) => _host.text = host,
                  itemBuilder: (context) => [
                    for (final peer in peers)
                      PopupMenuItem(
                        value: peer.magicDnsName.isNotEmpty
                            ? peer.magicDnsName
                            : (peer.ipv4 ?? peer.ipv6 ?? ''),
                        child: Text('${peer.online ? '●' : '○'} ${peer.name}'),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _message,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? const EmptyPlaceholder(
                    icon: Icons.forum_outlined,
                    text:
                        'No messages yet. Lines arriving on the listener show '
                        'up here with their sender.',
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, i) =>
                        _MessageBubble(messages[messages.length - 1 - i]),
                  ),
          ),
          const Divider(height: 1),
          ExpansionTile(
            title: const Text('HTTP fetch over the tailnet'),
            subtitle: _fetchResult == null
                ? null
                : Text(
                    '${_fetchResult!.statusCode} · ${_fetchResult!.bodyBytes} '
                    'bytes · ${_fetchResult!.elapsed.inMilliseconds} ms',
                  ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _url,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'URL',
                        hintText: 'http://peer:8080/health',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _fetch(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _fetching ? null : _fetch,
                    child: const Text('Fetch'),
                  ),
                ],
              ),
              if (_fetching) const LinearProgressIndicator(),
              if (_fetchError case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    error,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (_fetchResult case final result?) _FetchCard(result),
            ],
          ),
        ],
      );
    },
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(this.message);

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final time = _formatTime(message.at);
    switch (message.direction) {
      case ChatDirection.system:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              '$time · ${message.text}',
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      case ChatDirection.incoming:
      case ChatDirection.outgoing:
        final outgoing = message.direction == ChatDirection.outgoing;
        return Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: outgoing
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${outgoing ? 'to' : 'from'} ${message.peer} · $time',
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (outgoing) ...[
                      const SizedBox(width: 4),
                      Icon(
                        message.delivered ? Icons.done_all : Icons.schedule,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                SelectableText(message.text),
              ],
            ),
          ),
        );
    }
  }
}

class _FetchCard extends StatelessWidget {
  const _FetchCard(this.result);

  final FetchResult result;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mono = text.bodySmall?.copyWith(fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        SelectableText(
          '${result.statusCode} ${result.reasonPhrase} · '
          '${result.bodyBytes} bytes · ${result.elapsed.inMilliseconds} ms',
          style: text.titleSmall,
        ),
        const SizedBox(height: 6),
        for (final entry in result.headers.entries)
          SelectableText('${entry.key}: ${entry.value}', style: mono),
        if (result.preview.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(result.preview, style: mono, maxLines: 20),
          ),
        ],
      ],
    );
  }
}

String _formatTime(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}
