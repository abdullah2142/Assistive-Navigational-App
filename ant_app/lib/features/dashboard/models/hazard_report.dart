/// Top-level category for a crowdsourced report — mirrors the three
/// glassmorphism cards in the Crowdsource Reporting Hub. Display labels
/// live in `core/localization/dashboard_strings.dart`'s `Dashboard` class,
/// not here — this enum is just the stable identity stored in Firestore.
enum HazardCategory { crime, roadHazard, accessibilityBlock }

/// A single pin a user drops on the crowdsourcing map.
///
/// [subCategory] stores a stable English key (e.g. `'mugging'`, or the
/// sentinel `Dashboard.isOtherSubCategoryKey` matches) — never the displayed
/// label — so a report's data doesn't depend on which language the reporter
/// had selected. See `Dashboard.hazardSubCategoryKeys`/`hazardSubCategoryLabel`.
///
/// This is Module 2's data contract only: it persists the raw report.
/// Anti-spam thresholds (1 report = Yellow Flag, 3 in 24h = Red Flag),
/// AI summarization of the free-text description, and decay cron jobs are
/// `05_module_plan_crowdsourcing.md` — Module 5's job, not this one's.
class HazardReport {
  const HazardReport({
    this.id,
    required this.reporterUid,
    required this.category,
    required this.subCategory,
    this.description = '',
    this.lat,
    this.lng,
    this.createdAt,
  });

  final String? id;
  final String reporterUid;
  final HazardCategory category;
  final String subCategory;
  final String description;
  final double? lat;
  final double? lng;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'reporterUid': reporterUid,
        'category': category.name,
        'subCategory': subCategory,
        'description': description,
        'lat': lat,
        'lng': lng,
      };
}
