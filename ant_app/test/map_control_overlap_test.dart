// "The map full screen button covers the current location button."
//
// Not two of this app's buttons — those sit in opposite corners (fullscreen
// top-right, recentre bottom-right). The one underneath is Google's, drawn
// inside the platform view where nothing in `dashboard_map_panel.dart` can
// see it: my-location top-right, zoom buttons bottom-right, compass top-left,
// toolbar bottom-right. All four are enabled, deliberately, and this app then
// stacks its own chrome in the same corners.
//
// `GoogleMap.padding` is the supported way to move them, and it only works
// while the inset actually clears the buttons it is meant to clear. That is
// the relationship these tests hold: the padding and the `Positioned` values
// are derived from the same constants, so changing a button's size or
// position without revisiting the padding puts the collision straight back.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/dashboard/widgets/dashboard_map_panel.dart';

void main() {
  group('native map controls clear the app overlay', () {
    test('the reserved edge covers a whole overlay button', () {
      // 12pt from the edge, 44pt across — the button occupies 12..56, so
      // anything Google draws inside 56 is underneath it.
      expect(DashboardMapPanel.overlayReservedEdge, 56);
    });

    test('the top inset clears the fullscreen toggle', () {
      // The reported collision: Google's my-location button is top-right on
      // Android, and the fullscreen toggle is drawn on top of it.
      expect(
        DashboardMapPanel.nativeControlPadding.top,
        greaterThanOrEqualTo(DashboardMapPanel.overlayReservedEdge),
      );
    });

    test('the bottom inset clears the recentre button', () {
      // Same collision, other corner: Google's zoom controls are bottom-right.
      expect(
        DashboardMapPanel.nativeControlPadding.bottom,
        greaterThanOrEqualTo(DashboardMapPanel.overlayReservedEdge),
      );
    });

    test('the inset is symmetric, so recentring stays centred', () {
      // `padding` also moves the camera's idea of centre. An asymmetric inset
      // would quietly put the user's own location off-centre on every
      // recentre, which is a worse bug than the one being fixed.
      expect(
        DashboardMapPanel.nativeControlPadding.top,
        DashboardMapPanel.nativeControlPadding.bottom,
      );
    });

    test('nothing is pushed sideways', () {
      // Horizontal insets would walk the zoom buttons into the middle of the
      // map and the compass under the route banner. And the Google logo sits
      // bottom-left: obscuring or displacing it breaks the Maps terms.
      expect(DashboardMapPanel.nativeControlPadding.left, 0);
      expect(DashboardMapPanel.nativeControlPadding.right, 0);
    });
  });
}
