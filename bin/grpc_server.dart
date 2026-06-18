import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:coinlib/coinlib.dart';
import 'package:noosphere_roast_server/noosphere_roast_server.dart';

const _logLevels = {
  "trace": Level.trace,
  "debug": Level.debug,
  "info": Level.info,
  "warning": Level.warning,
  "error": Level.error,
  "fatal": Level.fatal,
  "off": Level.off,
};

void main(List<String> args) async {
  final argParser = ArgParser();
  argParser.addOption(
    "config",
    abbr: "c",
    help: "The path to the GrpcConfig YAML file",
    mandatory: true,
  );
  argParser.addOption(
    "rest-port",
    help: "Optional REST/WebSocket port for browser clients",
  );
  argParser.addOption(
    "rest-address",
    help: "REST/WebSocket bind address",
    defaultsTo: "localhost",
  );
  argParser.addOption(
    "rest-allow-origin",
    help: "CORS Access-Control-Allow-Origin value for REST/WebSocket clients",
    defaultsTo: "*",
  );
  argParser.addFlag(
    "rest-disable-cors",
    help: "Do not emit CORS headers; use when a reverse proxy handles CORS",
    defaultsTo: false,
    negatable: false,
  );
  argParser.addOption(
    "log-level",
    help: "Minimum log level to emit",
    allowed: _logLevels.keys,
    defaultsTo: "info",
  );
  final argResults = argParser.parse(args);
  configureNoosphereRoastServerLogging(
    level: _logLevels[argResults.option("log-level")]!,
  );
  final configFile = argResults.option("config")!;
  final restPortString = argResults.option("rest-port");
  final restPort = restPortString == null ? null : int.parse(restPortString);
  final configString = File(configFile).readAsStringSync();

  await loadFrosty();

  final config = GrpcConfig.fromYaml(configString);
  noosphereRoastServerLogger.i("Loaded config from $configFile");
  noosphereRoastServerLogger.i(
    "Group fingerprint is ${bytesToHex(config.server.group.fingerprint)}",
  );

  final apiHandler = SynchronizedServerApiHandler(config: config.server);
  final service = FrostNoosphereService(api: apiHandler);
  final grpcServer = service.createServer();
  await grpcServer.serve(port: config.port);
  noosphereRoastServerLogger.i("gRPC server listening on port ${config.port}");

  HttpServer? restServer;
  if (restPort != null) {
    final restService = RestWebSocketNoosphereService(
      api: apiHandler,
      allowOrigin: argResults.flag("rest-disable-cors")
          ? null
          : argResults.option("rest-allow-origin")!,
    );
    final restAddress = argResults.option("rest-address")!;
    restServer = await restService.serve(address: restAddress, port: restPort);
    noosphereRoastServerLogger.i(
      "REST/WebSocket server listening on $restAddress:${restServer.port}",
    );
  }

  // Wait for SIGINT or SIGTERM to terminate server

  final termCompleter = Completer<ProcessSignal>();

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((sig) {
      if (termCompleter.isCompleted) {
        noosphereRoastServerLogger.w("Exiting immediately");
        exit(0);
      }
      termCompleter.complete(sig);
    });
  }

  final signal = await termCompleter.future;
  noosphereRoastServerLogger.i(
    "Caught ${signal.name}. Shutting down server.",
  );

  await apiHandler.shutdown();
  await restServer?.close(force: true);
  await grpcServer.shutdown();

  exit(0);
}
