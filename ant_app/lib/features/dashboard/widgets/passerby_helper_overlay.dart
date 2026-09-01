import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/theme/app_colors.dart';

/// Full-screen route for the "Show Screen" Passerby Helper overlay: forces
/// landscape, solid bright yellow, massive black text. Tap anywhere to
/// dismiss and restore portrait.
class PasserbyHelperOverlay extends StatefulWidget {
  const PasserbyHelperOverlay({super.key, required this.message, required this.strings});

  final String message;
  final Dashboard strings;

  static Future<void> show(BuildContext context, String message, Dashboard strings) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, _, _) => PasserbyHelperOverlay(message: message, strings: strings),
      ),
    );
  }

  @override
  State<PasserbyHelperOverlay> createState() => _PasserbyHelperOverlayState();
}

class _PasserbyHelperOverlayState extends State<PasserbyHelperOverlay> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.passerbyHelperBackground,
      body: Semantics(
        label: '${widget.message}. ${widget.strings.passerbyOverlayTapToClose}',
        liveRegion: true,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.passerbyHelperText,
                  fontSize: 56,
                  fontWeight: FontWeight.w900,
                  height: 1.15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
