import 'package:flutter/material.dart';

/// Shared shell for every onboarding screen: a Semantics-announced header,
/// optional back button, scrollable body, and a fixed primary action at the
/// bottom so it's always reachable without hunting for it.
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onBack,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.primaryActionEnabled = true,
    this.isLoading = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onBack;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool primaryActionEnabled;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: onBack == null
          ? null
          : AppBar(
              leading: Semantics(
                label: 'Go back to the previous step',
                button: true,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: onBack,
                ),
              ),
            ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!, style: Theme.of(context).textTheme.bodyLarge),
              ],
              const SizedBox(height: 24),
              Expanded(child: SingleChildScrollView(child: child)),
              if (primaryActionLabel != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (primaryActionEnabled && !isLoading) ? onPrimaryAction : null,
                    child: isLoading
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(primaryActionLabel!),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
