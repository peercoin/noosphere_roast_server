import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'package:noosphere_roast_server/src/server/state/dkg.dart';
import 'package:noosphere_roast_server/src/server/state/signatures_coordination.dart';
import 'package:noosphere_roast_server/src/server/state/state.dart';
import 'package:test/test.dart';
import 'data.dart';
import 'helpers.dart';
import 'sig_data.dart';

class EventCollector<T> {

  static final Finalizer<StreamSubscription<Object>> _finalizer =
      Finalizer((sub) => sub.cancel());

  final List<Object> _events = [];
  final List<Object> _errors = [];
  late StreamSubscription<Object> subscription;

  EventCollector(Stream<Object> stream) {
    subscription = stream.listen(
      (e) => _events.add(e),
      onError: (Object e) => _errors.add(e),
    );
    _finalizer.attach(this, subscription);
  }

  void cancel() => subscription.cancel();

  Future<List<T2>> _getList<T2>(List<Object> Function() getter) async {
    await pumpEventQueue();
    final list = getter();
    final copy = list.toList();
    list.clear();
    return copy.cast<T2>();
  }

  Future<List<T>> getEvents() => _getList<T>(() => _events);
  Future<List<Object>> getErrors() => _getList<Object>(() => _errors);

  Future<E> getExpectOneEvent<E extends T>() async {
    final evs = await getEvents();
    expect(evs, hasLength(1));
    return evs.first as E;
  }

  Future<void> expectNoError() async {
    expect(await getErrors(), isEmpty);
  }

  Future<void> expectNoEvents() async {
    expect(await getEvents(), isEmpty);
  }

  Future<void> expectNoEventsOrError() async {
    await expectNoEvents();
    await expectNoError();
  }

  Future<void> expectError<E>() async {
    final errs = await getErrors();
    expect(errs.length, 1);
    expect(errs.first, isA<E>());
  }

  Future<void> expectOnlyOneEventType<ET>() async {
    expect(await getEvents(), everyElement(isA<ET>()));
    await expectNoError();
  }

}

typedef ClientEventCollector = EventCollector<ClientEvent>;

class ServerTestClient extends EventCollector<Event> {
  final LoginCompleteResponse loginResponse;
  ServerTestClient(this.loginResponse) : super(loginResponse.events);
  SessionID get sid => loginResponse.id;
}

class LoginRespMockApi extends ServerApiHandler {

  final List<SignaturesRequestEvent> sigRequests;
  final List<SignatureNewRoundsEvent> sigRounds;
  final List<CompletedSignaturesRequest> completedSigs;

  LoginRespMockApi({
    this.sigRequests = const [],
    this.sigRounds = const [],
    this.completedSigs = const [],
  }) : super(config: serverConfig);

  @override
  Future<LoginCompleteResponse> respondToChallenge(
    Signed<AuthChallenge> signedChallenge,
  ) async {
    final upstream = await super.respondToChallenge(signedChallenge);
    return LoginCompleteResponse(
      id: upstream.id,
      expiry: upstream.expiry,
      onlineParticipants: upstream.onlineParticipants,
      newDkgs: upstream.newDkgs,
      sigRequests: sigRequests,
      sigRounds: sigRounds,
      completedSigs: completedSigs,
      events: upstream.events,
    );
  }

}

/// Gives false DkgAck that wasn't requested
class MockUnrequestedAckApi extends ServerApiHandler {

  MockUnrequestedAckApi() : super(config: serverConfig);

  @override
  Future<Set<SignedDkgAck>> requestDkgAcks({
    required SessionID sid,
    required Set<DkgAckRequest> requests,
  }) async {
    final upstream = await super.requestDkgAcks(sid: sid, requests: requests);
    return {
      SignedDkgAck(
        signer: ids.last,
        signed: signObject(
          DkgAck(
            groupKey: cl.ECCompressedPublicKey.fromPubkey(getPrivkey(0).pubkey),
            accepted: false,
          ),
          9,
        ),
      ),
      ...upstream,
    };
  }

}

class MockPrematureSigsApi extends ServerApiHandler {

