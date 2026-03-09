/// HTTP client wrapper with retry logic, rate-limit handling, and
/// automatic GitHub authentication.
///
/// All network activity is routed through this wrapper so that retries,
/// backoff, and auth are handled consistently across the codebase.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'logger.dart';

/// A lightweight value object for HTTP responses.
class HttpResponse {

  const HttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  /// Whether the status code is in the 2xx range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Parse the body as a JSON object.
  Map<String, dynamic> get json =>
      jsonDecode(body) as Map<String, dynamic>;

  /// Parse the body as a JSON array.
  List<dynamic> get jsonList => jsonDecode(body) as List<dynamic>;

  @override
  String toString() => 'HttpResponse(statusCode: $statusCode, '
      'bodyLength: ${body.length})';
}

/// Wraps [http.Client] with:
/// - Automatic retry with exponential backoff (1 s, 2 s, 4 s).
/// - Respect for `429 Too Many Requests` and the `Retry-After` header.
/// - `Authorization` header injection for GitHub URLs when `GITHUB_TOKEN`
///   is set.
/// - GitHub API `Accept` header (`application/vnd.github.v3+json`).
/// - Debug-level request/response logging via [Logger].
class HttpClientWrapper {

  /// Creates a new wrapper.
  ///
  /// An optional [client] may be provided for testing. The GitHub token is
  /// read from the `GITHUB_TOKEN` environment variable.
  HttpClientWrapper({http.Client? client})
      : _client = client ?? http.Client(),
        _githubToken = Platform.environment['GITHUB_TOKEN'];
  final http.Client _client;
  final String? _githubToken;

  /// Maximum number of retry attempts per request.
  static const int _maxRetries = 3;

  /// Base delay for exponential backoff. The actual delay for attempt *n* is
  /// `_baseDelay * 2^n`.
  static const Duration _baseDelay = Duration(seconds: 1);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Perform an HTTP GET request to [url].
  ///
  /// Additional [headers] are merged with any automatically generated headers
  /// (e.g. GitHub auth).
  Future<HttpResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    return _requestWithRetry('GET', url, headers: headers);
  }

  /// Perform an HTTP POST request to [url] with an optional JSON [body].
  Future<HttpResponse> post(
    String url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return _requestWithRetry('POST', url, headers: headers, body: body);
  }

  /// Release the underlying [http.Client] resources.
  void dispose() => _client.close();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Determine whether [url] targets the GitHub API.
  bool _isGitHubUrl(String url) =>
      url.startsWith('https://api.github.com') ||
      url.startsWith('https://raw.githubusercontent.com');

  /// Build a merged header map, injecting GitHub-specific headers when
  /// appropriate.
  Map<String, String> _buildHeaders(
    String url,
    Map<String, String>? extra,
  ) {
    final merged = <String, String>{};

    if (_isGitHubUrl(url)) {
      merged['Accept'] = 'application/vnd.github.v3+json';
      if (_githubToken != null && _githubToken!.isNotEmpty) {
        merged['Authorization'] = 'token $_githubToken';
      }
    }

    if (extra != null) {
      merged.addAll(extra);
    }

    return merged;
  }

  /// Execute a request with up to [_maxRetries] retry attempts.
  Future<HttpResponse> _requestWithRetry(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final mergedHeaders = _buildHeaders(url, headers);
    late http.Response response;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        Logger.debug(
          '$method $url (attempt ${attempt + 1}/${_maxRetries + 1})',
        );

        final uri = Uri.parse(url);

        switch (method) {
          case 'GET':
            response = await _client.get(uri, headers: mergedHeaders);
            break;
          case 'POST':
            final encodedBody = body != null ? jsonEncode(body) : null;
            final postHeaders = Map<String, String>.from(mergedHeaders);
            if (encodedBody != null) {
              postHeaders['Content-Type'] = 'application/json; charset=utf-8';
            }
            response = await _client.post(
              uri,
              headers: postHeaders,
              body: encodedBody,
            );
            break;
          default:
            throw ArgumentError('Unsupported HTTP method: $method');
        }

        Logger.debug(
          '$method $url -> ${response.statusCode} '
          '(${response.body.length} bytes)',
        );

        // ----- Rate limiting (429) -----
        if (response.statusCode == 429) {
          final retryAfter = _parseRetryAfter(response.headers);
          if (attempt < _maxRetries) {
            Logger.warn(
              'Rate limited on $url. Retrying after '
              '${retryAfter.inSeconds}s...',
            );
            await Future<void>.delayed(retryAfter);
            continue;
          }
        }

        // ----- Server errors (5xx) -----
        if (response.statusCode >= 500 && attempt < _maxRetries) {
          final delay = _baseDelay * (1 << attempt); // exponential backoff
          Logger.warn(
            'Server error ${response.statusCode} on $url. '
            'Retrying in ${delay.inSeconds}s...',
          );
          await Future<void>.delayed(delay);
          continue;
        }

        // Success or non-retryable client error — return immediately.
        return HttpResponse(
          statusCode: response.statusCode,
          body: response.body,
          headers: response.headers,
        );
      } on SocketException catch (e) {
        if (attempt < _maxRetries) {
          final delay = _baseDelay * (1 << attempt);
          Logger.warn(
            'Network error on $url ($e). '
            'Retrying in ${delay.inSeconds}s...',
          );
          await Future<void>.delayed(delay);
          continue;
        }
        Logger.error('Network error on $url after ${_maxRetries + 1} attempts',
            e);
        rethrow;
      } on http.ClientException catch (e) {
        if (attempt < _maxRetries) {
          final delay = _baseDelay * (1 << attempt);
          Logger.warn(
            'Client error on $url ($e). '
            'Retrying in ${delay.inSeconds}s...',
          );
          await Future<void>.delayed(delay);
          continue;
        }
        Logger.error(
            'Client error on $url after ${_maxRetries + 1} attempts', e);
        rethrow;
      }
    }

    // Should be unreachable, but return the last response as a safety net.
    return HttpResponse(
      statusCode: response.statusCode,
      body: response.body,
      headers: response.headers,
    );
  }

  /// Parse the `Retry-After` header.
  ///
  /// The header may contain seconds (integer) or an HTTP-date. If missing or
  /// unparseable, defaults to 5 seconds.
  Duration _parseRetryAfter(Map<String, String> headers) {
    final value = headers['retry-after'];
    if (value == null) return const Duration(seconds: 5);

    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds);

    // Attempt to parse as HTTP-date (RFC 7231).
    try {
      final date = HttpDate.parse(value);
      final diff = date.difference(DateTime.now());
      return diff.isNegative ? const Duration(seconds: 1) : diff;
    } catch (_) {
      return const Duration(seconds: 5);
    }
  }
}
