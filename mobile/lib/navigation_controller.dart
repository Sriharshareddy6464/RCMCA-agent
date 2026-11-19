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
