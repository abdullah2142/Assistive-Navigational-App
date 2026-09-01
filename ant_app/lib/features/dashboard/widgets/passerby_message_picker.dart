import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import 'passerby_helper_overlay.dart';

/// Shown before the Passerby Helper overlay itself: lets the user pick one
/// of their onboarding-selected messages, or compose a new one on the spot,
/// instead of the overlay jumping straight to a single hardcoded message.
class PasserbyMessagePicker {
  PasserbyMessagePicker._();

  static Future<void> show(BuildContext context, {required List<String> messages, required Dashboard strings}) async {
    final composeController = TextEditingController();
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PickerSheet(messages: messages, composeController: composeController, strings: strings),
    );
    composeController.dispose();
    if (chosen == null || chosen.trim().isEmpty) return;
    if (!context.mounted) return;
    await PasserbyHelperOverlay.show(context, chosen.trim(), strings);
  }
}

class _PickerSheet extends StatelessWidget {
  const _PickerSheet({required this.messages, required this.composeController, required this.strings});

  final List<String> messages;
  final TextEditingController composeController;
  final Dashboard strings;

  void _submitCompose(BuildContext context) {
    final text = composeController.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = strings;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(d.passerbyPickerTitle, style: theme.textTheme.headlineSmall),
              ),
              const SizedBox(height: 4),
              Text(d.passerbyPickerSubtitle, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final message in messages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Semantics(
                            button: true,
                            label: message,
                            child: Material(
                              color: theme.scaffoldBackgroundColor,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => Navigator.of(context).pop(message),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                  alignment: Alignment.centerLeft,
                                  child: Text(message, style: theme.textTheme.titleSmall),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      textField: true,
                      label: d.passerbyWriteFieldSemantics,
                      child: TextField(
                        controller: composeController,
                        decoration: InputDecoration(hintText: d.passerbyPickerComposeHint),
                        onSubmitted: (_) => _submitCompose(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: d.passerbySpeakSemantics,
                    hint: d.passerbySpeakHint,
                    child: Material(
                      color: theme.colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(d.chatVoiceUnavailable)),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Icon(Icons.mic_rounded, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _submitCompose(context),
                  child: Text(d.passerbyPickerShowButton),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
