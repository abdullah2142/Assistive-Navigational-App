import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/utils/ai_text_summarizer.dart';
import '../models/hazard_report.dart';
import '../providers/dashboard_providers.dart';

/// The Crowdsource Reporting Hub — a glassmorphism overlay with three
/// drill-down categories, per UI module plan Step 4.2. Any category's
/// sub-option list ends in an "Other" entry (see
/// `Dashboard.isOtherSubCategoryKey`), which opens a free-text (or
/// dictated, once Module 3 lands) description that gets run through a
/// stub AI summary before submission.
class CrowdsourceReportingHub extends ConsumerStatefulWidget {
  const CrowdsourceReportingHub({super.key, required this.reporterUid, required this.language});

  final String reporterUid;
  final AppLanguage language;

  static Future<void> show(BuildContext context, {required String reporterUid, required AppLanguage language}) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        pageBuilder: (_, _, _) => CrowdsourceReportingHub(reporterUid: reporterUid, language: language),
      ),
    );
  }

  @override
  ConsumerState<CrowdsourceReportingHub> createState() => _CrowdsourceReportingHubState();
}

class _CrowdsourceReportingHubState extends ConsumerState<CrowdsourceReportingHub> {
  HazardCategory? _category;
  String? _subCategoryKey;
  final _descriptionController = TextEditingController();
  bool _submitting = false;

  late final Dashboard _d = Dashboard.of(widget.language);

  bool get _isOther => _subCategoryKey != null && _d.isOtherSubCategoryKey(_subCategoryKey!);

  @override
  void initState() {
    super.initState();
    _descriptionController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final rawDescription = _descriptionController.text.trim();
    if (_isOther && rawDescription.isEmpty) return;

    setState(() => _submitting = true);
    double? lat;
    double? lng;
    try {
      final position = await Geolocator.getCurrentPosition();
      lat = position.latitude;
      lng = position.longitude;
    } catch (_) {
      // Location is best-effort — a report without coordinates is still useful.
    }
    try {
      await ref.read(hazardReportServiceProvider).submitReport(HazardReport(
            reporterUid: widget.reporterUid,
            category: _category!,
            subCategory: _subCategoryKey!,
            description: _isOther ? summarizeText(rawDescription) : rawDescription,
            lat: lat,
            lng: lng,
          ));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_d.crowdsourceSubmitSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_d.crowdsourceSubmitError('$e'))),
      );
    }
  }

  void _promptVoiceUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_d.crowdsourceVoiceUnavailable)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(color: Colors.black.withValues(alpha: 0.35)),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                ),
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_category != null)
                          Semantics(
                            button: true,
                            label: _d.crowdsourceBackSemantics,
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_rounded),
                              onPressed: () => setState(() {
                                if (_subCategoryKey != null) {
                                  _subCategoryKey = null;
                                  _descriptionController.clear();
                                } else {
                                  _category = null;
                                }
                              }),
                            ),
                          ),
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(_titleFor(), style: theme.textTheme.headlineSmall),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: _d.crowdsourceCloseSemantics,
                          child: IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: _category == null
                            ? _buildCategoryGrid(theme)
                            : _subCategoryKey == null
                                ? _buildSubCategoryList(theme)
                                : _buildDescriptionForm(theme),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _titleFor() {
    if (_isOther) return _d.crowdsourceDescribeItTitle;
    if (_subCategoryKey != null) return _d.hazardSubCategoryLabel(_subCategoryKey!);
    if (_category != null) return _d.hazardCategoryLabel(_category!);
    return _d.crowdsourceTitle;
  }

  Widget _buildCategoryGrid(ThemeData theme) {
    const icons = {
      HazardCategory.crime: Icons.local_police_rounded,
      HazardCategory.roadHazard: Icons.construction_rounded,
      HazardCategory.accessibilityBlock: Icons.accessible_forward_rounded,
    };
    return Column(
      children: HazardCategory.values.map((category) {
        final label = _d.hazardCategoryLabel(category);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            button: true,
            label: label,
            child: Material(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => _category = category),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                  child: Row(
                    children: [
                      Icon(icons[category], color: theme.colorScheme.primary, size: 32),
                      const SizedBox(width: 16),
                      Text(label, style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSubCategoryList(ThemeData theme) {
    final keys = _d.hazardSubCategoryKeys(_category!);
    return Column(
      children: keys.map((key) {
        final isOtherOption = _d.isOtherSubCategoryKey(key);
        final label = _d.hazardSubCategoryLabel(key);
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            button: true,
            label: label,
            child: Material(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() => _subCategoryKey = key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (isOtherOption) ...[
                        Icon(Icons.edit_note_rounded, size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          label,
                          style: isOtherOption
                              ? theme.textTheme.titleSmall?.copyWith(fontStyle: FontStyle.italic)
                              : theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDescriptionForm(ThemeData theme) {
    final rawText = _descriptionController.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isOther ? _d.crowdsourceDescribeHint : _d.crowdsourceOptionalDetails,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                textField: true,
                label: _d.crowdsourceDescriptionFieldSemantics,
                child: TextField(
                  controller: _descriptionController,
                  maxLines: 3,
                  decoration: InputDecoration(hintText: _d.crowdsourceDescriptionHint),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: _d.crowdsourceSpeakSemantics,
              hint: _d.chatSpeakHint,
              child: Material(
                color: theme.colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _promptVoiceUnavailable,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.mic_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_isOther && rawText.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Semantics(
              liveRegion: true,
              label: '${_d.crowdsourceAiSummaryLabel}: ${summarizeText(rawText)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        _d.crowdsourceAiSummaryLabel,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(summarizeText(rawText), style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitting || (_isOther && rawText.isEmpty) ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Text(_d.crowdsourceSubmitButton),
          ),
        ),
      ],
    );
  }
}
