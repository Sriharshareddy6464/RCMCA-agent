import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Backend base URL shared by every screen. Mirrors `apiBase` in `main.dart`.
const rcmcaApiBase = String.fromEnvironment(
  'RCMCA_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8001',
);

/// A verification only counts when the citizen is this close to the pin.
const double verificationGeofenceMeters = 50;

/// `/api/v1/uploads/local` and `/api/v1/issues/report` accept at most 4 photos.
const int maxReportPhotos = 4;

/// Centre of the Hyderabad demo pin offered when live GPS is out of town.
const double hyderabadDemoLatitude = 17.3850;
const double hyderabadDemoLongitude = 78.4867;

/// Rigid box the live GPS fix must fall inside for the demo pin to stay hidden.
const double hyderabadMinLatitude = 17.20;
const double hyderabadMaxLatitude = 17.62;
const double hyderabadMinLongitude = 78.20;
const double hyderabadMaxLongitude = 78.68;

/// The 5-point surface scale: 1 is best, 5 is worst.
const List<_ConditionOption> _conditionOptions = [
  _ConditionOption(1, 'Clean', Color(0xff1b8a5a)),
  _ConditionOption(2, 'Good', Color(0xff4d9a4d)),
  _ConditionOption(3, 'Normal', Color(0xffb58105)),
  _ConditionOption(4, 'Bad', Color(0xffd97706)),
  _ConditionOption(5, 'Worst', Color(0xffd9342b)),
];

/// The primary-problem answer. `reportCategory` maps the citizen's choice onto
/// the backend's `hazard_category` enum when a new issue is submitted.
enum SurveyImpact {
  trafficBottleneck('Traffic Bottleneck', 'other', Icons.traffic),
  waterloggingSewage('Waterlogging / Sewage', 'waterlogging', Icons.water_drop),
  potholeCrater('Pothole / Crater', 'pothole', Icons.warning_amber),
  footpathDebris('Footpath / Debris', 'damaged_surface', Icons.construction),
  ecosystemHazard('Ecosystem Hazard', 'other', Icons.eco);

  const SurveyImpact(this.label, this.reportCategory, this.icon);

  final String label;
  final String reportCategory;
  final IconData icon;
}

/// Step 1: ten quick yes/no observations about the site.
const List<String> _presenceQuestions = [
  'Is the road damage visible right now?',
  'Is the hazard still at the map pin location?',
  'Is the surface broken, loose, or uneven?',
  'Does water collect or drain poorly here?',
  'Is the affected area wider than a dinner plate?',
  'Do vehicles slow down or swerve to avoid it?',
  'Is the footpath or roadside drain affected?',
  'Is the hazard hard to see after dark?',
  'Has the damage worsened since the last report?',
  'Would a fresh report still help the ward engineer?',
];

/// Step 2: ten five-point surface and safety ratings.
const List<String> _qualityQuestions = [
  'Overall surface quality of this stretch',
  'Ride smoothness for two-wheelers',
  'Pothole or crater severity',
  'Loose gravel or debris on the carriageway',
  'Waterlogging and drainage',
  'Road edge and shoulder condition',
  'Visibility of lane markings',
  'Night-time safety for commuters',
  'Footpath and pedestrian safety',
  'Urgency of the repair',
];

class _SurveyMcq {
  const _SurveyMcq(this.prompt, this.options);

  final String prompt;
  final List<String> options;
}

/// Step 3: ten multiple-choice impact questions. The first question drives the
/// `impact_mcq` string and the report `category`, matching the backend contract.
final List<_SurveyMcq> _impactQuestions = [
  _SurveyMcq(
    'What is the main problem at this spot?',
    [for (final impact in SurveyImpact.values) impact.label],
  ),
  _SurveyMcq('How much of the road is affected?', const [
    'One spot',
    'Part of a lane',
    'A full lane',
    'Multiple lanes',
  ]),
  _SurveyMcq('Who is most affected?', const [
    'Two-wheelers',
    'Cars',
    'Pedestrians',
    'Heavy vehicles',
  ]),
  _SurveyMcq('When is it worst?', const [
    'Peak hours',
    'After dark',
    'During rain',
    'All day',
  ]),
  _SurveyMcq('How long has it been here?', const [
    'Under a week',
    '1-4 weeks',
    '1-6 months',
    'Over 6 months',
  ]),
  _SurveyMcq('Have there been injuries or near misses?', const [
    'None seen',
    'Near misses',
    'Minor injuries',
    'Serious injuries',
  ]),
  _SurveyMcq('What happens during rain?', const [
    'Nothing notable',
    'Water pools',
    'Surface washes away',
    'Drain overflows',
  ]),
  _SurveyMcq('Is traffic diverted?', const [
    'No diversion',
    'Partial diversion',
    'Full diversion',
    'Road closed',
  ]),
  _SurveyMcq('What repair is needed?', const [
    'Patch repair',
    'Full resurfacing',
    'Drain cleaning',
    'Signage or barriers',
  ]),
  _SurveyMcq('How urgent is the repair?', const [
    'Routine',
    'Within a month',
    'Within a week',
    'Immediate',
  ]),
];