  MockPrematureSigsApi() : super(config: serverConfig);

  @override
  Future<SignaturesResponse?> submitSignatureReplies({
    required SessionID sid,
    required SignaturesRequestId reqId,
    required List<SignatureReply> replies,
  }) => Future.value(SignaturesCompleteResponse([dummySig]));

}

class TestContext {

  late final ServerApiHandler api;
  final List<ServerTestClient> clients = [];

  TestContext([ServerApiHandler? api]) {
    this.api = api ?? ServerApiHandler(config: serverConfig);
  }

  Future<ServerTestClient> login(int i) async {

    final response = await api.login(
      groupFingerprint: groupConfig.fingerprint,
      participantId: ids[i],
    );

    final client = ServerTestClient(
      await api.respondToChallenge(
        Signed.sign(obj: response.challenge, key: getPrivkey(i)),
      ),
    );

    clients.add(client);

    return client;

  }

  Future<List<ServerTestClient>> multiLogin(int n)
    => Future.wait(List.generate(n, (i) => login(i)));

  DkgState addDkg(Identifier creator, String name, { int threshold = 2 }) {
    return api.state.nameToDkg[name] = DkgState(
      details: signObject(getDkgDetails(name: name, threshold: threshold)),
      creator: creator,
      commitments: [],
    );
  }

  SignaturesCoordinationState addSigReq(
    Identifier creator,
    [ List<int> tweaks = const [0], ]
  ) {
    final signedDetails = signObject(
      getSignaturesDetails(singleSigTweaks: tweaks),
    );
    return api.state.sigRequests[signedDetails.obj.id]
      = SignaturesCoordinationState(
        details: signedDetails,
        creator: creator,
        keys: tweaks.map((t) => getAggregateKeyInfo(tweak: t)).toSet(),
      );
  }

  CompletedSignatures addCompletedSig(
    Set<Identifier> acks,
    int tweak,
  ) {
    final details = getSignaturesDetails(singleSigTweaks: [tweak]);
    final signedDetails = Signed.sign(obj: details, key: getPrivkey(0));
    final completed = api.state.completedSigs[details.id] = CompletedSignatures(
      details: signedDetails,
      // Dummy signature
      signatures: [cl.SchnorrSignature.sign(getPrivkey(0), Uint8List(32))],
      expiry: details.expiry,
      creator: ids.first,
    );
    completed.acks.addAll(acks);
    return completed;
  }

  DkgState addDkgRound1(Identifier creator, String name, List<int> whoCommit)
    => addDkg(creator, name)..round1.commitments.addAll(
      whoCommit.map((i) => (ids[i], getDkgPart1(i).public)).toList(),
    );

  DkgState addDkgRound2(
    Identifier creator, String name, [ Uint8List? expectedHash, ]
  ) => addDkg(creator, name)
    ..round = DkgRound2State(expectedHash: expectedHash ?? Uint8List(32));

  Future<void> clearEvents() async {
    for (final client in clients) {
      await client.getEvents();
    }
  }

  Future<void> expectNoEventsOrError() async {
    for (final client in clients) {
      await client.expectNoEventsOrError();
    }
  }

}

class TestClient {

  final Client client;
  final ClientEventCollector evCollector;
  final InMemoryClientStorage store;

  TestClient._(this.client, this.evCollector, this.store);

  static Future<TestClient> login(
    ApiRequestInterface api, int i, {
      InMemoryClientStorage? storage,
      void Function()? onDisconnect,
    }
  ) async {

    final store = storage ?? InMemoryClientStorage();
    final client = await Client.login(
      config: getClientConfig(i),
      api: api,
      store: store,
      getPrivateKey: (_) async => getPrivkey(i),
      onDisconnect: onDisconnect,
    );
    final evCollector = ClientEventCollector(client.events);

    return TestClient._(client, evCollector, store);

  }

  Future<void> logout() => client.logout();

  Future<void> expectOnlyLoginEvents()
    => evCollector.expectOnlyOneEventType<ParticipantStatusClientEvent>();

  Future<void> waitForNoSigsReqs()
    => waitFor(() => client.signaturesRequests.isEmpty);

}
