import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'survey_sheets.dart';

/// Hands a prefilled complaint to the phone's mail app (Gmail by default).
///
/// The backend's `draft_email` object maps directly onto [send]: pass `to`,
/// `subject`, and `body` and the citizen only has to tap Send in Gmail.
/// On Android 11+ the intent is launched directly, so no `<queries>` entry is
/// required for this flow. If you switch to `canLaunchUrl`, add a `mailto`
/// query to `AndroidManifest.xml` first.
class MailAppHandoff {
  const MailAppHandoff._();

  /// The authority email stored on an issue, or null when the ward has none.
  static String? recipientFor(Map<String, dynamic> issue) {
    final email = _text(issue['authority_email']);
    if (email == null || !email.contains('@')) return null;
    return email;
  }

  static String defaultSubject(Map<String, dynamic> issue) {
    final category = _readableCategory(_text(issue['category']));
    final ward = _text(issue['ward_name']);
    final location = ward == null ? '' : ' in $ward';
    return '$category$location — RCMCA issue ${_shortId(issue['id'])}';
  }

  static String defaultBody(Map<String, dynamic> issue) {
    final category = _readableCategory(_text(issue['category']));
    final designation = _text(issue['authority_designation']);
    final lines = <String>[
      'Dear ${designation ?? 'Sir/Madam'},',
      '',
      'I am reporting a road issue through the RCMCA citizen app and request an inspection.',
      '',
      'Issue ID: ${_shortId(issue['id'])}',
      'Type: $category',
      'Severity: ${_intValue(issue['severity'])}/5',
    ];

    final status = _text(issue['status']);
    if (status != null) lines.add('Status: ${_humanize(status)}');

    final ward = _text(issue['ward_name']);
    final corporation = _text(issue['corporation']);
    final zone = _text(issue['zone']);
    final wardNo = issue['ward_no'];
    final locality = [
      if (ward != null) ward,
      if (corporation != null) corporation,
      if (zone != null) zone,
      if (wardNo != null) 'Ward $wardNo',
    ].join(' · ');
    if (locality.isNotEmpty) lines.add('Locality: $locality');

    final latitude = _doubleValue(issue['latitude']);
    final longitude = _doubleValue(issue['longitude']);
    if (latitude != null && longitude != null) {
      lines.add('Location: https://www.google.com/maps/search/?api=1&query=$latitude,$longitude');
    }

    final impact = _text(issue['impact_mcq']);
    if (impact != null) lines.add('Reported impact: $impact');

    final description = _text(issue['description']);
    if (description != null) {
      lines.addAll(['', 'Description:', description]);
    }

    final photos = _imageUrls(issue);
    if (photos.isNotEmpty) {
      lines.addAll(['', 'Photos:']);
      for (final url in photos.take(4)) {
        lines.add('- $url');
      }
    }

    lines.addAll([
      '',
      'Please inspect this location and arrange repairs at the earliest.',
      '',
      'Regards,',
      'A concerned citizen',
      '(Sent from the RCMCA road safety app)',
    ]);
    return lines.join('\n');
  }

  /// Opens `mailto:` with the recipient, subject, and body already filled in.
  ///
  /// An empty [to] still opens the mail composer (with subject and body), which
  /// is what happens when the backend drafts a complaint for a ward that has no
  /// `authority_email` on file — the citizen then picks the recipient.
  static Future<bool> send({
    required String to,
    required String subject,
    required String body,
  }) async {
    final address = to.trim();
    final uri = Uri.parse(
      'mailto:$address?subject=${Uri.encodeComponent(subject)}'
      '&body=${Uri.encodeComponent(body)}',
    );
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// [send] plus a short snackbar so the citizen knows what happened.
  static Future<bool> sendWithFeedback(
    BuildContext context, {
    required String to,
    required String subject,
    required String body,
  }) async {
    final launched = await send(to: to, subject: subject, body: body);
    if (!context.mounted) return launched;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          launched
              ? 'Opening your mail app with the complaint pre-filled…'
              : 'No mail app could be opened. Add a mail account and try again.',
        ),
      ),
    );
    return launched;
  }
}

