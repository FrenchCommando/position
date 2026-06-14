import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:position_core/position_core.dart';

import 'package:position/map_screen.dart';
import 'package:position/providers.dart';

/// A group controller that does no IO — starts with no group.
class _TestGroupController extends GroupController {
  @override
  Future<GroupSession?> build() async => null;
}

void main() {
  testWidgets('renders the map screen with the local identity', (tester) async {
    final me = generateKeyPair();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith((ref) async => me),
          groupProvider.overrideWith(_TestGroupController.new),
          // Keep these from touching the live relay/tiles in the sandbox.
          keyInboxProvider.overrideWith((ref) => Stream<int>.empty()),
          positionsProvider.overrideWith((ref) => Stream<Map<String, Position>>.empty()),
        ],
        child: const MaterialApp(home: MapScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Position'), findsOneWidget);
    expect(find.textContaining(me.publicKey.substring(0, 12)), findsOneWidget);
    expect(find.textContaining('no group'), findsOneWidget);
  });
}