/// Result of a verification submitted to
/// `POST /api/v1/issues/{id}/verify`.
class SurveyVerificationResult {
  const SurveyVerificationResult({
    required this.stillPresent,
    this.conditionScore,
    this.impact,
    this.confidenceScore,
    this.status,
    this.severity,
    this.statusColor,
  });

  factory SurveyVerificationResult.fromJson(
    Map<String, dynamic> json, {
    required bool stillPresent,
    int? conditionScore,
    SurveyImpact? impact,
  }) {
    return SurveyVerificationResult(
      stillPresent: stillPresent,
      conditionScore: conditionScore,
      impact: impact,
      confidenceScore: _asDouble(json['confidence_score']),
      status: _asString(json['status']),
      severity: _asInt(json['severity']),
      statusColor: _asString(json['status_color']),
    );
  }

  final bool stillPresent;
  final int? conditionScore;
  final SurveyImpact? impact;
  final double? confidenceScore;
  final String? status;
  final int? severity;
  final String? statusColor;
}

/// Result of a report submitted to `POST /api/v1/issues/report`.
class ReportedIssueResult {
  const ReportedIssueResult({required this.issue, required this.deduplicated});

  factory ReportedIssueResult.fromJson(Map<String, dynamic> json) {
    final rawIssue = json['issue'];
    final issue = rawIssue is Map<String, dynamic>
        ? rawIssue
        : rawIssue is Map
            ? Map<String, dynamic>.from(rawIssue)
            : <String, dynamic>{};
    return ReportedIssueResult(
      issue: issue,
      deduplicated: json['deduplicated'] == true,
    );
  }

  final Map<String, dynamic> issue;
  final bool deduplicated;

  String get id => _asString(issue['id']) ?? '';
}

/// Reads (or creates) the same anonymous device identity used by `main.dart`.
/// The verify endpoint expects a UUID `user_id` and uses it to keep one vote per
/// citizen per issue.
Future<String> rcmcaAnonymousUserId() async {
  final preferences = await SharedPreferences.getInstance();
  final existing = preferences.getString('rcmca_anonymous_user_id');
  if (existing != null && existing.isNotEmpty) return existing;
  final id = const Uuid().v4();
  await preferences.setString('rcmca_anonymous_user_id', id);
  return id;
}

/// True when a live GPS distance is close enough to allow verification.
bool isWithinVerificationGeofence(double distanceMeters) =>
    distanceMeters <= verificationGeofenceMeters;

/// True when a coordinate falls inside the Hyderabad bounding box used to
/// decide whether to offer the demo pin.
bool isWithinHyderabad(double latitude, double longitude) =>
    latitude >= hyderabadMinLatitude &&
    latitude <= hyderabadMaxLatitude &&
    longitude >= hyderabadMinLongitude &&
    longitude <= hyderabadMaxLongitude;

/// Opens the proximity verification survey for an existing issue.
///
/// Use this from the map's 50 m geofence trigger (pass [distanceMeters]) or
/// when a citizen taps an issue pin (leave [distanceMeters] null).
Future<SurveyVerificationResult?> showProximityVerificationSheet(
  BuildContext context, {
  required String issueId,
  required String categoryLabel,
  double? distanceMeters,
  ValueChanged<SurveyVerificationResult>? onSubmitted,
}) async {
  final result = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _SurveyFlow(
      mode: _SurveyMode.verify,
      isSheet: true,
      issueId: issueId,
      categoryLabel: categoryLabel,
      distanceMeters: distanceMeters,
      onVerificationSubmitted: onSubmitted,
    ),
  );
  return result is SurveyVerificationResult ? result : null;
}

