/// A logger that writes exclusively to stderr.
///
/// This is critical for stdio-based MCP servers where stdout is reserved
/// for MCP protocol messages. Any logging to stdout would corrupt the
/// protocol stream.
library;

import 'dart:io';

/// Log severity levels, ordered from least to most severe.
enum LogLevel { debug, info, warn, error }

/// Singleton logger that writes all output to stderr.
///
/// Usage:
/// ```dart
/// Logger.init(); // Call once at startup
/// Logger.info('Server started');
/// Logger.error('Something failed', error, stackTrace);
/// ```
///
/// Configure via the `LOG_LEVEL` environment variable:
/// - `debug` — verbose output for development
/// - `info`  — default; general operational messages
/// - `warn`  — potential issues that are non-fatal
/// - `error` — failures that need attention
class Logger {

  Logger._();

  /// Current log level. Can be overridden programmatically (useful in tests).
  static LogLevel level = LogLevel.info;

  /// Initialise the logger from the `LOG_LEVEL` environment variable.
  ///
  /// If the variable is unset or unrecognised the level defaults to
  /// [LogLevel.info].
  static void init() {
    final envLevel = Platform.environment['LOG_LEVEL']?.toLowerCase();
    if (envLevel == null || envLevel.isEmpty) {
      level = LogLevel.info;
      return;
    }
    level = LogLevel.values.firstWhere(
      (l) => l.name == envLevel,
      orElse: () => LogLevel.info,
    );
    debug('Logger initialised at level: ${level.name}');
  }

  /// Log a debug-level message.
  static void debug(String message) => _log(LogLevel.debug, message);

  /// Log an info-level message.
  static void info(String message) => _log(LogLevel.info, message);

  /// Log a warning-level message.
  static void warn(String message) => _log(LogLevel.warn, message);

  /// Log an error-level message with an optional [error] and [stackTrace].
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _log(LogLevel.error, message);
    if (error != null) _log(LogLevel.error, '  Error: $error');
    if (stackTrace != null) _log(LogLevel.error, '  Stack: $stackTrace');
  }

  /// Internal writer — guards on level and writes to stderr only.
  static void _log(LogLevel msgLevel, String message) {
    if (msgLevel.index < level.index) return;
    final timestamp = DateTime.now().toIso8601String();
    stderr.writeln('[$timestamp] [${msgLevel.name.toUpperCase()}] $message');
  }
}