/// Opens the issue detail sheet used by the chat tab and by issue pins.
///
/// When [draftTo], [draftSubject], or [draftBody] are supplied (the chat API's
/// `draft_email`), the mail button reuses that draft. Otherwise a complaint is
/// composed from the issue's own fields, including `authority_email`.
Future<void> showIssueDetailSheet(
  BuildContext context, {
  required Map<String, dynamic> issue,
  String? draftTo,
  String? draftSubject,
  String? draftBody,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => IssueDetailSheet(
      issue: issue,
      draftTo: draftTo,
      draftSubject: draftSubject,
      draftBody: draftBody,
    ),
  );
}

class IssueDetailSheet extends StatefulWidget {
  const IssueDetailSheet({
    super.key,
    required this.issue,
    this.draftTo,
    this.draftSubject,
    this.draftBody,
  });

  final Map<String, dynamic> issue;
  final String? draftTo;
  final String? draftSubject;
  final String? draftBody;

  @override
  State<IssueDetailSheet> createState() => _IssueDetailSheetState();
}

class _IssueDetailSheetState extends State<IssueDetailSheet> {
  late String _status;
  late int _severity;
  late double _confidence;

  @override
  void initState() {
    super.initState();
    _status = _text(widget.issue['status']) ?? 'active_hazard';
    _severity = _intValue(widget.issue['severity']);
    _confidence = _doubleValue(widget.issue['confidence_score']) ?? 0;
  }

  String get _title => _readableCategory(_text(widget.issue['category']));

  String? get _recipient {
    final draft = widget.draftTo?.trim();
    if (draft != null && draft.isNotEmpty) return draft;
    return MailAppHandoff.recipientFor(widget.issue);
  }

  Future<void> _sendMail() async {
    final recipient = _recipient;
    if (recipient == null) {
      _snack('No authority email is on file for this issue.');
      return;
    }
    final subject = _firstNonEmpty([
          widget.draftSubject,
          MailAppHandoff.defaultSubject(widget.issue),
        ]) ??
        'Road issue complaint';
    final body = _firstNonEmpty([
          widget.draftBody,
          MailAppHandoff.defaultBody(widget.issue),
        ]) ??
        MailAppHandoff.defaultBody(widget.issue);
    await MailAppHandoff.sendWithFeedback(
      context,
      to: recipient,
      subject: subject,
      body: body,
    );
  }