/// Opens the new-issue report survey as a bottom sheet.
///
/// Photos are uploaded to `POST /api/v1/uploads/local`, then the issue goes to
/// `POST /api/v1/issues/report`.
Future<ReportedIssueResult?> showNewIssueReportSheet(
  BuildContext context, {
  ValueChanged<ReportedIssueResult>? onSubmitted,
}) async {
  final result = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _SurveyFlow(
      mode: _SurveyMode.report,
      isSheet: true,
      onReportSubmitted: onSubmitted,
    ),
  );
  return result is ReportedIssueResult ? result : null;
}

/// Embedded version of the report survey, used as a tab body.
class NewIssueReportSheet extends StatelessWidget {
  const NewIssueReportSheet({
    super.key,
    this.isSheet = true,
    this.onSubmitted,
  });

  final bool isSheet;
  final ValueChanged<ReportedIssueResult>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return _SurveyFlow(
      mode: _SurveyMode.report,
      isSheet: isSheet,
      onReportSubmitted: onSubmitted,
    );
  }
}

/// Standalone screen for the bottom navigation Report tab.
class NewIssueReportScreen extends StatelessWidget {
  const NewIssueReportScreen({super.key, this.onSubmitted});

  final ValueChanged<ReportedIssueResult>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report Road Hazard')),
      body: SafeArea(
        child: NewIssueReportSheet(
          isSheet: false,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
}

enum _SurveyMode { verify, report }

/// Titles shown in the header of each step. Deliberately functional, with no
/// "slide" or "layer" numbering.
const List<String> _verifyTitles = [
  'Site Condition Check',
  'Surface Quality Rating',
  'Impact Assessment',
];

const List<String> _reportTitles = [
  'Site Condition Check',
  'Surface Quality Rating',
  'Impact Assessment',
  'Photo & Location Evidence',
];

/// A GPS pin captured for a report. Keeping our own value object (instead of a
/// `Position`) makes the demo pin trivial to construct.
class _LockedPin {
  const _LockedPin({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.isDemo,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final bool isDemo;
}

class _ConditionOption {
  const _ConditionOption(this.score, this.label, this.color);

  final int score;
  final String label;
  final Color color;
}

// ---------------------------------------------------------------------------
// Step-based survey flow
// ---------------------------------------------------------------------------

class _SurveyFlow extends StatefulWidget {
  const _SurveyFlow({
    required this.mode,
    required this.isSheet,
    this.issueId,
    this.categoryLabel,
    this.distanceMeters,
    this.onVerificationSubmitted,
    this.onReportSubmitted,
  });

  final _SurveyMode mode;
  final bool isSheet;
  final String? issueId;
  final String? categoryLabel;
  final double? distanceMeters;
  final ValueChanged<SurveyVerificationResult>? onVerificationSubmitted;
  final ValueChanged<ReportedIssueResult>? onReportSubmitted;

  @override
  State<_SurveyFlow> createState() => _SurveyFlowState();
}

class _SurveyFlowState extends State<_SurveyFlow> {
  final PageController _pages = PageController();
  final TextEditingController _description = TextEditingController();
  final List<XFile> _photos = [];

  List<bool?> _presence =
      List<bool?>.filled(_presenceQuestions.length, null);
  List<int?> _quality = List<int?>.filled(_qualityQuestions.length, null);
  List<int?> _impactAnswers =
      List<int?>.filled(_impactQuestions.length, null);

  int _index = 0;
  _LockedPin? _pin;
  DateTime? _lockedAt;
  bool _locating = false;
  String? _locationError;
  int _gpsToken = 0;
  bool _submitting = false;
  String? _error;

  bool get _isReport => widget.mode == _SurveyMode.report;

  int get _lastIndex => _isReport ? 3 : 2;

  List<String> get _titles => _isReport ? _reportTitles : _verifyTitles;

  bool get _outsideGeofence {
    final distance = widget.distanceMeters;
    return distance != null && !isWithinVerificationGeofence(distance);
  }

  bool get _presenceComplete => _presence.every((answer) => answer != null);

  int get _yesCount => _presence.where((answer) => answer == true).length;

  /// The backend receives one `still_present` boolean, so the survey treats the
  /// issue as present when a clear majority of the ten checks are "Yes".
  bool get _stillPresent => _yesCount >= 6;

  bool get _qualityComplete => _quality.every((answer) => answer != null);

  bool get _impactComplete =>
      _impactAnswers.every((answer) => answer != null);

  int? get _conditionScore {
    if (!_qualityComplete) return null;
    final total = _quality.fold<int>(0, (sum, score) => sum + (score ?? 0));
    final average = (total / _quality.length).round().clamp(1, 5);
    return average.toInt();
  }

  SurveyImpact? get _primaryImpact {
    final selected = _impactAnswers.isEmpty ? null : _impactAnswers.first;
    if (selected == null ||
        selected < 0 ||
        selected >= SurveyImpact.values.length) {
      return null;
    }
    return SurveyImpact.values[selected];
  }

  bool get _canSubmitVerification {
    if (_submitting || _outsideGeofence || !_presenceComplete) return false;
    if (!_stillPresent) return true;
    return _qualityComplete && _impactComplete;
  }

  bool get _canSubmitReport =>
      !_submitting &&
      _presenceComplete &&
      _stillPresent &&
      _qualityComplete &&
      _impactComplete &&
      _pin != null &&
      _description.text.trim().length >= 8;

  bool get _isLastStep => _index >= _lastIndex;

  bool get _canAdvance {
    switch (_index) {
      case 0:
        if (!_presenceComplete) return false;
        return _isReport ? _stillPresent : true;
      case 1:
        if (!_isReport && !_stillPresent) return true;
        return _qualityComplete;
      case 2:
        if (!_isReport && !_stillPresent) return true;
        return _impactComplete;
      default:
        return false;
    }
  }

  bool get _canPressPrimary {
    if (_submitting) return false;
    if (!_isLastStep) return _canAdvance;
    return _isReport ? _canSubmitReport : _canSubmitVerification;
  }

  bool get _showDemoPin {
    if (_submitting || _locating) return false;
    final pin = _pin;
    if (pin == null) return true;
    if (pin.isDemo) return false;
    return !isWithinHyderabad(pin.latitude, pin.longitude);
  }

  List<String> get _missingForReport {
    final missing = <String>[];
    if (!_presenceComplete) {
      missing.add('answer all 10 condition checks');
    } else if (!_stillPresent) {
      missing.add('answer Yes to at least 6 checks (a new report must be present)');
    }
    if (!_qualityComplete) missing.add('rate all 10 surface-quality items');
    if (!_impactComplete) missing.add('choose an option in all 10 impact questions');
    if (_pin == null) missing.add('lock the GPS pin or use the demo pin');
    if (_description.text.trim().length < 8) {
      missing.add('write at least 8 characters of description');
    }
    return missing;
  }

  String? get _footerHint {
    if (_submitting) return null;
    if (_error != null && _isLastStep) return null;
    switch (_index) {
      case 0:
        if (!_presenceComplete) {
          return 'Answer all 10 condition checks to continue.';
        }
        if (_isReport && !_stillPresent) {
          return 'A new report needs at least 6 Yes answers. This site looks resolved.';
        }
        return null;
      case 1:
        if (!_isReport && !_stillPresent) {
          return 'Ratings are optional because you marked the issue as fixed.';
        }
        if (!_qualityComplete) return 'Rate all 10 items to continue.';
        return null;
      case 2:
        if (_isReport) {
          if (!_impactComplete) {
            return 'Choose an option in every impact question to continue.';
          }
          return null;
        }
        if (!_stillPresent) return 'Submit to record that this issue is fixed.';
        if (!_qualityComplete || !_impactComplete) {
          return 'Answer every rating and impact question to submit.';
        }
        return null;
      default:
        final missing = _missingForReport;
        if (missing.isEmpty) return null;
        final shown = missing.take(3).join(' · ');
        final extra =
            missing.length > 3 ? ' (+${missing.length - 3} more)' : '';
        return 'To enable submit: $shown$extra.';
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isReport) _lockGps();
  }

  @override
  void dispose() {
    _pages.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _lockGps({bool demo = false}) async {
    if (demo) {
      setState(() {
        _gpsToken++;
        _locating = false;
        _locationError = null;
        _pin = const _LockedPin(
          latitude: hyderabadDemoLatitude,
          longitude: hyderabadDemoLongitude,
          accuracy: 5,
          isDemo: true,
        );
        _lockedAt = DateTime.now();
      });
      return;
    }
    final token = ++_gpsToken;
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final position = await _resolvePosition();
      if (!mounted || token != _gpsToken) return;
      setState(() {
        _pin = _LockedPin(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
          isDemo: false,
        );
        _lockedAt = DateTime.now();
        _locating = false;
      });
    } catch (error) {
      if (!mounted || token != _gpsToken) return;
      setState(() {
        _locationError = _cleanError(error);
        _locating = false;
      });
    }
  }

  Future<void> _addPhoto() async {
    if (_photos.length >= maxReportPhotos) {
      _showMessage('You can attach up to $maxReportPhotos photos.');
      return;
    }
    final photo = await Navigator.of(context).push<XFile>(
      MaterialPageRoute(
        builder: (_) => const _SurveyCameraPage(),
        fullscreenDialog: true,
      ),
    );
    if (photo == null || !mounted) return;
    setState(() => _photos.add(photo));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _next() async {
    if (!_canAdvance || _isLastStep) return;
    await _pages.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _back() async {
    if (_index == 0 || _submitting) return;
    await _pages.previousPage(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _onPrimary() async {
    if (!_isLastStep) {
      await _next();
      return;
    }
    if (_isReport) {
      await _submitReport();
    } else {
      await _submitVerification();
    }
  }

  Future<void> _submitVerification() async {
    if (!_canSubmitVerification) return;
    final stillPresent = _stillPresent;
    final condition = stillPresent ? _conditionScore : null;
    final impact = stillPresent ? _primaryImpact : null;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final userId = await rcmcaAnonymousUserId();
      final payload = <String, dynamic>{
        'user_id': userId,
        'still_present': stillPresent,
      };
      if (stillPresent) {
        payload['condition_score'] = condition;
        payload['impact_mcq'] = impact!.label;
      }
      final response = await http
          .post(
            Uri.parse(
              '$rcmcaApiBase/api/v1/issues/'
              '${Uri.encodeComponent(widget.issueId ?? '')}/verify',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception(_friendlyApiError(response.statusCode, response.body));
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final result = SurveyVerificationResult.fromJson(
        json,
        stillPresent: stillPresent,
        conditionScore: condition,
        impact: impact,
      );
      if (!mounted) return;
      widget.onVerificationSubmitted?.call(result);
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _cleanError(error);
        _submitting = false;
      });
    }
  }

  Future<void> _submitReport() async {
    if (!_canSubmitReport) return;
    final pin = _pin;
    final condition = _conditionScore;
    final impact = _primaryImpact;
    final description = _description.text.trim();
    if (pin == null || condition == null || impact == null) {
      setState(() => _error = 'Complete every step before submitting.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final imageUrls = await _uploadPhotos();
      final response = await http
          .post(
            Uri.parse('$rcmcaApiBase/api/v1/issues/report'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'category': impact.reportCategory,
              'description': description,
              'latitude': pin.latitude,
              'longitude': pin.longitude,
              'severity': condition,
              'still_present': true,
              'condition_score': condition,
              'impact_mcq': impact.label,
              'image_urls': imageUrls,
              'evidence_image_url': imageUrls.isEmpty ? null : imageUrls.first,
              'capture_accuracy_m': pin.accuracy,
              'captured_at': DateTime.now().toUtc().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 201) {
        throw Exception(_friendlyApiError(response.statusCode, response.body));
      }
      final result = ReportedIssueResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      if (!mounted) return;
      widget.onReportSubmitted?.call(result);
      if (widget.isSheet) {
        Navigator.of(context).pop(result);
        return;
      }
      setState(() {
        _submitting = false;
        _photos.clear();
        _description.clear();
        _presence = List<bool?>.filled(_presenceQuestions.length, null);
        _quality = List<int?>.filled(_qualityQuestions.length, null);
        _impactAnswers = List<int?>.filled(_impactQuestions.length, null);
      });
      _pages.jumpToPage(0);
      _showMessage('Report submitted successfully! Returning to map…');
      _lockGps();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _cleanError(error);
        _submitting = false;
      });
    }
  }

  Future<List<String>> _uploadPhotos() async {
    if (_photos.isEmpty) return const [];
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$rcmcaApiBase/api/v1/uploads/local'),
    );
    for (final photo in _photos) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'files',
          photo.path,
          contentType: _mediaTypeFor(photo.path),
        ),
      );
    }
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception(_friendlyApiError(streamed.statusCode, body));
    }
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final urls = payload['image_urls'];
    if (urls is! List) return const [];
    return [
      for (final url in urls)
        if (url is String && url.trim().isNotEmpty) url,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);

    final content = Column(
      children: [
        _buildHeader(theme, scheme),
        if (!_isReport && _outsideGeofence)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: _Notice(
              icon: Icons.gps_off,
              color: scheme.error,
              text:
                  'You are ${widget.distanceMeters!.toStringAsFixed(0)} m from the pin. '
                  'Move within ${verificationGeofenceMeters.toStringAsFixed(0)} m so the '
                  'verification matches the actual road condition.',
            ),
          ),
        Expanded(
          child: PageView(
            controller: _pages,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (index) => setState(() => _index = index),
            children: [
              _buildPresenceStep(theme, scheme),
              _buildQualityStep(theme, scheme),
              _buildImpactStep(theme, scheme),
              if (_isReport) _buildEvidenceStep(theme, scheme),
            ],
          ),
        ),
        _buildFooter(theme, scheme),
      ],
    );

    if (!widget.isSheet) return content;

    final maxHeight = media.size.height * 0.94;
    final height = (maxHeight - media.viewInsets.bottom)
        .clamp(220.0, maxHeight)
        .toDouble();
    return PopScope(
      canPop: !_submitting,
      child: SizedBox(height: height, child: content),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _titles[_index],
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              if (widget.isSheet)
                IconButton(
                  onPressed:
                      _submitting ? null : () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
            ],
          ),
          if (!_isReport) ...[
            Text(
              '${widget.categoryLabel ?? 'Road issue'} · '
              'issue #${_shortId(widget.issueId ?? '')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            _DistanceChip(distanceMeters: widget.distanceMeters),
          ],
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (_index + 1) / _titles.length,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme scheme) {
    final hint = _footerHint;
    final label = _primaryLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hint != null) ...[
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_error != null) ...[
            _Notice(
              icon: Icons.error_outline,
              color: scheme.error,
              text: _error!,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (_index > 0) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting ? null : _back,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: _canPressPrimary ? _onPrimary : null,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_primaryIcon),
                  label: Text(label),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData get _primaryIcon {
    if (!_isLastStep) return Icons.arrow_forward;
    return _isReport ? Icons.camera_alt : Icons.verified_outlined;
  }

  String get _primaryLabel {
    if (_submitting) {
      if (!_isReport) return 'Submitting…';
      if (_photos.isEmpty) return 'Submitting report…';
      return 'Uploading ${_photos.length} '
          'photo${_photos.length == 1 ? '' : 's'}…';
    }
    if (!_isLastStep) return 'Next';
    return _isReport ? 'Submit report' : 'Submit Verification';
  }

  Widget _buildPresenceStep(ThemeData theme, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
      children: [
        _IntroLine(
          text: 'Look at the spot at the pin, then answer each check with '
              'the green tick or the red cross.',
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _presenceQuestions.length; i++)
          _YesNoRow(
            question: '${i + 1}. ${_presenceQuestions[i]}',
            value: _presence[i],
            onChanged: _submitting
                ? null
                : (answer) => setState(() => _presence[i] = answer),
          ),
      ],
    );
  }

  Widget _buildQualityStep(ThemeData theme, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
      children: [
        _IntroLine(
          text: 'Tap one pill per row, from Clean (1) to Worst (5). The '
              'average becomes the issue severity.',
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _qualityQuestions.length; i++)
          _QualityRow(
            question: '${i + 1}. ${_qualityQuestions[i]}',
            value: _quality[i],
            onChanged: _submitting
                ? null
                : (score) => setState(() => _quality[i] = score),
          ),
      ],
    );
  }

  Widget _buildImpactStep(ThemeData theme, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
      children: [
        _IntroLine(
          text: 'Pick the one option per question that best matches what '
              'commuters experience here.',
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _impactQuestions.length; i++)
          _McqCard(
            question: '${i + 1}. ${_impactQuestions[i].prompt}',
            options: _impactQuestions[i].options,
            value: _impactAnswers[i],
            onChanged: _submitting
                ? null
                : (choice) => setState(() => _impactAnswers[i] = choice),
          ),
      ],
    );
  }

