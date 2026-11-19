import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';

import '../widgets/issue_detail_sheet.dart';
import '../widgets/survey_sheets.dart' show rcmcaApiBase;

/// A route recommendation returned by `POST /api/v1/chat`.
///
/// [geometry] is the raw GeoJSON geometry from OSRM (`type: LineString`,
/// coordinates in longitude/latitude order). The Map tab can project it with
/// `ChatRoutePlan.coordinates` and draw it without calling `/routes/plan` again.
class ChatRoutePlan {
  const ChatRoutePlan({
    required this.routeId,
    required this.label,
    required this.distanceKm,
    required this.durationMin,
    required this.geometry,
    this.issuesOnRoute = const [],
  });

  final String routeId;
  final String label;
  final double distanceKm;
  final double durationMin;
  final Map<String, dynamic> geometry;
  final List<Map<String, dynamic>> issuesOnRoute;

  int get criticalIssueCount => issuesOnRoute.where((issue) {
        final color = issue['status_color'];
        return color == 'ORANGE' || color == 'RED';
      }).length;

  List<List<double>> get coordinates {
    final raw = geometry['coordinates'];
    if (raw is! List) return const [];
    final points = <List<double>>[];
    for (final point in raw) {
      if (point is List && point.length >= 2) {
        final longitude = point[0];
        final latitude = point[1];
        if (longitude is num && latitude is num) {
          points.add([longitude.toDouble(), latitude.toDouble()]);
        }
      }
    }
    return points;
  }
}

/// Called when the citizen taps "Start In-App Driveway".
///
/// Wire this to the Map tab: set the route line from [ChatRoutePlan.geometry],
/// zoom to the corridor, and turn on navigation. The callback may be async.
typedef StartDrivewayCallback = Future<void> Function(ChatRoutePlan plan);

/// The `draft_email` object from the chat API.
class ChatDraftEmail {
  const ChatDraftEmail({
    required this.to,
    required this.subject,
    required this.body,
  });

  final String to;
  final String subject;
  final String body;
}

/// A parsed `POST /api/v1/chat` response.
class ChatReply {
  const ChatReply({
    required this.intent,
    required this.message,
    this.route,
    this.issue,
    this.draftEmail,
  });

  factory ChatReply.fromJson(Map<String, dynamic> json) {
    final routes = _asMaps(json['routes']);
    final routeId = _asString(json['recommended_route_id']);
    final geometry = _asMap(json['recommended_route_geojson']);
    ChatRoutePlan? route;
    // `recommended_route_id` alone is enough to offer "Start In-App Driveway":
    // if the geometry is ever missing the Map tab can re-plan from the route id.
    if (routeId != null) {
      Map<String, dynamic>? selected;
      for (final candidate in routes) {
        if (candidate['route_id'] == routeId) {
          selected = candidate;
          break;
        }
      }
      route = ChatRoutePlan(
        routeId: routeId,
        label: _asString(selected?['label']) ?? 'Safest available route',
        distanceKm: _asDouble(selected?['distance_km']) ?? 0,
        durationMin: _asDouble(selected?['duration_min']) ?? 0,
        geometry: geometry ?? const <String, dynamic>{},
        issuesOnRoute: _asMaps(selected?['issues_on_route']),
      );
    }
    return ChatReply(
      intent: _asString(json['intent']) ?? 'other',
      message: _asString(json['message']) ?? '',
      route: route,
      issue: _asMap(json['issue']),
      draftEmail: _asDraft(json['draft_email']),
    );
  }

  final String intent;
  final String message;
  final ChatRoutePlan? route;
  final Map<String, dynamic>? issue;
  final ChatDraftEmail? draftEmail;
}

class _ChatMessage {
  const _ChatMessage({required this.text, required this.isUser, this.reply});

  final String text;
  final bool isUser;
  final ChatReply? reply;
}

