import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_server/noosphere_roast_server.dart';

final ids = List.generate(10, (i) => Identifier.fromUint16(i+1));
final badId = Identifier.fromUint16(11);

final _basePrivkey = cl.ECPrivateKey(Uint8List(32)..last = 1);
Uint8List _getScalar(int i) => Uint8List(32)..last = i+1;
cl.ECPrivateKey getPrivkey(int i) => _basePrivkey.tweak(_getScalar(i))!;

final groupConfig = GroupConfig(
  id: "TestGroup",
  participants: {
    for (int i = 0; i < 10; i++)
      ids[i]: cl.ECCompressedPublicKey.fromPubkey(
        _basePrivkey.pubkey.tweak(_getScalar(i))!,
      ),
  },
);

final serverConfig = ServerConfig(
  group: groupConfig,
  keepAliveFreq: Duration(seconds: 1),
);
ServerApiHandler getApiHandler() => ServerApiHandler(config: serverConfig);

final futureExpiry = Expiry(Duration(days: 1));
final dummySig = cl.SchnorrSignature.sign(getPrivkey(0), Uint8List(32));

NewDkgDetails getDkgDetails({
  String name = "123",
  String description = "",
  int threshold = 2,
  Expiry? expiry,
}) => NewDkgDetails.allowNegativeExpiry(
  name: name,
  description: description,
  threshold: threshold,
  expiry: expiry ?? futureExpiry,
);

Signed<T> signObject<T extends Signable>(T details, [ int i = 0, ])
  => Signed.sign(obj: details, key: getPrivkey(i));

DkgPart1 getDkgPart1(int i) => DkgPart1(
  identifier: ids[i],
  threshold: 2,
  n: 10,
);

ClientConfig getClientConfig(int i) => ClientConfig(
  id: ids[i],
  group: groupConfig,
);
