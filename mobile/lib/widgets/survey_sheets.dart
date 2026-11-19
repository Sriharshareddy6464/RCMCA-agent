import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Backend base URL shared by every screen. Mirrors `apiBase` in `main.dart`.
const rcmcaApiBase = String.fromEnvironment(
  'RCMCA_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8001',
);

/// A verification only counts when the citizen is this close to the pin.
const double verificationGeofenceMeters = 50;

/// `/api/v1/uploads/local` and `/api/v1/issues/report` accept at most 4 photos.
const int maxReportPhotos = 4;

/// Layer 2 of the road survey: the 5-point condition scale.
const List<_ConditionOption> _conditionOptions = [
  _ConditionOption(1, 'Very Good', Color(0xff1b8a5a)),
  _ConditionOption(2, 'Good', Color(0xff4d9a4d)),
  _ConditionOption(3, 'Normal', Color(0xffb58105)),
  _ConditionOption(4, 'Bad', Color(0xffd97706)),
  _ConditionOption(5, 'Worst', Color(0xffd9342b)),
];

/// Layer 3 of the road survey. `reportCategory` maps the citizen's answer onto
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

/// Result of a 3-layer verification submitted to
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

/// Result of a 4-layer report submitted to `POST /api/v1/issues/report`.
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

/// Opens the 3-layer proximity verification sheet.
///
/// Use this from the map's 50 m geofence trigger (pass [distanceMeters]) or
/// when a citizen taps an issue pin (leave [distanceMeters] null).
Future<SurveyVerificationResult?> showProximityVerificationSheet(
  BuildContext context, {
  required String issueId,
  required String categoryLabel,
  double? distanceMeters,
  ValueChanged<SurveyVerificationResult>? onSubmitted,
}) {
  return showModalBottomSheet<SurveyVerificationResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ProximityVerificationSheet(
      issueId: issueId,
      categoryLabel: categoryLabel,
      distanceMeters: distanceMeters,
      onSubmitted: onSubmitted,
    ),
  );
}

/// Opens the 4-layer new-issue report sheet.
///
/// Layers 1-3 mirror the verification survey, Layer 4 adds up to four photos,
/// an auto-locked GPS pin, and a short description. Photos are uploaded to
/// `POST /api/v1/uploads/local`, then the issue goes to
/// `POST /api/v1/issues/report`.
Future<ReportedIssueResult?> showNewIssueReportSheet(BuildContext context) {
  return showModalBottomSheet<ReportedIssueResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _NewIssueReportSheet(),
  );
}

class _ConditionOption {
  const _ConditionOption(this.score, this.label, this.color);

  final int score;
  final String label;
  final Color color;
}

// ---------------------------------------------------------------------------
// 3-layer verification sheet
// ---------------------------------------------------------------------------

class _ProximityVerificationSheet extends StatefulWidget {
  const _ProximityVerificationSheet({
    required this.issueId,
    required this.categoryLabel,
    required this.distanceMeters,
    required this.onSubmitted,
  });

  final String issueId;
  final String categoryLabel;
  final double? distanceMeters;
  final ValueChanged<SurveyVerificationResult>? onSubmitted;

  @override
  State<_ProximityVerificationSheet> createState() =>
      _ProximityVerificationSheetState();
}

