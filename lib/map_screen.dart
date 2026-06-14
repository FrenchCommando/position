import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:position_core/position_core.dart';

import 'identity_sheet.dart';
import 'location_source.dart';
import 'providers.dart';

class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(identityProvider);
    final positions = ref.watch(positionsProvider);
    final group = ref.watch(groupProvider);
    final sharing = ref.watch(sharingProvider);
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
                markers: [
                  for (final entry in (positions.asData?.value ?? const {}).entries)
                    _marker(entry.key, entry.value, me.asData?.value.publicKey),
                ],
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
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
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
    );
  }

  Marker _marker(String pubkey, Position p, String? mePubkey) {
    final isMe = pubkey == mePubkey;
    return Marker(
      point: LatLng(p.lat, p.lon),
      width: 40,
      height: 40,
      child: Icon(
        Icons.location_on,
        color: isMe ? Colors.blue : Colors.deepOrange,
        size: 40,
      ),
    );
  }
}
