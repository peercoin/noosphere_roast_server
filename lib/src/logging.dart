export 'package:logger/logger.dart'
    show Level, Logger, LogFilter, LogOutput, LogPrinter;

import 'package:logger/logger.dart';

/// Creates the default logger used by server components when no logger is
/// provided.
Logger createNoosphereRoastServerLogger({
  Level level = Level.info,
  LogFilter? filter,
  LogPrinter? printer,
  LogOutput? output,
}) =>
    Logger(
      filter: filter ?? ProductionFilter(),
      printer: printer ?? SimplePrinter(printTime: true, colors: false),
      output: output,
      level: level,
    );
