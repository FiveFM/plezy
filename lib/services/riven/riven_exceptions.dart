import 'dart:async';

import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';

/// The URL doesn't point at a reachable Riven frontend or backend.
///
/// [message] is English for stable logs and Sentry grouping. [display] is the
/// localized user-facing text when this failure is rendered in the UI.
class RivenUrlException implements Exception {
  final String message;
  final String? display;

  /// Status of the response that disqualified the URL, when one arrived at
  /// all. Null means nothing answered (DNS, refused, TLS, timeout), which is
  /// how candidate racing tells "reached a server that isn't Riven" apart from
  /// "never reached anything".
  final int? statusCode;
  const RivenUrlException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'RivenUrlException: $message';
}

/// Sign-in or session-refresh failure (bad credentials, a revoked API key).
/// [RivenClient] treats this during re-auth as "the server rejected the
/// stored credentials" and unlinks the session.
///
/// [message] is English for stable logs and Sentry grouping. [display] is the
/// localized user-facing text when this failure is rendered in the UI.
class RivenAuthException implements Exception {
  final String message;
  final String? display;
  final int? statusCode;
  const RivenAuthException(this.message, {this.statusCode, this.display});

  @override
  String toString() => 'RivenAuthException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// Something in front of Riven answered instead of it: a forward-auth
/// redirect to an SSO login page, an HTTP Basic challenge, an auth wall's
/// 401/403. Riven's own refusals are narrow — the frontend redirects to its
/// login page, the backend and better-auth reject with JSON — so anything
/// else is diagnostic. Deliberately not a [RivenAuthException]: the stored
/// session may be perfectly valid behind the wall, so [RivenClient] must not
/// unlink it.
///
/// [message] is English for stable logs and Sentry grouping. [display] is the
/// localized user-facing text when this failure is rendered in the UI.
class RivenProxyException implements Exception {
  final String message;
  final String display;
  final int statusCode;
  const RivenProxyException(this.message, {required this.display, required this.statusCode});

  @override
  String toString() => 'RivenProxyException($statusCode): $message';
}

/// Non-auth API failure with a server-provided message (FastAPI's `detail`).
class RivenApiException implements Exception {
  final String message;
  final int statusCode;
  const RivenApiException(this.message, {required this.statusCode});

  @override
  String toString() => 'RivenApiException($statusCode): $message';
}

/// A localized, user-safe reason for a Riven failure, for the `${error}` slot
/// of a message that already names what failed.
///
/// Riven's own refusals carry FastAPI's `detail`, shown as the server worded
/// it the way the Seerr request sheet shows Seerr's; the other exceptions
/// here carry a localized `display`. Transport failures map to the shared
/// fixed phrases — their `toString()` names the host and path.
String rivenErrorReason(Object error) => switch (error) {
  RivenApiException(:final message) => message,
  RivenAuthException(:final display?) || RivenUrlException(:final display?) => display,
  RivenProxyException(:final display) => display,
  TimeoutException() => t.errors.reasonTimedOut,
  http.ClientException() => t.errors.reasonUnreachable,
  _ => t.errors.reasonUnexpected,
};