  Widget _buildEvidenceStep(ThemeData theme, ColorScheme scheme) {
    final impact = _primaryImpact;
    final condition = _conditionScore;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
      children: [
        _IntroLine(
          text: 'Add photos if you can, confirm the pin, and describe what '
              'you saw. Photos and the pin help the ward engineer find it.',
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _SummaryPill(
                icon: Icons.rule,
                label: _stillPresent ? 'Still present' : 'Marked fixed',
                color: _stillPresent
                    ? const Color(0xff1b8a5a)
                    : scheme.error,
              ),
              if (condition != null)
                _SummaryPill(
                  icon: Icons.speed,
                  label: 'Condition $condition/5',
                  color: _conditionOptions[condition - 1].color,
                ),
              if (impact != null)
                _SummaryPill(
                  icon: Icons.report_problem_outlined,
                  label: impact.label,
                  color: scheme.primary,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                'Photos',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${_photos.length}/$maxReportPhotos · optional',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount:
                _photos.length + (_photos.length < maxReportPhotos ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index >= _photos.length) {
                return _AddPhotoTile(
                  enabled: !_submitting,
                  onTap: _addPhoto,
                );
              }
              return _PhotoThumb(
                photo: _photos[index],
                onRemove: _submitting
                    ? null
                    : () => setState(() => _photos.removeAt(index)),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        _GpsPinCard(
          locating: _locating,
          pin: _pin,
          lockedAt: _lockedAt,
          error: _locationError,
          onRetry: _submitting ? null : _lockGps,
        ),
        if (_showDemoPin) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _lockGps(demo: true),
            icon: const Icon(Icons.pin_drop_outlined),
            label: const Text('Use Hyderabad Demo Pin'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _pin == null
                ? 'No live fix yet. The demo pin at '
                    '${hyderabadDemoLatitude.toStringAsFixed(4)}, '
                    '${hyderabadDemoLongitude.toStringAsFixed(4)} lets you '
                    'finish a test report.'
                : 'Live GPS is at ${_pin!.latitude.toStringAsFixed(4)}, '
                    '${_pin!.longitude.toStringAsFixed(4)}, outside Hyderabad '
                    '(17.20-17.62, 78.20-78.68). The demo pin at '
                    '${hyderabadDemoLatitude.toStringAsFixed(4)}, '
                    '${hyderabadDemoLongitude.toStringAsFixed(4)} is used '
                    'instead.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 14),
        TextField(
          controller: _description,
          enabled: !_submitting,
          minLines: 2,
          maxLines: 4,
          maxLength: 240,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Short description',
            hintText:
                'e.g. Deep pothole across the left lane near the bus stop',
            helperText: 'At least 8 characters. Mention the lane and landmark.',
            counterText: '',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The pin is taken from your device or the demo location and cannot '
          'be dragged. Photos are stored on the RCMCA server for ward engineers.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step widgets
// ---------------------------------------------------------------------------

class _IntroLine extends StatelessWidget {
  const _IntroLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 12.5, height: 1.35, color: color),
    );
  }
}

class _YesNoRow extends StatelessWidget {
  const _YesNoRow({
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final String question;
  final bool? value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xff1b8a5a);
    final red = scheme.error;
    final selectedColor = value == true ? green : red;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: value == null
            ? scheme.surface
            : selectedColor.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value == null ? scheme.outlineVariant : selectedColor,
          width: value == null ? 1 : 1.4,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              question,
              style: const TextStyle(fontSize: 13, height: 1.3),
            ),
          ),
          const SizedBox(width: 8),
          _ToggleIcon(
            icon: Icons.check,
            tooltip: 'Yes',
            color: green,
            selected: value == true,
            onPressed: onChanged == null ? null : () => onChanged!(true),
          ),
          const SizedBox(width: 6),
          _ToggleIcon(
            icon: Icons.close,
            tooltip: 'No',
            color: red,
            selected: value == false,
            onPressed: onChanged == null ? null : () => onChanged!(false),
          ),
        ],
      ),
    );
  }
}

