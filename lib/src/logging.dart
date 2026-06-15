export 'package:logger/logger.dart'
    show Level, Logger, LogFilter, LogOutput, LogPrinter;

import 'package:logger/logger.dart';

Logger _defaultNoosphereRoastServerLogger({
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

/// Logger used by this package.
///
/// Replace it with [configureNoosphereRoastServerLogging] when embedding the
/// package in an application that already has logging configured.
Logger noosphereRoastServerLogger = _defaultNoosphereRoastServerLogger();

/// Configures the logger used by this package.
///
/// Pass [logger] to take full control, or pass individual logger components to
/// keep the package defaults while changing the level, filter, printer, or
/// output.
void configureNoosphereRoastServerLogging({
  Logger? logger,
  Level level = Level.info,
  LogFilter? filter,
  LogPrinter? printer,
  LogOutput? output,
}) {
  noosphereRoastServerLogger = logger ??
      _defaultNoosphereRoastServerLogger(
        level: level,
        filter: filter,
        printer: printer,
        output: output,
      );
}