  Future<void> _verifyHere() async {
    final id = _text(widget.issue['id']);
    if (id == null) {
      _snack('This issue has no ID, so it cannot be verified here.');
      return;
    }
    final result = await showProximityVerificationSheet(
      context,
      issueId: id,
      categoryLabel: _title,
    );
    if (!mounted || result == null) return;
    setState(() {
      _status = result.status ?? _status;
      _severity = result.severity ?? _severity;
      _confidence = result.confidenceScore ?? _confidence;
    });
    _snack('Verification recorded. Thanks for checking the real road condition.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColor = _statusColor(context, _text(widget.issue['status_color']));
    final imageUrls = _imageUrls(widget.issue);
    final recipient = _recipient;
    final description = _text(widget.issue['description']);
    final impact = _text(widget.issue['impact_mcq']);
    final latitude = _doubleValue(widget.issue['latitude']);
    final longitude = _doubleValue(widget.issue['longitude']);
    final ward = _text(widget.issue['ward_name']);
    final corporation = _text(widget.issue['corporation']);
    final zone = _text(widget.issue['zone']);
    final wardNo = widget.issue['ward_no'];
    final locality = [
      if (ward != null) ward,
      if (corporation != null) corporation,
      if (zone != null) zone,
      if (wardNo != null) 'Ward $wardNo',
    ].join(' · ');
    final designation = _text(widget.issue['authority_designation']);
    final authorityEmail = _text(widget.issue['authority_email']);
    final created = _formatTimestamp(widget.issue['created_at']);
    final updated = _formatTimestamp(widget.issue['updated_at']);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 7),
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '#${_shortId(widget.issue['id'])} · ${_humanize(_status)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill('Severity $_severity/5', color: statusColor),
                _pill(_confidenceLabel(_confidence)),
                _pill('${_intValue(widget.issue['report_count'])} reports'),
                _pill(
                  _humanize(_status),
                  color: statusColor,
                ),
              ],
            ),
            if (imageUrls.isNotEmpty) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 116,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: imageUrls.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(
                      imageUrls[index],
                      width: 156,
                      height: 116,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) => progress == null
                          ? child
                          : Container(
                              width: 156,
                              height: 116,
                              color: scheme.surfaceContainerHighest,
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            ),
                      errorBuilder: (_, __, ___) => Container(
                        width: 156,
                        height: 116,
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (description != null) ...[
              const SizedBox(height: 16),
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _cardTitle('Description'),
                    const SizedBox(height: 6),
                    Text(description, style: const TextStyle(height: 1.4)),
                  ],
                ),
              ),
            ],
            if (impact != null) ...[
              const SizedBox(height: 10),
              _card(
                child: Row(
                  children: [
                    Icon(Icons.traffic, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _cardTitle('Reported impact'),
                          const SizedBox(height: 3),
                          Text(impact),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.place, size: 20, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _cardTitle('Location'),
                            const SizedBox(height: 3),
                            if (latitude != null && longitude != null)
                              Text(
                                '${latitude.toStringAsFixed(5)}, '
                                '${longitude.toStringAsFixed(5)}',
                              ),
                            if (locality.isNotEmpty)
                              Text(
                                locality,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (created.isNotEmpty || updated.isNotEmpty) ...[
                    const Divider(height: 20),
                    Text(
                      [
                        if (created.isNotEmpty) 'Reported $created',
                        if (updated.isNotEmpty) 'updated $updated',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (recipient != null) ...[
              const SizedBox(height: 10),
              _card(
                child: Row(
                  children: [
                    Icon(Icons.account_balance, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _cardTitle(designation ?? 'Ward authority'),
                          const SizedBox(height: 3),
                          Text(authorityEmail ?? recipient),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (recipient != null)
              FilledButton.icon(
                onPressed: _sendMail,
                icon: const Icon(Icons.mail_outline),
                label: const Text('Send via Mail App'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            if (recipient != null) ...[
              const SizedBox(height: 6),
              Text(
                'Opens Gmail (or your default mail app) with the recipient, '
                'subject, and complaint body pre-filled.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (_status != 'resolved') ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _verifyHere,
                icon: const Icon(Icons.fact_check),
                label: const Text('Verify condition here'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }

  Widget _cardTitle(String text) => Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      );

  Widget _pill(String label, {Color? color}) {
    final scheme = Theme.of(context).colorScheme;
    final tone = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: tone,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<String> _imageUrls(Map<String, dynamic> issue) {
  final urls = <String>[];
  final gallery = issue['image_urls'];
  if (gallery is List) {
    for (final item in gallery) {
      if (item is String && item.trim().isNotEmpty && !urls.contains(item)) {
        urls.add(item);
      }
    }
  }
  final cover = _text(issue['evidence_image_url']);
  if (cover != null && !urls.contains(cover)) urls.insert(0, cover);
  return urls;
}

Color _statusColor(BuildContext context, String? statusColor) {
  switch (statusColor) {
    case 'GREEN':
      return const Color(0xff1b8a5a);
    case 'BLUE':
      return const Color(0xff1f6feb);
    case 'YELLOW':
      return const Color(0xffb58105);
    case 'ORANGE':
      return const Color(0xffd97706);
    case 'RED':
      return const Color(0xffd9342b);
    default:
      return Theme.of(context).colorScheme.primary;
  }
}

String _readableCategory(String? category) {
  final value = (category ?? 'road issue').replaceAll('_', ' ').trim();
  if (value.isEmpty) return 'Road issue';
  return value[0].toUpperCase() + value.substring(1);
}

String _humanize(String value) {
  final text = value.replaceAll('_', ' ').trim();
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}

String _shortId(Object? id) {
  final value = id?.toString() ?? '';
  return value.isEmpty
      ? 'unknown'
      : value.length > 8
          ? value.substring(0, 8)
          : value;
}

String _confidenceLabel(double value) {
  final percent = value <= 1 ? value * 100 : value;
  final clamped = percent.clamp(0, 100).toStringAsFixed(0);
  return '$clamped% confidence';
}

String _formatTimestamp(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) return '';
  final local = parsed.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int _intValue(Object? value, [int fallback = 0]) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;

double? _doubleValue(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(value?.toString() ?? '');
