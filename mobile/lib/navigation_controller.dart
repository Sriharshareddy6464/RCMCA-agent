import 'dart:async';

/// Top-level navigation and route activation controller for RCMCA mobile app.
///
/// Enables external tabs (such as the Chatbot tab) or headless agents to:
/// 1. Switch the active tab directly to the Map tab.
/// 2. Activate a recommended route on MapLibre.
/// 3. Automatically launch in-app driveway mode with 45° camera pitch.
class NavigationController {
  NavigationController._();

  /// Shared singleton instance.
  static final NavigationController instance = NavigationController._();

  /// Callback to switch the active top-level tab by index (0: Map, 1: Chatbot, 2: Report).
  void Function(int index)? switchTab;

  /// Callback registered by the active RoadMapScreen to activate a route payload.
  Future<void> Function(Map<String, dynamic> routePayload, {bool startDriveway})?
      onActivateRecommendedRoute;

  /// Last activated route payload (preserved across tab switches or pending initialization).
  Map<String, dynamic>? lastRoutePayload;

  /// Callback registered by RoadMapScreen to activate a route from a deep link.
  Future<void> Function({String? routeId, String? origin, String? destination})?
      onDeepLinkRoute;

  /// Routes `rcmcs://navigate?route_id=...` deep links to activate that route on the Map tab.
  Future<void> handleDeepLinkUri(Uri uri) async {
    if (uri.scheme == 'rcmcs' || uri.scheme == 'rcmc') {
      if (uri.host == 'navigate' || uri.path.contains('navigate')) {
        final routeId = uri.queryParameters['route_id'];
        final origin = uri.queryParameters['origin'];
        final destination = uri.queryParameters['destination'];

        // 1. Switch directly to Map tab (tab index 0)
        switchTab?.call(0);

        // 2. Activate route through registered handler
        if (onDeepLinkRoute != null) {
          await onDeepLinkRoute!(
            routeId: routeId,
            origin: origin,
            destination: destination,
          );
        }
      }
    }
  }

  /// Parses a deep link string and routes it.
  Future<void> handleDeepLink(String link) async {
    final uri = Uri.tryParse(link);
    if (uri != null) {
      await handleDeepLinkUri(uri);
    }
  }

  /// Clean callback/controller method exposed for the Chatbot tab and external callers.
  ///
  /// Switches directly to the Map tab (tab index 0) and activates the recommended
  /// route on MapLibre in in-app driveway mode (45° camera tilt & simulated tracking).
  Future<void> activateRecommendedRoute(
    Map<String, dynamic> routePayload, {
    bool startDriveway = true,
  }) async {
    lastRoutePayload = routePayload;

    // 1. Switch directly to the Map tab (index 0)
    switchTab?.call(0);

    // 2. Forward to the Map screen controller if registered
    if (onActivateRecommendedRoute != null) {
      await onActivateRecommendedRoute!(routePayload, startDriveway: startDriveway);
    }
  }
}

/// Global convenience function matching the exact required signature:
/// `activateRecommendedRoute(Map<String, dynamic> routePayload)`
///
/// The Chatbot tab or other components can import this directly to switch to
/// the Map tab and launch in-app driveway mode for a recommended route.
Future<void> activateRecommendedRoute(
  Map<String, dynamic> routePayload, {
  bool startDriveway = true,
}) =>
    NavigationController.instance.activateRecommendedRoute(
      routePayload,
      startDriveway: startDriveway,
    );

/// Global convenience function to handle deep links.
Future<void> handleDeepLink(String link) =>
    NavigationController.instance.handleDeepLink(link);

/// Global convenience function to handle deep link URIs.
Future<void> handleDeepLinkUri(Uri uri) =>
    NavigationController.instance.handleDeepLinkUri(uri);
