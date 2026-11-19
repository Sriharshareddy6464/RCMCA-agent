# RCMCA Mobile

Flutter client for reporting road hazards, reviewing nearby pins, planning safer routes, and confirming whether a reported issue remains active.

## Run on Android

1. Install Flutter 3.50+ and Android Studio / Android SDK, including Android SDK Command-line Tools, then run `flutter pub get` in `mobile/`.
2. Start the root Docker Compose services and make the API reachable from the phone. Android emulator uses `http://10.0.2.2:8001`. For a USB-connected development phone, run `adb reverse tcp:8001 tcp:8001` and use `http://127.0.0.1:8001`; over Wi-Fi, use the development machine's LAN IP and firewall access.
3. Configure the API's `S3_BUCKET`, AWS credentials/role, and `S3_PUBLIC_BASE_URL` before using photo reporting. The presign route returns a 503 until a private S3 bucket and its CloudFront URL are configured.
4. Run `flutter run --dart-define=RCMCA_API_BASE_URL=http://10.0.2.2:8001` (emulator) or replace the URL with `http://127.0.0.1:8001` for USB reverse forwarding.

The current Android debug APK and release AAB are local build outputs under `build/app/outputs/`. The release Gradle configuration keeps native symbols in bundle metadata, and the Flutter AAB symbol check passes with Android Command-line Tools installed. A Play upload still needs a production signing key and production API URL; the checked-in Gradle setup currently signs release builds with the debug key. This workspace has a Git-ignored local Android SDK tools folder under `.android-sdk/` with junctions to the installed SDK components; configure `ANDROID_HOME` to that folder when reproducing the AAB check on this workstation.

The map currently uses MapLibre's public demo style, centered on Hyderabad. Configure a production style/tile source before field deployment. The starter expects navigation destinations as latitude/longitude; address search is not part of this phase.

## Platform permissions

Android permissions are declared in `android/app/src/main/AndroidManifest.xml`; cleartext HTTP is allowed only in the debug manifest. Background location must be disclosed and requested only after the user starts navigation; Play review may require a user-facing justification. iOS camera/location purpose strings and the Location Updates background mode are declared in `ios/Runner/Info.plist`. iOS builds and signing still require macOS/Xcode.

Continuous location checks run while navigation is active. Android uses a foreground service notification; iOS enables Core Location background updates. Geofence alerts are limited to active hazards returned by the visible map viewport, so production navigation should fetch an along-route corridor feed as the user moves.

Location-triggered viewport requests are throttled to one every 15 seconds to limit API traffic; manual refresh and map-camera movement request an immediate reload.

## API address

Set `RCMCA_API_BASE_URL` at build/run time. Never ship the emulator URL in a release build. The app uses `/api/v1/issues` viewport listing, `/api/v1/routes/plan`, `/api/v1/issues/report`, `/api/v1/issues/{id}/verify`, `/api/v1/uploads/presign`, and `/api/v1/issues/{id}/vision`.

## Current limitations

- API vote identity is a development placeholder until authentication and user accounts exist.
- S3 upload requires configured AWS credentials and an S3/CloudFront deployment from Phase 4.
- The camera samples the best available GPS fix immediately before the shutter action and stores capture time, GPS accuracy, heading, and every submitted evidence URL. It is not hardware shutter synchronization.
- The included vision model detects potholes only. The category picker does not imply model classification support for the other hazard types.
- The public demo map style is for development only.
