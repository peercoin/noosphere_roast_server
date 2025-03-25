import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'server.dart';

class GrpcConfig with cl.Writable, MapWritable {

  final ServerConfig server;
  final int port;

  GrpcConfig({
    required this.server,
    required this.port,
  });

  GrpcConfig.fromReader(cl.BytesReader reader) : this(
    server: ServerConfig.fromReader(reader),
    port: reader.readUInt16(),
  );

  /// Convenience constructor to construct from serialised [bytes].
  GrpcConfig.fromBytes(Uint8List bytes)
    : this.fromReader(cl.BytesReader(bytes));

  /// Convenience constructor to construct from encoded [hex].
  GrpcConfig.fromHex(String hex) : this.fromBytes(cl.hexToBytes(hex));

  GrpcConfig.fromMapReader(MapReader reader) : this(
    server: ServerConfig.fromMapReader(reader["server"]),
    port: reader["port"].require(),
  );

  GrpcConfig.fromYaml(String yaml)
    : this.fromMapReader(MapReader.fromYaml(yaml));

  @override
  void write(cl.Writer writer) {
    server.write(writer);
    writer.writeUInt16(port);
  }

  @override
  Map<Object, Object> map() => {
    "port": port,
    "server": server.map(),
  };

}