class _ToggleIcon extends StatelessWidget {
  const _ToggleIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: color.withValues(alpha: selected ? 1 : 0.45),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Icon(
              icon,
              size: 20,
              color: selected ? Colors.white : color,
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final String question;
  final int? value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value == null
              ? scheme.outlineVariant
              : _conditionOptions[value! - 1].color.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          _FivePillBar(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A single horizontal 5-pill bar. Every pill is inside an [Expanded] and its
/// label is wrapped in a scale-down [FittedBox], so the bar always stays on one
/// line and never wraps.
class _FivePillBar extends StatelessWidget {
  const _FivePillBar({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _conditionOptions.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: _ScalePill(
              option: _conditionOptions[i],
              selected: value == _conditionOptions[i].score,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(_conditionOptions[i].score),
            ),
          ),
        ],
      ],
    );
  }
}

class _ScalePill extends StatelessWidget {
  const _ScalePill({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _ConditionOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = selected
        ? Colors.white
        : Color.lerp(option.color, Colors.black, 0.25)!;
    return Semantics(
      button: true,
      selected: selected,
      label: '${option.label}, ${option.score} of 5',
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          height: 38,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: selected
                ? option.color
                : option.color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: option.color.withValues(alpha: selected ? 1 : 0.45),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              option.label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _McqCard extends StatelessWidget {
  const _McqCard({
    required this.question,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String question;
  final List<String> options;
  final int? value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value == null
              ? scheme.outlineVariant
              : scheme.primary.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < options.length; i++)
                ChoiceChip(
                  label: Text(options[i]),
                  selected: value == i,
                  showCheckmark: false,
                  onSelected:
                      onChanged == null ? null : (_) => onChanged!(i),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: BorderSide(
                    color: value == i
                        ? scheme.primary
                        : scheme.outlineVariant,
                  ),
                  selectedColor:
                      scheme.primaryContainer.withValues(alpha: 0.7),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        value == i ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _DistanceChip extends StatelessWidget {
  const _DistanceChip({required this.distanceMeters});

  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final distance = distanceMeters;
    final inside =
        distance == null || isWithinVerificationGeofence(distance);
    final color = inside ? const Color(0xff1b8a5a) : scheme.error;
    final label = distance == null
        ? 'Pin-tap verification'
        : inside
            ? '${distance.toStringAsFixed(0)} m away · inside 50 m geofence'
            : '${distance.toStringAsFixed(0)} m away · outside 50 m geofence';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(inside ? Icons.gps_fixed : Icons.gps_off,
                size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.35, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _GpsPinCard extends StatelessWidget {
  const _GpsPinCard({
    required this.locating,
    required this.pin,
    required this.lockedAt,
    required this.error,
    required this.onRetry,
  });

  final bool locating;
  final _LockedPin? pin;
  final DateTime? lockedAt;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locked = pin;
    final hasError = error != null && !locating;
    final color = hasError
        ? scheme.error
        : locked != null
            ? const Color(0xff1b8a5a)
            : scheme.primary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            locked != null ? Icons.gps_fixed : Icons.gps_not_fixed,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Auto-locked GPS pin',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    if (locked != null)
                      Icon(Icons.lock, size: 13, color: scheme.onSurfaceVariant),
                    if (locked != null && locked.isDemo) ...[
                      const SizedBox(width: 6),
                      Text(
                        'demo',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                if (locating)
                  Text(
                    'Locking your location…',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  )
                else if (locked != null)
                  Text(
                    '${locked.latitude.toStringAsFixed(6)}, '
                    '${locked.longitude.toStringAsFixed(6)}\n'
                    'Accuracy ±${locked.accuracy.toStringAsFixed(0)} m'
                    '${lockedAt == null ? '' : ' · locked ${_clock(lockedAt!)}'}',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                  )
                else
                  Text(
                    error ?? 'Location is not available.',
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
              ],
            ),
          ),
          if (locating)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry GPS lock',
            ),
        ],
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_a_photo, color: scheme.primary),
              const SizedBox(height: 4),
              Text(
                'Add',
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.photo, required this.onRemove});

  final XFile photo;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(photo.path),
            width: 84,
            height: 84,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 84,
              height: 84,
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _SurveyCameraPage extends StatefulWidget {
  const _SurveyCameraPage();

  @override
  State<_SurveyCameraPage> createState() => _SurveyCameraPageState();
}

class _SurveyCameraPageState extends State<_SurveyCameraPage> {
  CameraController? _controller;
  String? _error;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No camera is available on this device.');
      }
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Camera unavailable: ${_cleanError(error)}');
      }
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final photo = await controller.takePicture();
      if (mounted) Navigator.of(context).pop(photo);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not capture photo: ${_cleanError(error)}';
          _capturing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Capture evidence')),
      body: Column(
        children: [
          Expanded(
            child: controller != null && controller.value.isInitialized
                ? Center(child: CameraPreview(controller))
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error ?? 'Opening camera…',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _capturing ? null : _capture,
                  icon: _capturing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt),
                  label: Text(_capturing ? 'Capturing…' : 'Capture photo'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Position> _resolvePosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Turn on device location to lock the report pin.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw Exception('Location permission is needed to lock the report pin.');
  }
  return Geolocator.getCurrentPosition(
    locationSettings: LocationSettings(
      accuracy: LocationAccuracy.best,
      timeLimit: const Duration(seconds: 15),
    ),
  );
}

MediaType _mediaTypeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return MediaType('image', 'png');
  if (lower.endsWith('.webp')) return MediaType('image', 'webp');
  return MediaType('image', 'jpeg');
}

String _friendlyApiError(int status, String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] is String) {
          return first['msg'] as String;
        }
      }
    }
  } catch (_) {
    // Fall through to the generic message.
  }
  return 'Request failed (HTTP $status).';
}

String _cleanError(Object error) =>
    error.toString().replaceFirst('Exception: ', '');

String _clock(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

String _two(int value) => value.toString().padLeft(2, '0');

String _shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

String? _asString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

int? _asInt(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '');

double? _asDouble(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(value?.toString() ?? '');
