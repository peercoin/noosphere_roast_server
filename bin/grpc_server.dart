import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:coinlib/coinlib.dart';
import 'package:noosphere_roast_server/noosphere_roast_server.dart';

void main(List<String> args) async {

  final argParser = ArgParser();
  argParser.addOption(
    "config",
    abbr: "c",
    help: "The path to the GrpcConfig YAML file",
    mandatory: true,
  );
  final argResults = argParser.parse(args);
  final configFile = argResults.option("config")!;
  final configString = File(configFile).readAsStringSync();

  await loadFrosty();

  final config = GrpcConfig.fromYaml(configString);
  print("Loaded config from $configFile");
  print("Group fingerprint is ${bytesToHex(config.server.group.fingerprint)}");

  final apiHandler = ServerApiHandler(config: config.server);
  final service = FrostNoosphereService(api: apiHandler);
  final grpcServer = service.createServer();
  await grpcServer.serve(port: config.port);
  print("Server listening on port ${config.port}");

  // Wait for SIGINT or SIGTERM to terminate server

  final termCompleter = Completer<ProcessSignal>();

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((sig) {
      if (termCompleter.isCompleted) {
        print("Exiting immediately");
        exit(0);
      }
      termCompleter.complete(sig);
    });
  }

  final signal = await termCompleter.future;
  print("Caught ${signal.name}. Shutting down server.");

  await apiHandler.shutdown();
  await grpcServer.shutdown();

  exit(0);

}
