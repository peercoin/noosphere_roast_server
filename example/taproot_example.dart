import 'dart:async';
import 'dart:io';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:grpc/grpc.dart' as grpc;
import 'package:noosphere_roast_server/noosphere_roast_server.dart';

String getCommandLineString(String prompt) {
  stdout.write("$prompt: ");
  return stdin.readLineSync() ?? "";
}

int getCommandLineInt(String prompt, int min, int max) {
  final i = int.parse(getCommandLineString(prompt));
  RangeError.checkValueInInterval(i, min, max);
  return i;
}

class EventCompleters {

  final gotDkg = Completer<void>();
  final gotSigsReq = Completer<void>();
  final signature = Completer<cl.SchnorrSignature>();

  EventCompleters(Stream<ClientEvent> events) {
    events.listen((event) {
      switch (event) {
        case UpdatedDkgClientEvent():
          if (!gotDkg.isCompleted) gotDkg.complete();
        case SignaturesRequestClientEvent():
          gotSigsReq.complete();
        case SignaturesCompleteClientEvent():
          signature.complete(event.signatures.first);
        case _: break;
      }
    });
  }

}

const maxParticipants = 1000;
const port = 13543;
const String keyName = "example_key";

void main() async {

  await loadFrosty();

  final nParticipants = getCommandLineInt(
    "Number of participants", 2, maxParticipants,
  );
  final threshold = getCommandLineInt("Threshold", 2, nParticipants);

  print("Creating server");

  final ids = List.generate(nParticipants, (i) => Identifier.fromUint16(i+1));
  final participantKeys = List.generate(
    nParticipants, (i) => cl.ECPrivateKey.generate(),
  );

  final groupConfig = GroupConfig(
    id: "example",
    participants: {
      for (int i = 0; i < nParticipants; i++)
        ids[i]: cl.ECCompressedPublicKey.fromPubkey(
          participantKeys[i].pubkey,
        ),
    },
  );

  final server = FrostNoosphereService(
    api: ServerApiHandler(
      config: ServerConfig(
        group: groupConfig,
        sessionTTL: Duration(minutes: 25),
      ),
    ),
  ).createServer();
  await server.serve(port: port);

  print("Logging in $nParticipants clients");

  final stores = List.generate(nParticipants, (i) => InMemoryClientStorage());
  final clients = await Future.wait(
    List.generate(
      nParticipants,
      (i) => Client.login(
        config: ClientConfig(group: groupConfig, id: ids[i]),
        api: GrpcClientApi(
          grpc.ClientChannel(
            "127.0.0.1",
            port: port,
            options: const grpc.ChannelOptions(
              credentials: grpc.ChannelCredentials.insecure(),
            ),
          ),
        ),
        store: stores[i],
        getPrivateKey: (_) async => participantKeys[i],
      ),
    ),
  );
  final clientCompleters = clients.map(
    (client) => EventCompleters(client.events),
  ).toList();

  print("Creating $threshold-of-$nParticipants key");

  final dkgStart = DateTime.now();

  await clients.first.requestDkg(
    NewDkgDetails(
      name: keyName,
      description: "This is an example key",
      threshold: threshold,
      expiry: Expiry(Duration(hours: 1)),
    ),
  );

  // Wait for others to receive the DKG and accept
  await Future.wait(
    clientCompleters.skip(1).map((completers) => completers.gotDkg.future),
  );
  await Future.wait(
    clients.skip(1).map((client) => client.acceptDkg(keyName)),
  );

  print("All clients accepted DKG, waiting for completion...");
  print("Please wait up-to 20 minutes...");

  final result = await Future.any([
    Future.wait(
      stores.map((store) => store.waitForKeyWithName(keyName, nParticipants)),
    ),
    Future.delayed(Duration(minutes: 20), () => null),
  ]);

  if (result == null) {
    print("DKG Failure. Took too long");
    exit(1);
  }

  final groupKey = stores.first.keys.values.first.keyInfo.group.groupKey;
  final derivedKeyInfo = HDGroupKeyInfo.master(
    groupKey: groupKey,
    threshold: threshold,
  ).derive(0).derive(0x7fffffff);

  final pubkey = cl.ECCompressedPublicKey.fromPubkey(groupKey);
  final derivedPubkey = derivedKeyInfo.groupKey;
  final dkgTime = DateTime.now().difference(dkgStart);

  print("\nGenerated key ${pubkey.hex}");
  print("HD Derived key ${derivedPubkey.hex}");
  print("DKG took $dkgTime\n");

  final taproot = cl.Taproot(internalKey: derivedPubkey);
  final address = cl.P2TRAddress.fromTaproot(
    taproot, hrp: cl.Network.testnet.bech32Hrp,
  );
  print("Testnet Taproot address: $address");
  print("Send exactly 10 tPPC to this address");

  final txid = getCommandLineString("What is the txid?");
  final outI = getCommandLineInt("What is output index?", 0, 0xffffffff);

  final program = cl.P2TR.fromTaproot(taproot);

  // Create unsigned tx

  final unsignedInput = cl.TaprootKeyInput(
    prevOut: cl.OutPoint.fromHex(txid, outI),
  );
  final unsignedTx = cl.Transaction(
    inputs: [unsignedInput],
    outputs: [
      cl.Output.fromProgram(
        // Gives 0.01 PPC as fee. Use CoinSelection to construct transactions
        // with proper fee handling and input selection.
        cl.CoinUnit.coin.toSats("9.99"),
        program,
      ),
    ],
  );

  final sigHash = cl.TaprootSignatureHasher(
    cl.TaprootSignDetails(
      tx: unsignedTx,
      inputN: 0,
      prevOuts: [cl.Output.fromProgram(cl.CoinUnit.coin.toSats("10"), program)],
      hashType: cl.SigHashType.schnorrDefault(),
      isScript: false,
    ),
  ).hash;

  // Sign signature hash

  final requestDetails = SignaturesRequestDetails(
    requiredSigs: [
      SingleSignatureDetails(
        signDetails: SignDetails.keySpend(message: sigHash),
        groupKey: pubkey,
        hdDerivation: [0, 0x7fffffff],
      ),
    ],
    expiry: Expiry(Duration(minutes: 3)),
    // In reality, the metadata of the transaction should be included so that
    // other participants can determine what is being signed.
  );

  await clients.first.requestSignatures(requestDetails);

  // Wait for others to receive and then accept
  await Future.wait(
    clientCompleters.skip(1).map((completers) => completers.gotSigsReq.future),
  );
  await Future.wait(
    clients.skip(1).map(
      (client) => client.acceptSignaturesRequest(requestDetails.id),
    ),
  );

  // Wait for signature
  final signature = await clientCompleters.first.signature.future;

  // Add signature and output signed transaction

  final finalTx = unsignedTx.replaceInput(
    unsignedInput.addSignature(cl.SchnorrInputSignature(signature)),
    0,
  );

  print("The hex of the completed transaction is provided below\n");
  print(finalTx.toHex());
  print("\nTransaction ID = ${finalTx.txid}\n");

  // Shutdown everything
  await Future.wait(clients.map((client) => client.logout()));
  server.shutdown();

  exit(0);

}
