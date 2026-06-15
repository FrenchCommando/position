import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:position_core/position_core.dart';

import 'identity_sheet.dart';
import 'location_source.dart';
import 'providers.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Frame everyone: center on the single known dot, or fit the camera to all of
  /// them. No-op with a hint when nothing has been received yet.
  void _recenter() {
    final positions = ref.read(positionsProvider).asData?.value ?? const {};
    final points = positions.values.map((p) => LatLng(p.lat, p.lon)).toList();
    final local = ref.read(myLocalPositionProvider).asData?.value;
    if (local != null) points.add(LatLng(local.lat, local.lon));
    if (points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No positions yet.')),
      );
      return;
    }
    if (points.length == 1) {
      _mapController.move(points.first, 15);
      return;
    }
    _mapController.fitCamera(CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.all(48),
      maxZoom: 16,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(identityProvider);
    final positions = ref.watch(positionsProvider);
    final group = ref.watch(groupProvider);
    final sharing = ref.watch(sharingProvider);
    final localMe = ref.watch(myLocalPositionProvider).asData?.value;
    // Activate adoption of group keys wrapped to us by inviters.
    ref.watch(keyInboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Position'),
        actions: [
          IconButton(
            icon: const Icon(Icons.people),
            tooltip: 'Identity & friends',
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const IdentitySheet(),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Text(
            me.when(
              data: (kp) => 'me · ${kp.publicKey.substring(0, 12)}…'
                  '${group.asData?.value == null ? ' · no group' : ''}',
              loading: () => 'loading identity…',
              error: (e, _) => 'identity error: $e',
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
      // The map always renders; positions are markers layered on top. Loading
      // or an empty relay just means "no markers yet", never a blank screen.
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(48.8566, 2.3522),
              initialZoom: 12,
              // On desktop/web (manual source) tapping the map drops your
              // position there and publishes it — so two devices show as two
              // distinct dots instead of stacking on the default point.
              onTap: (_, latlng) async {
                final src = ref.read(locationSourceProvider);
                if (src is! ManualLocationSource) return;
                // Move my dot. If live sharing is on, its stream publishes the
                // move automatically; otherwise publish this one fix directly.
                src.set(latlng.latitude, latlng.longitude);
                if (ref.read(sharingProvider)) return;
                final messenger = ScaffoldMessenger.of(context);
                if (ref.read(groupProvider).asData?.value == null) {
                  messenger.showSnackBar(const SnackBar(
                    content: Text('Create or join a group first (tap the people icon).'),
                  ));
                  return;
                }
                final ok = await ref.read(publisherProvider).publishNow();
                if (!ok) {
                  messenger.showSnackBar(const SnackBar(
                    content: Text('Could not reach any relay — check your connection.'),
                  ));
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'io.github.frenchcommando.position',
              ),
              MarkerLayer(
                markers: _buildMarkers(
                  positions.asData?.value ?? const {},
                  me.asData?.value.publicKey,
                  localMe,
                ),
              ),
            ],
          ),
          if (positions.hasError)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Material(
                color: Colors.red.shade100,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('relay error: ${positions.error}'),
                ),
              ),
            ),
          if (ref.watch(pendingInvitesProvider).isNotEmpty)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Column(
                children: [
                  for (final invite in ref.watch(pendingInvitesProvider))
                    _InviteBanner(invite: invite),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'recenter',
            tooltip: 'Center on everyone',
            onPressed: _recenter,
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'sharetoggle',
            backgroundColor: sharing ? Colors.blue : null,
            foregroundColor: sharing ? Colors.white : null,
            onPressed: () {
              final messenger = ScaffoldMessenger.of(context);
              if (!sharing && ref.read(groupProvider).asData?.value == null) {
                messenger.showSnackBar(const SnackBar(
                  content: Text('Create or join a group first (tap the people icon).'),
                ));
                return;
              }
              ref.read(sharingProvider.notifier).toggle();
            },
            icon: Icon(sharing ? Icons.location_on : Icons.location_off),
            label: Text(sharing ? 'Sharing live' : 'Share live'),
          ),
        ],
      ),
    );
  }

  /// Friends' dots from the relay, plus my own dot — preferring my instant local
  /// fix (web) over the relay echo, so I see myself before/without publishing.
  List<Marker> _buildMarkers(
    Map<String, Position> relay,
    String? mePub,
    Position? localMe,
  ) {
    final markers = <Marker>[];
    for (final entry in relay.entries) {
      if (entry.key == mePub) continue; // my own dot handled below
      markers.add(_marker(entry.key, entry.value, mePub));
    }
    final mine = localMe ?? (mePub != null ? relay[mePub] : null);
    if (mine != null && mePub != null) {
      markers.add(_marker(mePub, mine, mePub));
    }
    return markers;
  }

  Marker _marker(String pubkey, Position p, String? mePubkey) {
    final isMe = pubkey == mePubkey;
    final label = (p.name != null && p.name!.isNotEmpty)
        ? p.name!
        : (isMe ? 'me' : '${pubkey.substring(0, 6)}…');
    return Marker(
      point: LatLng(p.lat, p.lon),
      width: 120,
      height: 56,
      // topCenter places the whole box above the point, so the box's bottom
      // (the pin tip) lands on the coordinate; label floats above.
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ),
          Icon(
            Icons.location_on,
            color: isMe ? Colors.blue : Colors.deepOrange,
            size: 32,
          ),
        ],
      ),
    );
  }
}

/// Prompt for a group key wrapped to us that we haven't joined yet. Accept adopts
/// the key (joining the group); Decline drops it so we're never pulled in silently.
class _InviteBanner extends ConsumerWidget {
  const _InviteBanner({required this.invite});

  final PendingInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(pendingInvitesProvider.notifier);
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.group_add),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${invite.senderPub.substring(0, 8)}… invited you to a group.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => notifier.decline(invite),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => notifier.accept(invite),
              child: const Text('Accept'),
            ),
          ],
        ),
      ),
    );
  }
}
