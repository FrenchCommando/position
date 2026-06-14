import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'providers.dart';

/// Bottom sheet for identity + group management: show my key (text + QR for
/// in-person exchange), create a group, and invite a friend by their pubkey.
class IdentitySheet extends ConsumerStatefulWidget {
  const IdentitySheet({super.key});

  @override
  ConsumerState<IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends ConsumerState<IdentitySheet> {
  final _friendCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _nameInit = false;
  String? _status;

  @override
  void dispose() {
    _friendCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(identityProvider);
    final group = ref.watch(groupProvider);
    // Seed the name field once from stored value; don't fight the user's typing.
    ref.watch(myNameProvider).whenData((n) {
      if (!_nameInit) {
        _nameCtrl.text = n;
        _nameInit = true;
      }
    });

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Your key', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          me.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('identity error: $e'),
            data: (kp) => Column(
              children: [
                Center(
                  child: QrImageView(data: kp.publicKey, size: 160),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  kp.publicKey,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: kp.publicKey));
                    setState(() => _status = 'key copied');
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy key'),
                ),
              ],
            ),
          ),
          const Divider(height: 24),
          Text('Your name', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Shown to friends on the map',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _saveName(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _saveName, child: const Text('Save')),
            ],
          ),
          const Divider(height: 24),
          group.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('group error: $e'),
            data: (g) => g == null ? _noGroup() : _inGroup(),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_status!, style: const TextStyle(color: Colors.green)),
            ),
        ],
      ),
    );
  }

  Widget _noGroup() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "You're not in a group yet. Share your key above with a friend who'll "
            "add you — the group key then arrives here automatically. Only one "
            "person should Create the group; if you both create, you each get a "
            "different key and won't see each other.",
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              await ref.read(groupProvider.notifier).createGroup();
              setState(() => _status = 'group created — now add a friend');
            },
            icon: const Icon(Icons.group_add),
            label: const Text('Create group'),
          ),
        ],
      );

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
  bool get _validFriendKey => _hex64.hasMatch(_friendCtrl.text.trim());

  Widget _inGroup() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add a friend', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Your friend shares their key with you (their Copy button or QR). '
            'Paste it here to give them the group key.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _friendCtrl,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: "Paste your friend's key",
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _validFriendKey
                ? () async {
                    try {
                      await ref.read(groupProvider.notifier).addFriend(_friendCtrl.text.trim());
                      _friendCtrl.clear();
                      setState(() => _status = 'added — they get the group key on next connect');
                    } catch (e) {
                      setState(() => _status = 'failed: $e');
                    }
                  }
                : null,
            icon: const Icon(Icons.person_add),
            label: const Text('Add to group'),
          ),
          const SizedBox(height: 16),
          _members(),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _confirmLeave,
            icon: const Icon(Icons.logout, size: 16, color: Colors.red),
            label: const Text('Leave group', style: TextStyle(color: Colors.red)),
          ),
        ],
      );

  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text(
          'Drops your group key and member list. Use this to recover from a fork '
          '(you both created a group): leave, then have the other person add you. '
          'Your key stays the same, so they can re-add you.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(groupProvider.notifier).leaveGroup();
    setState(() => _status = 'left the group');
  }

  Future<void> _saveName() async {
    await ref.read(myNameProvider.notifier).setName(_nameCtrl.text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => _status = 'name saved');
  }

  Widget _members() {
    final members = ref.watch(membersProvider);
    final positions = ref.watch(positionsProvider).asData?.value ?? const {};
    return members.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('members error: $e'),
      data: (list) {
        if (list.isEmpty) {
          return const Text('No members yet.', style: TextStyle(fontSize: 13));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Members', style: Theme.of(context).textTheme.titleMedium),
            for (final pub in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  positions[pub]?.name?.isNotEmpty == true
                      ? positions[pub]!.name!
                      : '${pub.substring(0, 16)}…',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  positions[pub] != null
                      ? 'updated ${_ago(positions[pub]!.t)}'
                      : 'no position yet',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.person_remove, color: Colors.red),
                  tooltip: 'Remove (re-keys the group)',
                  onPressed: () => _confirmRemove(pub),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Compact relative age of a unix-seconds timestamp, e.g. "3m ago".
  static String _ago(int unixSeconds) {
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000));
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Future<void> _confirmRemove(String pub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text(
          'This mints a new group key for everyone else. '
          '${pub.substring(0, 16)}… can no longer see the group.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(groupProvider.notifier).removeMember(pub);
      setState(() => _status = 'removed — group re-keyed; others get the new key on next connect');
    } catch (e) {
      setState(() => _status = 'remove failed: $e');
    }
  }
}