/// Conversational tab backed by `POST /api/v1/chat`.
///
/// The assistant can explain a route, show the issue it found, or return a
/// pre-written complaint email. This screen renders:
///  * "Start In-App Driveway" when [ChatReply.route] is present, invoking
///    [onStartDriveway] so the Map tab can activate the route.
///  * "Send via Mail App" when `draft_email` (or the issue's `authority_email`)
///    is available, opening `mailto:` through `url_launcher`.
///
/// Pass `showAppBar: false` when the parent tab shell already supplies an
/// `AppBar`.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.onStartDriveway,
    this.showAppBar = true,
  });

  final StartDrivewayCallback? onStartDriveway;
  final bool showAppBar;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const String _welcomeText =
      'Hi! I can check road conditions, plan a safer route, or draft a complaint '
      'email to the ward authority. Ask me anything about Hyderabad roads.';
  static const _ChatMessage _welcome =
      _ChatMessage(text: _welcomeText, isUser: false);

  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_ChatMessage> _messages = <_ChatMessage>[_welcome];

  bool _sending = false;
  Position? _lastPosition;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    if (_sending) return;
    final text = (preset ?? _composer.text).trim();
    if (text.isEmpty) return;
    _composer.clear();
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _sending = true;
    });
    _scrollToBottom();

    try {
      final position = _lastPosition ?? await _tryCurrentPosition();
      _lastPosition = position;
      final response = await http
          .post(
            Uri.parse('$rcmcaApiBase/api/v1/chat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'message': text,
              if (position != null) 'user_lat': position.latitude,
              if (position != null) 'user_lon': position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 75));
      if (response.statusCode != 200) throw Exception(_apiError(response));
      final reply = ChatReply.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(text: reply.message, isUser: false, reply: reply));
        _sending = false;
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(
            text: 'I could not finish that request. ${_cleanError(error)}',
            isUser: false,
          ),
        );
        _sending = false;
      });
      _scrollToBottom();
    }
  }

  Future<Position?> _tryCurrentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // Chat still works for named origins; location is only a convenience.
      return null;
    }
  }

  Future<void> _startDriveway(ChatRoutePlan route) async {
    final handler = widget.onStartDriveway;
    if (handler == null) {
      _snack('Open the Map tab to start this route.');
      return;
    }
    try {
      await handler(route);
      _snack('${route.routeId} is ready in the Map tab.');
    } catch (error) {
      _snack('Could not start the route: ${_cleanError(error)}');
    }
  }

  /// The button appears whenever the backend supplied a `draft_email` or the
  /// issue carries its ward authority's address, per the chat contract.
  bool _canMail(ChatReply reply) {
    if (reply.draftEmail != null) return true;
    final issue = reply.issue;
    return issue != null && MailAppHandoff.recipientFor(issue) != null;
  }

  String _recipientFor(ChatReply reply) {
    final draftTo = reply.draftEmail?.to.trim();
    if (draftTo != null && draftTo.isNotEmpty) return draftTo;
    final issue = reply.issue;
    return issue == null ? '' : MailAppHandoff.recipientFor(issue) ?? '';
  }

  Future<void> _sendViaMail(ChatReply reply) async {
    if (!_canMail(reply)) {
      _snack('No authority email is available for this issue.');
      return;
    }
    final recipient = _recipientFor(reply);
    final issue = reply.issue;
    final subject = _firstNonEmpty([
          reply.draftEmail?.subject,
          if (issue != null) MailAppHandoff.defaultSubject(issue),
        ]) ??
        'Road issue complaint';
    final body = _firstNonEmpty([
          reply.draftEmail?.body,
          if (issue != null) MailAppHandoff.defaultBody(issue),
        ]) ??
        'Reporting a road issue through the RCMCA app.';
    await MailAppHandoff.sendWithFeedback(
      context,
      to: recipient,
      subject: subject,
      body: body,
    );
  }

  void _resetConversation() {
    if (_sending) return;
    setState(() {
      _messages
        ..clear()
        ..add(_welcome);
    });
    _scrollToBottom();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            itemCount: _messages.length + (_sending ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _messages.length) return _typingBubble();
              return _buildMessage(_messages[index]);
            },
          ),
        ),
        if (_messages.length == 1 && !_sending) _suggestions(),
        _composerBar(context),
      ],
    );

    if (!widget.showAppBar) {
      return SafeArea(top: false, child: body);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Road assistant'),
        actions: [
          IconButton(
            onPressed: _sending ? null : _resetConversation,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'New conversation',
          ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _buildMessage(_ChatMessage message) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;
    final reply = message.reply;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.87,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isUser ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.text.isEmpty ? '…' : message.text,
                style: TextStyle(
                  color: isUser ? scheme.onPrimary : scheme.onSurface,
                  height: 1.35,
                ),
              ),
              if (!isUser && reply != null) ..._replyWidgets(reply),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _replyWidgets(ChatReply reply) {
    final scheme = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    final route = reply.route;
    if (route != null) {
      widgets.add(Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.route, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    route.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${route.distanceKm.toStringAsFixed(1)} km · '
              '${route.durationMin.toStringAsFixed(0)} min · '
              '${route.issuesOnRoute.length} issue(s) on the corridor'
              '${route.criticalIssueCount == 0 ? '' : ' · ${route.criticalIssueCount} critical'}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _startDriveway(route),
              icon: const Icon(Icons.directions_car),
              label: const Text('Start In-App Driveway'),
            ),
          ],
        ),
      ));
    }

    final issue = reply.issue;
    if (issue != null) {
      widgets.add(const SizedBox(height: 10));
      widgets.add(_issueSummary(issue, reply));
    }

    if (_canMail(reply)) {
      widgets.add(const SizedBox(height: 10));
      widgets.add(SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _sendViaMail(reply),
          icon: const Icon(Icons.mail_outline),
          label: const Text('Send via Mail App'),
        ),
      ));
    }

    return widgets;
  }

  Widget _issueSummary(Map<String, dynamic> issue, ChatReply reply) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ward = _text(issue['ward_name']);
    final severity = _intValue(issue['severity']);
    final status = _humanize(_text(issue['status']) ?? 'road issue');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showIssueDetailSheet(
          context,
          issue: issue,
          draftTo: reply.draftEmail?.to,
          draftSubject: reply.draftEmail?.subject,
          draftBody: reply.draftEmail?.body,
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.report_problem_outlined, color: scheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_readableCategory(_text(issue['category']))} · $status',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Severity $severity/5'
                      '${ward == null ? '' : ' · $ward'} · tap for details',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typingBubble() {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Checking routes and road reports…',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestions() {
    const prompts = [
      'Plan a safer route to Charminar',
      'Any potholes near Madhapur?',
      'Draft a complaint for my nearest pothole',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final prompt in prompts)
            ActionChip(
              onPressed: _sending ? null : () => _send(prompt),
              label: Text(prompt),
            ),
        ],
      ),
    );
  }

  Widget _composerBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _composer,
              enabled: !_sending,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Ask about routes, hazards, or complaints…',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : () => _send(),
            tooltip: 'Send',
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

String _apiError(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] is String) return first['msg'] as String;
      }
    }
  } catch (_) {
    // Fall through to the status message.
  }
  return 'The assistant is unavailable (HTTP ${response.statusCode}).';
}

String _cleanError(Object error) =>
    error.toString().replaceFirst('Exception: ', '');

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

String? _asString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<Map<String, dynamic>> _asMaps(Object? value) {
  final result = <Map<String, dynamic>>[];
  if (value is List) {
    for (final item in value) {
      final map = _asMap(item);
      if (map != null) result.add(map);
    }
  }
  return result;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

ChatDraftEmail? _asDraft(Object? value) {
  final map = _asMap(value);
  if (map == null) return null;
  return ChatDraftEmail(
    to: _asString(map['to']) ?? '',
    subject: _asString(map['subject']) ?? '',
    body: _asString(map['body']) ?? '',
  );
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

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int _intValue(Object? value, [int fallback = 0]) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;
