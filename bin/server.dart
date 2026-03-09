import 'dart:io';

import 'package:augur/server.dart';
import 'package:augur/utils/logger.dart';

void main(List<String> args) async {
  Logger.init();
  Logger.info('Starting Augur MCP server...');

  try {
    final server = AugurServer();
    await server.run();
  } catch (e, stack) {
    Logger.error('Fatal error starting server', e, stack);
    exit(1);
  }
}