class _ProximityVerificationSheetState
    extends State<_ProximityVerificationSheet> {
  bool? _stillPresent;
  int? _conditionScore;
  SurveyImpact? _impact;
  bool _submitting = false;
  String? _error;

  bool get _outsideGeofence {
    final distance = widget.distanceMeters;
    return distance != null && !isWithinVerificationGeofence(distance);
  }

  bool get _canSubmit {
    if (_submitting || _outsideGeofence || _stillPresent == null) return false;
    if (_stillPresent == true) {
      return _conditionScore != null && _impact != null;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final userId = await rcmcaAnonymousUserId();
      final payload = <String, dynamic>{
        'user_id': userId,
        'still_present': _stillPresent,
      };
      if (_stillPresent == true) {
        payload['condition_score'] = _conditionScore;
        payload['impact_mcq'] = _impact!.label;
      }
      final response = await http
          .post(
            Uri.parse(
              '$rcmcaApiBase/api/v1/issues/${Uri.encodeComponent(widget.issueId)}/verify',
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
        stillPresent: _stillPresent!,
        conditionScore: _stillPresent == true ? _conditionScore : null,
        impact: _stillPresent == true ? _impact : null,
      );
      if (!mounted) return;
      widget.onSubmitted?.call(result);
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _cleanError(error);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final layersDisabled = _stillPresent != true;

    return PopScope(
      canPop: !_submitting,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            18,
            0,
            18,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Road condition check',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.categoryLabel} · issue #${_shortId(widget.issueId)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _DistanceChip(distanceMeters: widget.distanceMeters),
              if (_outsideGeofence) ...[
                const SizedBox(height: 10),
                _Notice(
                  icon: Icons.gps_off,
                  color: scheme.error,
                  text:
                      'You are ${widget.distanceMeters!.toStringAsFixed(0)} m from the pin. '
                      'Move within ${verificationGeofenceMeters.toStringAsFixed(0)} m so the '
                      'verification matches the actual road condition.',
                ),
              ],
              const SizedBox(height: 16),
              _SurveyStep(
                step: 1,
                title: 'Layer 1 · Presence',
                subtitle: 'Is this road issue still present?',
                complete: _stillPresent != null,
                child: _BooleanSelector(
                  value: _stillPresent,
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() {
                            _stillPresent = value;
                            if (value == false) {
                              _conditionScore = null;
                              _impact = null;
                            }
                          }),
                ),
              ),
              _SurveyStep(
                step: 2,
                title: 'Layer 2 · Condition',
                subtitle: 'Rate the road surface from 1 (very good) to 5 (worst).',
                complete: _conditionScore != null,
                enabled: !layersDisabled,
                child: _ConditionSelector(
                  value: _conditionScore,
                  onChanged: layersDisabled || _submitting
                      ? null
                      : (score) => setState(() => _conditionScore = score),
                ),
              ),
              _SurveyStep(
                step: 3,
                title: 'Layer 3 · Impact',
                subtitle: 'What is the main problem at this spot?',
                complete: _impact != null,
                enabled: !layersDisabled,
                child: _ImpactSelector(
                  value: _impact,
                  onChanged: layersDisabled || _submitting
                      ? null
                      : (impact) => setState(() => _impact = impact),
                ),
              ),
              if (_stillPresent == false)
                _Notice(
                  icon: Icons.check_circle_outline,
                  color: const Color(0xff1b8a5a),
                  text:
                      'Thanks for checking. Reporting that the issue is gone marks it '
                      'as fixed for the community, so layers 2 and 3 are skipped.',
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                _Notice(icon: Icons.error_outline, color: scheme.error, text: _error!),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _canSubmit ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _stillPresent == false
                            ? Icons.check_circle_outline
                            : Icons.verified_outlined,
                      ),
                label: Text(
                  _submitting
                      ? 'Submitting…'
                      : _stillPresent == false
                          ? 'Submit · issue is fixed'
                          : 'Submit verification',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Your anonymous device ID keeps one vote per issue. Layer 2 is stored as '
                'the issue severity.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4-layer new issue report sheet
// ---------------------------------------------------------------------------

class _NewIssueReportSheet extends StatefulWidget {
  const _NewIssueReportSheet();

  @override
  State<_NewIssueReportSheet> createState() => _NewIssueReportSheetState();
}

class _NewIssueReportSheetState extends State<_NewIssueReportSheet> {
  final TextEditingController _description = TextEditingController();
  final List<XFile> _photos = [];

  bool? _stillPresent;
  int? _conditionScore;
  SurveyImpact? _impact;
  Position? _position;
  DateTime? _lockedAt;
  bool _locating = true;
  String? _locationError;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lockGps();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_submitting &&
      !_locating &&
      _position != null &&
      _stillPresent == true &&
      _conditionScore != null &&
      _impact != null &&
      _description.text.trim().length >= 8;

  Future<void> _lockGps() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final position = await _resolvePosition();
      if (!mounted) return;
      setState(() {
        _position = position;
        _lockedAt = DateTime.now();
        _locating = false;
      });
    } catch (error) {
      if (!mounted) return;
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

  Future<void> _submit() async {
    final position = _position;
    final impact = _impact;
    final condition = _conditionScore;
    if (position == null || impact == null || condition == null) {
      setState(() => _error = 'Complete every layer before submitting.');
      return;
    }
    if (_stillPresent != true) {
      setState(() => _error = 'A new report must describe an issue that is still present.');
      return;
    }
    final description = _description.text.trim();
    if (description.length < 8) {
      setState(() => _error = 'Add a short description of at least 8 characters.');
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
              'latitude': position.latitude,
              'longitude': position.longitude,
              'severity': condition,
              'still_present': true,
              'condition_score': condition,
              'impact_mcq': impact.label,
              'image_urls': imageUrls,
              'evidence_image_url': imageUrls.isEmpty ? null : imageUrls.first,
              'capture_accuracy_m': position.accuracy,
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
      Navigator.of(context).pop(result);
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
    final layersDisabled = _stillPresent != true;
    final position = _position;

    return PopScope(
      canPop: !_submitting,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            18,
            0,
            18,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Report a new road issue',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '4 layers · about 30 seconds · GPS pin locks automatically',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed:
                        _submitting ? null : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SurveyStep(
                step: 1,
                title: 'Layer 1 · Presence',
                subtitle: 'Is this road issue still present?',
                complete: _stillPresent != null,
                child: _BooleanSelector(
                  value: _stillPresent,
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() {
                            _stillPresent = value;
                            if (value == false) {
                              _conditionScore = null;
                              _impact = null;
                            }
                          }),
                ),
              ),
              _SurveyStep(
                step: 2,
                title: 'Layer 2 · Condition',
                subtitle: 'Rate the road surface from 1 (very good) to 5 (worst).',
                complete: _conditionScore != null,
                enabled: !layersDisabled,
                child: _ConditionSelector(
                  value: _conditionScore,
                  onChanged: layersDisabled || _submitting
                      ? null
                      : (score) => setState(() => _conditionScore = score),
                ),
              ),
              _SurveyStep(
                step: 3,
                title: 'Layer 3 · Impact',
                subtitle: 'What is the main problem at this spot?',
                complete: _impact != null,
                enabled: !layersDisabled,
                child: _ImpactSelector(
                  value: _impact,
                  onChanged: layersDisabled || _submitting
                      ? null
                      : (impact) => setState(() => _impact = impact),
                ),
              ),
              _SurveyStep(
                step: 4,
                title: 'Layer 4 · Evidence',
                subtitle: 'Photos, the auto-locked GPS pin, and a short description.',
                complete: _description.text.trim().length >= 8 && position != null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Photos (${_photos.length}/$maxReportPhotos)',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 84,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _photos.length +
                            (_photos.length < maxReportPhotos ? 1 : 0),
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
                      position: position,
                      lockedAt: _lockedAt,
                      error: _locationError,
                      onRetry: _submitting ? null : _lockGps,
                    ),
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
                        counterText: '',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_stillPresent == false)
                _Notice(
                  icon: Icons.info_outline,
                  color: scheme.tertiary,
                  text:
                      'A new report needs an issue that is still on the road. '
                      'Switch Layer 1 to Yes to continue.',
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                _Notice(icon: Icons.error_outline, color: scheme.error, text: _error!),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _canSubmit ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera_alt),
                label: Text(
                  _submitting
                      ? _photos.isEmpty
                          ? 'Submitting report…'
                          : 'Uploading ${_photos.length} photo${_photos.length == 1 ? '' : 's'}…'
                      : 'Submit report',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The pin is taken from your device and cannot be dragged. '
                'Photos are stored on the RCMCA server for ward engineers.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared survey widgets
// ---------------------------------------------------------------------------

class _SurveyStep extends StatelessWidget {
  const _SurveyStep({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.child,
    this.complete = false,
    this.enabled = true,
  });

  final int step;
  final String title;
  final String subtitle;
  final Widget child;
  final bool complete;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: complete
                ? scheme.primary.withValues(alpha: 0.55)
                : scheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: complete ? scheme.primary : scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: complete
                      ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
                      : Text(
                          '$step',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _BooleanSelector extends StatelessWidget {
  const _BooleanSelector({required this.value, required this.onChanged});

  final bool? value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: _ChoiceButton(
            label: 'Yes',
            sublabel: 'Still present',
            icon: Icons.check_circle_outline,
            color: const Color(0xff1b8a5a),
            selected: value == true,
            onTap: onChanged == null ? null : () => onChanged!(true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ChoiceButton(
            label: 'No',
            sublabel: 'Fixed / gone',
            icon: Icons.remove_circle_outline,
            color: scheme.error,
            selected: value == false,
            onTap: onChanged == null ? null : () => onChanged!(false),
          ),
        ),
      ],
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sublabel;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? color.withValues(alpha: 0.12)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? color : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? color : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? color : scheme.onSurface,
                      ),
                    ),
                    Text(
                      sublabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConditionSelector extends StatelessWidget {
  const _ConditionSelector({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in _conditionOptions)
          ChoiceChip(
            label: Text('${option.score}: ${option.label}'),
            selected: value == option.score,
            onSelected:
                onChanged == null ? null : (_) => onChanged!(option.score),
            selectedColor: option.color.withValues(alpha: 0.18),
            side: BorderSide(
              color: value == option.score ? option.color : scheme.outlineVariant,
            ),
            labelStyle: TextStyle(
              color: value == option.score ? option.color : scheme.onSurface,
              fontWeight:
                  value == option.score ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
      ],
    );
  }
}

class _ImpactSelector extends StatelessWidget {
  const _ImpactSelector({required this.value, required this.onChanged});

  final SurveyImpact? value;
  final ValueChanged<SurveyImpact>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final impact in SurveyImpact.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: value == impact
                  ? scheme.primaryContainer.withValues(alpha: 0.55)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onChanged == null ? null : () => onChanged!(impact),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: value == impact
                          ? scheme.primary
                          : scheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        impact.icon,
                        size: 20,
                        color: value == impact
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          impact.label,
                          style: TextStyle(
                            fontWeight: value == impact
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (value == impact)
                        Icon(Icons.check_circle, size: 20, color: scheme.primary),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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
            Icon(inside ? Icons.gps_fixed : Icons.gps_off, size: 14, color: color),
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
    required this.position,
    required this.lockedAt,
    required this.error,
    required this.onRetry,
  });

  final bool locating;
  final Position? position;
  final DateTime? lockedAt;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locked = position;
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
                    '${locked.latitude.toStringAsFixed(6)}, ${locked.longitude.toStringAsFixed(6)}\n'
                    'Accuracy ±${locked.accuracy.toStringAsFixed(0)} m'
                    '${lockedAt == null ? '' : ' · locked ${_clock(lockedAt!)}'}',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                  )
                else
                  Text(
                    error ?? 'Location is not available.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
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
              child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
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
      if (cameras.isEmpty) throw Exception('No camera is available on this device.');
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
