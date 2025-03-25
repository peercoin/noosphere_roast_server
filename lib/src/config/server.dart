import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/common.dart';
import 'package:noosphere_roast_client/noosphere_roast_client.dart';

class ServerConfig with cl.Writable, MapWritable {

  static const defaultChallengeTTL = Duration(seconds: 20);
  static const defaultSessionTTL = Duration(minutes: 1);
  static const defaultMinDkgRequestTTL = Duration(minutes: 29);
  static const defaultMaxDkgRequestTTL = Duration(days: 7);
  static const defaultMinSignaturesRequestTTL = Duration(seconds: 25);
  static const defaultMaxSignaturesRequestTTL = Duration(days: 14);
  static const defaultMinCompletedSignaturesTTL = Duration(days: 1);
  static const defaultAckCacheTTL = Duration(minutes: 1);

  final GroupConfig group;
  final Duration challengeTTL;
  final Duration sessionTTL;
  final Duration minDkgRequestTTL;
  final Duration maxDkgRequestTTL;
  final Duration minSignaturesRequestTTL;
  final Duration maxSignaturesRequestTTL;
  final Duration minCompletedSignaturesTTL;
  final Duration ackCacheTTL;

  /// A [KeepaliveEvent] will be sent to clients periodically.
  final Duration? keepAliveFreq;

  ServerConfig({
    required this.group,
    this.challengeTTL = defaultChallengeTTL,
    this.sessionTTL = defaultSessionTTL,
    this.minDkgRequestTTL = defaultMinDkgRequestTTL,
    this.maxDkgRequestTTL = defaultMaxDkgRequestTTL,
    this.minSignaturesRequestTTL = defaultMinSignaturesRequestTTL,
    this.maxSignaturesRequestTTL = defaultMaxSignaturesRequestTTL,
    this.minCompletedSignaturesTTL = defaultMinCompletedSignaturesTTL,
    this.ackCacheTTL = defaultAckCacheTTL,
    this.keepAliveFreq,
  });

  /// Convenience constructor to construct from serialised [bytes].
  ServerConfig.fromBytes(Uint8List bytes)
    : this.fromReader(cl.BytesReader(bytes));

  /// Convenience constructor to construct from encoded [hex].
  ServerConfig.fromHex(String hex) : this.fromBytes(cl.hexToBytes(hex));

  ServerConfig.fromReader(cl.BytesReader reader) : this(
    group: GroupConfig.fromReader(reader),
    challengeTTL: reader.readDuration(),
    sessionTTL: reader.readDuration(),
    minDkgRequestTTL: reader.readDuration(),
    maxDkgRequestTTL: reader.readDuration(),
    minSignaturesRequestTTL: reader.readDuration(),
    maxSignaturesRequestTTL: reader.readDuration(),
    minCompletedSignaturesTTL: reader.readDuration(),
    ackCacheTTL: reader.readDuration(),
    keepAliveFreq: reader.readBool() ? reader.readDuration() : null,
  );

  ServerConfig.fromMapReader(MapReader reader) : this(
    group: GroupConfig.fromMapReader(reader["group"]),
    challengeTTL: reader.getTTL("challenge") ?? defaultChallengeTTL,
    sessionTTL: reader.getTTL("session") ?? defaultSessionTTL,
    minDkgRequestTTL: reader.getTTL("min-dkg-request")
      ?? defaultMinDkgRequestTTL,
    maxDkgRequestTTL: reader.getTTL("max-dkg-request")
      ?? defaultMaxDkgRequestTTL,
    minSignaturesRequestTTL: reader.getTTL("min-signatures-request")
      ?? defaultMinSignaturesRequestTTL,
    maxSignaturesRequestTTL: reader.getTTL("max-signatures-request")
      ?? defaultMaxSignaturesRequestTTL,
    minCompletedSignaturesTTL: reader.getTTL("min-completed-signatures")
      ?? defaultMinCompletedSignaturesTTL,
    ackCacheTTL: reader.getTTL("ack-cache") ?? defaultAckCacheTTL,
    keepAliveFreq: reader["keep-alive-event-ms"].duration(),
  );

  ServerConfig.fromYaml(String yaml)
    : this.fromMapReader(MapReader.fromYaml(yaml));

  @override
  void write(cl.Writer writer) {

    group.write(writer);

    writer.writeDuration(challengeTTL);
    writer.writeDuration(sessionTTL);
    writer.writeDuration(minDkgRequestTTL);
    writer.writeDuration(maxDkgRequestTTL);
    writer.writeDuration(minSignaturesRequestTTL);
    writer.writeDuration(maxSignaturesRequestTTL);
    writer.writeDuration(minCompletedSignaturesTTL);
    writer.writeDuration(ackCacheTTL);

    bool useKeepalive = keepAliveFreq != null;
    writer.writeBool(useKeepalive);
    if (useKeepalive) {
      writer.writeDuration(keepAliveFreq!);
    }

  }

  @override
  Map<Object, Object> map() => {
    "ms-lifetimes": {
      "challenge": challengeTTL.inMilliseconds,
      "session": sessionTTL.inMilliseconds,
      "min-dkg-request": minDkgRequestTTL.inMilliseconds,
      "max-dkg-request": maxDkgRequestTTL.inMilliseconds,
      "min-signatures-request": minSignaturesRequestTTL.inMilliseconds,
      "max-signatutres-request": maxSignaturesRequestTTL.inMilliseconds,
      "min-completed-signatures": minCompletedSignaturesTTL.inMilliseconds,
      "ack-cache": ackCacheTTL.inMilliseconds,
    },
    if (keepAliveFreq != null) "keep-alive-event-ms": keepAliveFreq!.inMilliseconds,
    "group": group.map(),
  };

}
