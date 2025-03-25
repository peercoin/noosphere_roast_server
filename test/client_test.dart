import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/internals.dart';
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'package:noosphere_roast_server/src/server/state/client_session.dart';
import 'package:noosphere_roast_server/src/server/state/dkg.dart';
import 'package:noosphere_roast_server/src/server/state/signatures_coordination.dart';
import 'package:noosphere_roast_server/src/server/state/state.dart';
import 'package:test/test.dart';
import 'context.dart';
import 'data.dart';
import 'helpers.dart';
import 'sig_data.dart';
import 'test_keys.dart';

void main() {
  group("Client", () {

    late final Identifier invalidId;
    late final Signed<NewDkgDetails> dkgDetails;
    late final List<DkgPart1> dummyPart1s;
    late final DkgCommitmentSet dummyCommitmentSet;
    setUpAll(() async {
      await loadFrosty();
      invalidId = badId;
      dkgDetails = signObject(getDkgDetails());
      dummyPart1s = List.generate(10, (i) => getDkgPart1(i));
      dummyCommitmentSet = DkgCommitmentSet(
        List.generate(10, (i) => (ids[i], dummyPart1s[i].public)),
      );
    });

    late TestContext ctx;
    setUp(() => ctx = TestContext());

    Future<void> expectMisbehaviour(void Function() f) => expectLater(
      f, throwsA(isA<ServerMisbehaviour>()),
    );

    final List<TestClient> clientsToLogout = [];
    tearDown(() async {
      for (final client in clientsToLogout) {
        await client.logout();
      }
      clientsToLogout.clear();
    });

    Future<TestClient> login(int i, [InMemoryClientStorage? storage]) async {
      final client = await TestClient.login(ctx.api, i, storage: storage);
      clientsToLogout.add(client);
      return client;
    }

    Future<List<TestClient>> loginMany(int n) => Future.wait(
      List.generate(n, (i) => login(i)),
    );

    void sendEventToClient(TestClient tc, Event ev) async {
      final clientState = ctx.api.state.clientSessions.values.firstWhere(
        (state) => state.participantId == tc.client.config.id,
      );
      clientState.sendEvent(ev);
    }

    Future<void> expectBadEvent(TestClient tc, Event ev) async {
      sendEventToClient(tc, ev);
      await tc.evCollector.expectNoEvents();
      await tc.evCollector.expectError<ServerMisbehaviour>();
    }

    void expectNoDkgs(Client client) {
      expect(client.dkgRequests, isEmpty);
      expect(client.acceptedDkgs, isEmpty);
    }

    DkgRound2ShareEvent getRound2ShareEvent(
      DkgCommitmentSet commitments, int sender, int receiver,
      DkgPart1 part1, Uint8List commonHash,
      { String? altName, }
    ) => DkgRound2ShareEvent(
      name: altName ?? "123",
      commitmentSetSignature: cl.SchnorrSignature.sign(
        getPrivkey(sender), commonHash,
      ),
      sender: ids[sender],
      secret: DkgEncryptedSecret.encrypt(
        secretShare: DkgPart2(
          identifier: ids[sender],
          round1Secret: part1.secret,
          commitments: commitments,
        ).sharesToGive[ids[receiver]]!,
        recipientKey: getPrivkey(receiver).pubkey,
        senderKey: getPrivkey(sender),
      ),
    );

    test("can login and keep track of online participants", () async {

      // Login 2 clients before creating Client object
      await ctx.multiLogin(2);

      // Create round 1 DKG
      ctx.addDkgRound1(ids.first, "round1", [0, 1]);

      // Create client
      final TestClient(:client, :evCollector) = await login(2);

      expect(client.onlineParticipants, {ids[0], ids[1]});

      // Expect round 1 DKG
      void expectRound1Dkg(Set<Identifier> commitmentIds) {
        expect(client.dkgRequests.length, 1);
        final dkgRequest = client.dkgRequests.first;
        expect(dkgRequest.creator, ids.first);
        expect(dkgRequest.completed, commitmentIds);
        expect(client.acceptedDkgs, isEmpty);
      }
      expectRound1Dkg({ids[0], ids[1]});

      // Login two more clients and expect an event

      await ctx.login(3);
      await ctx.login(4);

      final evs = await evCollector.getEvents();
      final loginEvs = evs.cast<ParticipantStatusClientEvent>();
      expect(loginEvs.map((e) => e.id).toSet(), {ids[3], ids[4]});
      expect(loginEvs.map((e) => e.loggedIn).toList(), [true, true]);

      expect(client.onlineParticipants, {ids[0], ids[1], ids[3], ids[4]});

      // Logout client
      ctx.api.state.clientSessions.values.firstWhere(
        (v) => v.participantId == ids[0],
      ).expiry = Expiry(Duration(minutes: -1));
      ctx.api.state.clientSessions.values; // Will expire

      {
        final evs = await evCollector.getEvents();
        expect(evs.length, 1);
        final loginEv = evs.first as ParticipantStatusClientEvent;
        expect(loginEv.id, ids[0]);
        expect(loginEv.loggedIn, false);
      }

      expect(client.onlineParticipants, {ids[1], ids[3], ids[4]});

      // Round 1 DKG loses commitment from logged out participant
      expectRound1Dkg({ids[1]});

    });

    test("logout old client object if re-login", () async {

      final logoutCompleter = Completer<bool>();
      await TestClient.login(
        ctx.api,
        0,
        onDisconnect: () => logoutCompleter.complete(true),
      );
      await TestClient.login(ctx.api, 0);
      expect(
        await Future.any([
          Future<bool>.delayed(Duration(seconds: 1), () => false),
          logoutCompleter.future,
        ]),
        true,
      );

    });

    test("handles multiple logouts immediately", () async {

      final tcs = await Future.wait(List.generate(6, (i) => login(i)));
      await tcs.first.expectOnlyLoginEvents();

      // 5 logout
      await Future.wait(tcs.skip(1).take(5).map((tc) => tc.logout()));

      final evs = await tcs.first.evCollector.getEvents();
      expect(evs, hasLength(5));
      expect(evs, everyElement(isA<ParticipantStatusClientEvent>()));

    });

    group("handles login misbehaviour", () {

      void expectLoginMisbehaviour() => expectMisbehaviour(
        () => Client.login(
          config: getClientConfig(0),
          api: ctx.api,
          store: InMemoryClientStorage(),
          getPrivateKey: (_) async => getPrivkey(0),
        ),
      );

      test("online participant not in config", () {
        final mockSessionId = SessionID();
        ctx.api.state.clientSessions[mockSessionId] = ClientSession(
          participantId: invalidId,
          sessionID: mockSessionId,
          expiry: Expiry(serverConfig.sessionTTL),
          onLostStream: () {},
        );
        expectLoginMisbehaviour();
      });

      test("no participant for DKG creator", () {
        ctx.addDkg(invalidId, "mock");
        expectLoginMisbehaviour();
      });

      test("invalid DKG participant num", () {
        ctx.addDkg(ids.first, "mock", threshold: 11);
        expectLoginMisbehaviour();
      });

      test("invalid DKG signature", () {
        ctx.api.state.nameToDkg["mock"] = DkgState(
          // Creator should be ids[0] so signature is wrong
          details: dkgDetails,
          creator: ids[1],
          commitments: [],
        );
        expectLoginMisbehaviour();
      });

      test("invalid participant in commitments", () {
        ctx.addDkg(ids.first, "mock").round1.commitments.add(
          (invalidId, getDkgPart1(0).public),
        );
        expectLoginMisbehaviour();
      });

      test("duplicate participant in commitments", () {
        ctx.addDkgRound1(ids.first, "mock", [0, 0]);
        expectLoginMisbehaviour();
      });

      test("duplicate DKG", () {
        ctx.api.state.nameToDkg["one"]
          = ctx.api.state.nameToDkg["two"]
          = DkgState(
            details: dkgDetails,
            creator: ids.first,
            commitments: [],
          );
        expectLoginMisbehaviour();
      });

      test("duplicate signatures request", () {
        final sigsDetails1 = getSignaturesDetails();
        final sigsDetails2 = getSignaturesDetails(
          singleSigTweaks: [1],
        );
        ctx.api.state.sigRequests[sigsDetails1.id]
          = ctx.api.state.sigRequests[sigsDetails2.id]
          = SignaturesCoordinationState(
            details: signObject(sigsDetails1),
            creator: ids.first,
            keys: {getAggregateKeyInfo()},
          );
        expectLoginMisbehaviour();
      });

    });

    test("does not receive events after logout", () async {
      final TestClient(:client, :evCollector) = await login(0);
      client.logout();
      await ctx.login(1);
      await evCollector.expectNoEventsOrError();
      clientsToLogout.clear();
    });

    test("handles incorrect participant login event", () async {

      final tc = await login(0);

      await expectBadEvent(
        tc,
        ParticipantStatusEvent(id: invalidId, loggedIn: true),
      );

      // Shouldn't receive for self
      await expectBadEvent(
        tc,
        ParticipantStatusEvent(id: ids.first, loggedIn: true),
      );

    });

    test("requestDkg success", () async {

      var tc1 = await login(0);
      var tc2 = await login(1);
      await tc1.expectOnlyLoginEvents();

      // Client 1 sends request, allowing n-of-n
      await tc1.client.requestDkg(getDkgDetails(threshold: 10));

      void expectProgress(
        DkgInProgress progress,
        [ Set<Identifier>? completed, ]
      ) {
        expect(progress.creator, ids.first);
        expect(progress.stage, DkgStage.round1);
        expect(progress.completed, completed ?? { ids.first });
        expect(progress.details.threshold, 10);
      }

      // Client 2 receives event
      await tc1.evCollector.expectNoEventsOrError();
      final evs = await tc2.evCollector.getEvents();
      expect(evs.length, 1);
      expectProgress((evs.first as UpdatedDkgClientEvent).progress);

      // Both clients have the DKG before and after relogin
      void expectDkg(Client client, bool accepted, bool firstAccepted) {
        final inList = accepted ? client.acceptedDkgs : client.dkgRequests;
        final outList = !accepted ? client.acceptedDkgs : client.dkgRequests;
        expect(inList.length, 1);
        expect(outList, isEmpty);
        expectProgress(inList.first, firstAccepted ? null : {});
      }

      expectDkg(tc1.client, true, true);
      expectDkg(tc2.client, false, true);

      await tc1.logout();
      await tc2.logout();
      tc1 = await login(0);
      tc2 = await login(1);

      // Both clients lose acceptance
      expectDkg(tc1.client, false, false);
      expectDkg(tc2.client, false, false);

    });

    test("requestDkg failure", () async {

      final TestClient(:client) = await login(0);

      final existingDetails = getDkgDetails(name: "exists");
      await client.requestDkg(existingDetails);

      Future<void> expectFail(NewDkgDetails details)
        => expectLater(
          () => client.requestDkg(details),
          throwsArgumentError,
        );

      for (final duration in [
        Duration(minutes: 29, seconds: 59),
        Duration(days: 7, seconds: 1),
      ]) {
        await expectFail(getDkgDetails(expiry: Expiry(duration)));
      }

      await expectFail(existingDetails);
      await expectFail(getDkgDetails(threshold: 11));

    });

    Future<void> expectNoRaceCondition(Future<void> Function() f) async {

      final futures = List.generate(20, (_) => f());

      int argumentErrors = 0;
      for (final future in futures) {
        try {
          await future;
        } on ArgumentError {
          argumentErrors++;
        }
      }
      expect(argumentErrors, 19);

    }

    test("requestDkg race condition", () async {
      // Try creating same DKG in quick succession.
      // Only one should succeed with the rest giving ArgumentError
      final TestClient(:client) = await login(0);
      expectNoRaceCondition(() => client.requestDkg(getDkgDetails()));
    });

    test("handles incorrect DKG request event", () async {

      final tc = await login(5);

      // Incorrect threshold
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: signObject(getDkgDetails(threshold: 11)),
          creator: ids.first,
          commitments: [],
        ),
      );

      // Incorrect signature
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: dkgDetails,
          creator: ids[1],
          commitments: [],
        ),
      );

      // Creator not in group
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: dkgDetails,
          creator: badId,
          commitments: [],
        ),
      );

      // Creator cannot be self
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: signObject(getDkgDetails(), 5),
          creator: ids[5],
          commitments: [],
        ),
      );

      // Commitment identifier not in group
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: dkgDetails,
          creator: ids.first,
          commitments: [(badId, getDkgPart1(0).public)],
        ),
      );

      // Expiry too far in past
      final dkgToChange = getDkgDetails(
        expiry: Expiry(Duration(minutes: -2, seconds: -1)),
      );
      await expectBadEvent(
        tc,
        NewDkgEvent(
          details: signObject(dkgToChange),
          creator: ids.first,
          commitments: [],
        ),
      );

    });

    test("DKG expiry is clamped", () async {

      final TestClient(:client, :evCollector) = await login(1);

      final reqExp = Expiry(Duration(days: 8));

      ctx.api.state.sendEventToAll(
        NewDkgEvent(
          details: signObject(getDkgDetails(expiry: reqExp)),
          creator: ids.first,
          commitments: [],
        ),
      );

      final ev = await evCollector.getExpectOneEvent<UpdatedDkgClientEvent>();

      // Expect details to be the same
      expect(ev.progress.details.expiry.time, reqExp.time);

      // Expect progress expiry to be clamped
      expect(
        ev.progress.expiry.ttl.compareTo(Duration(days: 7)),
        lessThanOrEqualTo(0),
      );

      // Event progress expiry same as from DKG request getter
      expect(
        ev.progress.expiry.time,
        client.dkgRequests.first.expiry.time,
      );

    });

    test("DKGs can be replaced with same name", () async {

      final tc = await login(5);

      final ev1 = NewDkgEvent(
        details: dkgDetails,
        creator: ids.first,
        commitments: [],
      );

      final ev2 = NewDkgEvent(
        details: signObject(getDkgDetails(), 1),
        creator: ids[1],
        commitments: [],
      );

      ctx.api.state.sendEventToAll(ev1);
      await tc.evCollector.getExpectOneEvent<UpdatedDkgClientEvent>();

      ctx.api.state.sendEventToAll(ev2);
      final ev = await tc.evCollector
        .getExpectOneEvent<UpdatedDkgClientEvent>();
      expect(ev.progress.details.name, "123");
      expect(ev.progress.creator, ids[1]);
      expect(tc.client.dkgRequests, hasLength(1));
      expect(tc.client.dkgRequests.first.creator, ids[1]);

    });

    test("ignore DKG that doesn't exist", () async {
      final TestClient(:client) = await login(0);
      await client.rejectDkg("noexist");
      await client.acceptDkg("noexist");
    });

    test("DKGs can be rejected", () async {

      final TestClient(client: client1, evCollector: evCollector1)
        = await login(0);
      final TestClient(client: client2, evCollector: evCollector2)
        = await login(1);

      // Client 1 add DKG
      await client1.requestDkg(getDkgDetails());

      // Clear events
      await evCollector1.getEvents();
      await evCollector2.getEvents();

      // Client 2 reject DKG
      await client2.rejectDkg("123");

      // Client 1 only receives event
      await evCollector2.expectNoEventsOrError();
      final ev = await evCollector1.getExpectOneEvent<RejectedDkgClientEvent>();
      expect(ev.participant, ids[1]);
      expect(ev.details.name, "123");
      expect(ev.fault, DkgFault.none);

      // No DKG for both clients
      expect(client1.dkgRequests, isEmpty);
      expect(client2.dkgRequests, isEmpty);

    });

    test("handles incorrect DKG rejection event", () async {

      final tc = await login(0);

      // Participant doesn't exist, or is self
      for (final badId in [badId, ids.first]) {
        await expectBadEvent(
          tc,
          DkgRejectEvent(name: "123", participant: badId),
        );
      }

    });

    test("Non-existant DKG ignored", () async {

      final TestClient(:evCollector) = await login(0);

      ctx.api.state.sendEventToAll(
        DkgRejectEvent(name: "noexist", participant: ids.last),
      );

      ctx.api.state.sendEventToAll(
        DkgCommitmentEvent(
          name: "noexist",
          participant: ids.last,
          commitment: getDkgPart1(0).public,
        ),
      );

      ctx.api.state.sendEventToAll(
        getRound2ShareEvent(
          dummyCommitmentSet, 1, 0, dummyPart1s[1],
          Uint8List(32),
          altName: "noexist",
        ),
      );

      await evCollector.expectNoEventsOrError();

    });

    test("can create FROST keys", () async {

      // Create 10 clients
      final tcs = await loginMany(10);
      for (final tc in tcs) {
        await tc.expectOnlyLoginEvents();
      }

      // Client 0 requests DKG
      await tcs.first.client.requestDkg(getDkgDetails());
      await tcs.first.evCollector.expectNoEventsOrError();
      for (final tc in tcs.skip(1)) {
        expect(await tc.evCollector.getEvents(), hasLength(1));
      }

      // Client 1-9 accepts DKG
      for (final tc in tcs.skip(1)) {
        await tc.client.acceptDkg("123");
      }

      // Wait for completion
      for (final tc in tcs) {
        await tc.store.waitForKeyWithName("123", 10);
      }

      // Expect progress events and then completion event
      for (int i = 0; i < 10; i++) {

        final cid = ids[i];
        final evCollector = tcs[i].evCollector;
        await evCollector.expectNoError();
        final evs = await evCollector.getEvents();

        // Creator should get 9 commitments
        // Others should get 8 commitments as they already have the creator
        // commitment
        final isCreator = i == 0;
        final nCommitments = isCreator ? 9 : 8;

        // Expect +8 events for shares
        expect(evs, hasLength(nCommitments + 8));

        // Commitment events
        for (int j = 0; j < nCommitments; j++) {

          final ev = evs[j] as UpdatedDkgClientEvent;
          final finished = j == nCommitments-1;
          final completed = ev.progress.completed;

          // Apart from creator and first acceptor, participants may or may not
          // have accepted yet and may not have own commitment
          final hasOwnCommitment = completed.contains(cid);
          final round2 = finished && hasOwnCommitment;

          expect(
            ev.progress.stage,
            round2 ? DkgStage.round2 : DkgStage.round1,
          );

          expect(
            completed,
            hasLength(
              // If round 2, then have just own share
              // If round 1, then have received commitments, plus creator, plus
              // own
              round2 ? 1 : j+1+(isCreator ? 0 : 1)+(hasOwnCommitment ? 1 : 0),
            ),
          );

          if (!round2) expect(completed, contains(ids.first));

        }

        // Expect 8 update events from shares
        // Do not expect update event for final share as addNewFrostKey is
        // called

        for (int j = 0; j < 8; j++) {
          final ev = evs[nCommitments+j] as UpdatedDkgClientEvent;
          final completed = ev.progress.completed;
          expect(ev.progress.stage, DkgStage.round2);
          expect(completed, hasLength(j+2));
          expect(completed, contains(cid));
        }

      }

      // Expect key in storage
      final keys = tcs.map((tc) => tc.store.keys.values.first).toList();
      expect(keys.toSet(), hasLength(1));
      for (final key in keys) {
        expect(key.name, "123");
        expect(key.acks.map((ack) => ack.signer).toSet(), ids.toSet());
        expect(key.groupKey, keys.first.groupKey);
      }

      // DKG no longer exists
      for (final tc in tcs) {
        expectNoDkgs(tc.client);
      }

    });

    test("cannot accept DKG twice", () async {

      final client1 = (await login(0)).client;
      final client2 = (await login(1)).client;

      await client1.requestDkg(getDkgDetails());
      await client2.acceptDkg("123");

      for (final client in [client1, client2]) {
        expectLater(() => client.acceptDkg("123"), throwsArgumentError);
      }

    });

    test("handles incorrect DkgCommitmentEvent", () async {

      final tc = await login(0);
      await tc.client.requestDkg(getDkgDetails());

      // Invalid identifier
      {
        await expectBadEvent(
          tc,
          DkgCommitmentEvent(
            name: "123",
            participant: badId,
            commitment: getDkgPart1(1).public,
          ),
        );
      }

      // Duplicate identifier
      for (int i = 0; i < 2; i++) {
        ctx.api.state.sendEventToAll(
          DkgCommitmentEvent(
            name: "123",
            participant: ids[1],
            commitment: getDkgPart1(1).public,
          ),
        );
      }

      await tc.evCollector.getExpectOneEvent<UpdatedDkgClientEvent>();
      await tc.evCollector.expectError<ServerMisbehaviour>();

    });

    test("handles round 2 share given on round 1", () async {
      final tc = await login(0);
      await tc.client.requestDkg(getDkgDetails());
      await expectBadEvent(
        tc,
        getRound2ShareEvent(
          dummyCommitmentSet, 1, 0, dummyPart1s[1], Uint8List(32),
        ),
      );
    });

    test("handles receiving own identifier for commitment", () async {
      await expectBadEvent(
        await login(0),
        DkgCommitmentEvent(
          name: "123",
          participant: ids.first,
          commitment: getDkgPart1(0).public,
        ),
      );
    });

    test("handles invalid proof-of-knowledge", () async {

      final TestClient(:client, :evCollector) = await login(0);
      await client.requestDkg(getDkgDetails());

      // Give wrong commitment for i = 4
      for (int i = 1; i < 10; i++) {
        ctx.api.state.sendEventToAll(
          DkgCommitmentEvent(
            name: "123",
            participant: ids[i],
            commitment: getDkgPart1(i == 4 ? 0 : i).public,
          ),
        );
      }

      final evs = await evCollector.getEvents();
      expect(evs, hasLength(9));
      expect(evs.take(8).any((e) => e is! UpdatedDkgClientEvent), false);

      final rejectEv = evs.last as RejectedDkgClientEvent;
      expect(rejectEv.details.name, "123");
      expect(rejectEv.participant, ids[4]);
      expect(rejectEv.fault, DkgFault.proofOfKnowledge);

      await evCollector.expectNoError();

    });

    test("remove DKG upon expiry", () async {

      final tc = await login(0);
      final state = getHiddenClientStateForTestsDoNotUse(tc.client);

      state.nameToDkg["toexpire"] = ClientDkgState(
        details: getDkgDetails(name: "toexpire"),
        creator: ids.first,
        expiry: Expiry(Duration(seconds: -1)),
      );

      // Should get failure event due to expiry
      final ev = await tc.evCollector.getExpectOneEvent<RejectedDkgClientEvent>();
      expect(ev.participant, null);
      expect(ev.details.name, "toexpire");
      expect(ev.fault, DkgFault.expired);

      // No DKGs should exist
      expect(tc.client.dkgRequests, isEmpty);

    });

    group("given a round 2 DKG", () {

      late TestClient tc;
      late List<DkgPart1> part1s;
      late DkgCommitmentSet commitmentSet;
      late Uint8List commonHash;

      setUp(() async {

        tc = await login(9);
        await tc.client.requestDkg(dkgDetails.obj);

        part1s = List.generate(9, (i) => getDkgPart1(i));

        // Obtain part1 commitment for requestor so commitment set can be known
        commitmentSet = DkgCommitmentSet([
          ...List.generate(9, (i) => (ids[i], part1s[i].public)),
          ctx.api.state.round1Dkgs.first.round1.commitments.first,
        ]);

        commonHash = dkgDetails.obj.hashWithCommitments(commitmentSet);

        // Accept DKGs for other participants but do not create Client for them
        // to hold on round 2
        await ctx.multiLogin(9);
        for (int i = 0; i < 9; i++) {
          await ctx.api.submitDkgCommitment(
            sid: ctx.clients[i].sid,
            name: "123",
            commitment: part1s[i].public,
          );
        }

        // Flush events we do not care about
        await tc.evCollector.getEvents();

      });

      test(
        "handles DkgCommitmentEvent on round 2",
        () => expectBadEvent(
          tc,
          DkgCommitmentEvent(
            name: "123",
            participant: ids.first,
            commitment: getDkgPart1(0).public,
          ),
        ),
      );

      test(
        "handles bad commitment set signature",
        () => expectBadEvent(
          tc,
          getRound2ShareEvent(commitmentSet, 0, 9, part1s.first, Uint8List(32)),
        ),
      );

      Future<void> expectDkgRejectionOnEvent(
        Event sendEv, DkgFault fault, [bool hasCulprit = true,]
      ) async {

        ctx.api.state.sendEventToAll(sendEv);

        final ev = await tc.evCollector
          .getExpectOneEvent<RejectedDkgClientEvent>();
        expect(ev.participant, hasCulprit ? ids.first : null);
        expect(ev.details.name, "123");
        expect(ev.fault, fault);

        expectNoDkgs(tc.client);

      }

      test(
        "handles rejection on round 2",
        () => expectDkgRejectionOnEvent(
          DkgRejectEvent(name: "123", participant: ids.first),
          DkgFault.none,
        ),
      );

      test("handles logout causing DKG to return to round 1", () async {

        ctx.api.state.sendEventToAll(
          ParticipantStatusEvent(id: ids.first, loggedIn: false),
        );

        await tc.evCollector.getExpectOneEvent<ParticipantStatusClientEvent>();

        expect(tc.client.acceptedDkgs, isEmpty);
        expect(tc.client.dkgRequests, hasLength(1));
        expect(tc.client.dkgRequests.first.completed, isEmpty);

      });

      test(
        "handles incorrect secret ciphertext",
        () => expectDkgRejectionOnEvent(
          getRound2ShareEvent(commitmentSet, 0, 1, part1s.first, commonHash),
          DkgFault.secretCiphertext,
        ),
      );

      test(
        "handles invalid secret",
        () async {

          // Send in bad secret
          ctx.api.state.sendEventToAll(
            getRound2ShareEvent(commitmentSet, 0, 9, part1s[1], commonHash),
          );

          // Send in all but one good secrets
          for (int i = 1; i < 8; i++) {
            ctx.api.state.sendEventToAll(
              getRound2ShareEvent(commitmentSet, i, 9, part1s[i], commonHash),
            );
          }

          final evs = await tc.evCollector.getEvents();
          expect(evs, hasLength(8));
          expect(evs.any((e) => e is! UpdatedDkgClientEvent), false);

          // Rejection happens on final event
          await expectDkgRejectionOnEvent(
            getRound2ShareEvent(commitmentSet, 8, 9, part1s[8], commonHash),
            DkgFault.secret,
            false,
          );

        }
      );

      test("handles duplicate secret share", () async {
        final ev = getRound2ShareEvent(
          commitmentSet, 1, 9, part1s[1], commonHash,
        );
        ctx.api.state.sendEventToAll(ev);
        await tc.evCollector.expectOnlyOneEventType<UpdatedDkgClientEvent>();
        await expectBadEvent(tc, ev);
      });

    });

    Future<TestClient> loginWithOwnAck(
      int i, [ Set<SignedDkgAck> otherAcks = const {}, ]
    ) => login(i, storeWithKeyAndAcks(i, { getDkgAck(i, true), ...otherAcks }));

    test("ask and receive DKGs on logins", () async {

      final acks = List.generate(10, (i) => getDkgAck(i, true));

      // Give 4 acks to server
      final ackCache = ctx.api.state.dkgAckCache[groupPublicKey]
        = DkgAckCache(Expiry(Duration(days: 1)));

      for (int i = 0; i < 4; i++) {
        ackCache.acks[ids[i]] = acks[i].signed;
      }

      // Give 2 of the same acks and 2 different to client
      final tc1 = await loginWithOwnAck(0, { acks[1], acks[4], acks[5] },);

      // Receive 2 of them from server so it now has first 6
      await tc1.store.waitForKeyWithName("123", 6);

      // Give 2 acks shared with server to new client
      // Plus 2 acks shared with client
      // Plus 2 others
      final tc2 = await loginWithOwnAck(
        1,
        { acks[2], acks[5], acks[6], acks[7], },
      );

      // Client 1 should receive 2 others
      await tc1.store.waitForKeyWithName("123", 8);

      // Client 2 should receive server ACKs plus ACKs from client 1
      await tc1.store.waitForKeyWithName("123", 8);

      // Login everyone and ensure everyone has all ACKs
      final tcs = [tc1, tc2];
      for (int i = 2; i < 10; i++) {
        tcs.add(await loginWithOwnAck(i));
      }

      for (final tc in tcs) {
        await tc.store.waitForKeyWithName("123", 10);
        await tc.expectOnlyLoginEvents();
      }

    });

    test("gives negative ACK without key", () async {

      Future<void> expectAcks(
        TestClient tc, List<(int, bool)> expected,
      ) async {
        await waitFor(
          () => tc.store.keys.values.first.acks.length == expected.length,
        );
        final actual = tc.store.keys.values.first.acks;
        expect(actual, hasLength(expected.length));
        for (final (expI, expAccepted) in expected) {
          expect(
            actual.firstWhere((ack) => ack.signer == ids[expI]).signed.obj.accepted,
            expAccepted,
          );
        }
      }

      // Login client 1 with positive ACK
      final tc1 = await loginWithOwnAck(0);

      // Login client 2 that provides NACK for third client
      final tc2 = await loginWithOwnAck(1, { getDkgAck(2, false) });

      // Client 1 & 2 should now have client 1 and 2 ACK and id 3 NACK
      final expAcks = [(0, true), (1, true), (2, false)];
      for (final tc in [tc1, tc2]) {
        await expectAcks(tc, expAcks);
      }

      // Login client 3 without key, NACK is already given
      final tc3 = await login(2);

      // Login client 4 without key
      final tc4 = await login(3);

      // Expect NACK given to client 1 and 2
      expAcks.add((3, false));
      for (final tc in [tc1, tc2]) {
        await expectAcks(tc, expAcks);
      }

      // Login client 5 with key
      final tc5 = await loginWithOwnAck(4);

      // Expect ACKs and NACKs given to everyone
      expAcks.add((4, true));
      for (final tc in [tc1, tc2, tc5]) {
        await expectAcks(tc, expAcks);
      }

      for (final tc in [tc1, tc2, tc3, tc4, tc5]) {
        await tc.expectOnlyLoginEvents();
      }

    });

    test("handles bad DkgAckEvent", () async {

      final tc = await loginWithOwnAck(0);
      final ackWithId = getDkgAck(0, true);
      final ack1 = ackWithId.signed;

      // Bad identifier
      await expectBadEvent(
        tc,
        DkgAckEvent(
          { SignedDkgAck(signer: badId, signed: ack1) },
        ),
      );

      // Wrong identifier, bad signature
      await expectBadEvent(
        tc,
        DkgAckEvent({ SignedDkgAck(signer: ids[1], signed: ack1) }),
      );

      // Can't be self
      await expectBadEvent(tc, DkgAckEvent({ ackWithId }));

    });

    test("handles bad DkgAckRequestEvent", () async {
      // Bad requested ID
      await expectBadEvent(
        await loginWithOwnAck(0),
        DkgAckRequestEvent(
          { DkgAckRequest(ids: {badId}, groupPublicKey: groupPublicKey) },
        ),
      );
    });

    test("handles unrequested ACK", () async {
      final tc = await TestClient.login(
        MockUnrequestedAckApi(),
        0,
        storage: storeWithKeyAndAcks(0, { getDkgAck(0, true) }),
      );
      await tc.evCollector.expectError<ServerMisbehaviour>();
    });

    group("given all clients with 3-threshold key", () {

      late SignaturesRequestDetails reqDetails;
      // Assign with 3-of-10 and 6-of-10
      late List<List<ParticipantKeyInfo>> infosForKeys;
      late List<cl.ECCompressedPublicKey> groupKeys;
      late List<InMemoryClientStorage> stores;
      late List<TestClient> tcs;
      late SignaturesRequestId missingReqId;

      Future<void> loginAll() async {
        tcs = await Future.wait(List.generate(10, (i) => login(i, stores[i])));
        for (final tc in tcs) {
          await tc.expectOnlyLoginEvents();
        }
      }

      Future<void> reloginAll() async {
        for (final tc in tcs) {
          await tc.logout();
        }
        await loginAll();
      }

      SignaturesRequestDetails getSigDetailsWithKeys(
        {
          Expiry? expiry,
          List<cl.ECCompressedPublicKey>? keys,
        }
      ) => SignaturesRequestDetails.allowNegativeExpiry(
        requiredSigs: (keys ?? groupKeys).map(
          (key) => SingleSignatureDetails(
            signDetails: getSignDetails(0),
            groupKey: key,
            hdDerivation: [0],
          ),
        ).toList(),
        expiry: expiry ?? futureExpiry,
      );

      setUp(() async {

        infosForKeys = [generateNewKey(3), generateNewKey(6)];
        groupKeys = infosForKeys.map(
          (keyInfos) => keyInfos.first.groupKey,
        ).toList();
        stores = List.generate(
          10,
          (i) {
            final store = InMemoryClientStorage();

            for (final j in [0,1]) {
              store.addNewFrostKey(
                FrostKeyWithDetails(
                  keyInfo: infosForKeys[j][i],
                  name: j == 0 ? "3-of-10" : "6-of-10",
                  description: "",
                  acks: {},
                ),
              );
            }

            return store;
          },
        );

        reqDetails = getSigDetailsWithKeys();
        missingReqId = SignaturesRequestId.fromBytes(Uint8List(16));

        await loginAll();

      });

      test("requestSignatures success", () async {

        // First client creates request
        await tcs.first.client.requestSignatures(reqDetails);

        void expectRequest(
          SignaturesRequest request,
          SignaturesRequestStatus status,
        ) {
          expect(request.creator, ids.first);
          expect(request.expiry, futureExpiry);
          expect(request.details.expiry, futureExpiry);
          expect(request.details.id, reqDetails.id);
          expect(request.status, status);
        }

        // Other clients receive event
        await tcs.first.evCollector.expectNoEventsOrError();
        for (final tc in tcs.skip(1)) {
          final ev = await tc.evCollector
            .getExpectOneEvent<SignaturesRequestClientEvent>();
          expectRequest(ev.request, SignaturesRequestStatus.waiting);
        }

        void expectHasRequests() {
          void expectRequests(TestClient tc, SignaturesRequestStatus status) {
            final reqs = tc.client.signaturesRequests;
            expect(reqs, hasLength(1));
            expectRequest(reqs.first, status);
          }
          expectRequests(tcs.first, SignaturesRequestStatus.accepted);
          for (final tc in tcs.skip(1)) {
            expectRequests(tc, SignaturesRequestStatus.waiting);
          }
        }

        // Everyone has request
        expectHasRequests();

        // Everyone has request after logout and login
        await reloginAll();
        expectHasRequests();

        // Nonces exist in storage
        expect(stores.first.sigNonces, contains(reqDetails.id));

      });

      test("requestSignatures failure", () async {

        // Already existing request
        await tcs.first.client.requestSignatures(reqDetails);

        Future<void> expectFail(SignaturesRequestDetails details)
          => expectLater(
            () => tcs.first.client.requestSignatures(details),
            throwsArgumentError,
          );

        // Bad expiry
        for (final duration in [
          Duration(seconds: 29),
          Duration(days: 14, seconds: 1),
        ]) {
          await expectFail(getSigDetailsWithKeys(expiry: Expiry(duration)));
        }

        // Already exists
        await expectFail(reqDetails);

        // Non-existant key using details without stored key
        await expectFail(getSignaturesDetails());

      });

      test(
        "requestSignatures race condition",
        () => expectNoRaceCondition(
          () => tcs.first.client.requestSignatures(reqDetails),
        ),
      );

      test("handles incorrect signatures request event", () async {

        Future<void> expectBadSigReqEv(
          Signed<SignaturesRequestDetails> details,
          Identifier id,
        ) => expectBadEvent(
          tcs.first,
          SignaturesRequestEvent(
            details: details,
            creator: id,
          ),
        );

        // Incorrect signature
        await expectBadSigReqEv(signObject(reqDetails, 2), ids[1]);

        // Creator not in group
        await expectBadSigReqEv(signObject(reqDetails), badId);

        // Creator cannot be self
        await expectBadSigReqEv(signObject(reqDetails), ids.first);

        // Expiry too far in past
        await expectBadSigReqEv(
          signObject(
            getSigDetailsWithKeys(
              expiry: Expiry(Duration(minutes: -2, seconds: -1)),
            ),
            1,
          ),
          ids[1],
        );

        // Cannot receive signatures request we already have
        final ev = SignaturesRequestEvent(
          details: signObject(reqDetails, 1),
          creator: ids[1],
        );
        ctx.api.state.sendEventToAll(ev);
        await tcs.first.evCollector.expectOnlyOneEventType<
          SignaturesRequestClientEvent
        >();
        await expectBadEvent(tcs.first, ev);

      });

      test("signatures request expiry is clamped", () async {

        final reqExp = Expiry(Duration(days: 15));
        final details = getSigDetailsWithKeys(expiry: reqExp);

        ctx.api.state.sendEventToAll(
          SignaturesRequestEvent(
            details: signObject(details, 1),
            creator: ids[1],
          ),
        );

        final ev = await tcs.first.evCollector
          .getExpectOneEvent<SignaturesRequestClientEvent>();

        // Details are the same
        expect(ev.request.details.id, details.id);

        // Request expiry is clamped
        expect(
          ev.request.expiry.ttl.compareTo(Duration(days: 14)),
          lessThanOrEqualTo(0),
        );
        expect(
          ev.request.expiry.time,
          tcs.first.client.signaturesRequests.first.expiry.time,
        );

      });

      test("signatures request auto rejected for missing keys", () async {

        // Give first client a key that others do not have
        final otherKey = generateNewKey(3).first;
        await tcs.first.store.addNewFrostKey(
          FrostKeyWithDetails(
            keyInfo: otherKey,
            name: "other key",
            description: "",
            acks: {},
          ),
        );

        // Refresh store cache by login/logout
        await reloginAll();

        // 6 logout
        for (final tc in tcs.skip(1).take(6)) {
          await tc.logout();
        }
        await tcs.first.expectOnlyLoginEvents();

        // First client makes signature request with other key
        final sigDetails = getSigDetailsWithKeys(
          keys: [...groupKeys, otherKey.groupKey],
        );
        await tcs.first.client.requestSignatures(sigDetails);

        // 3 other logged in clients reject immediately
        final state = ctx.api.state.sigRequests.values.first;
        expect(state.rejectors, hasLength(3));

        // Log in one of the other clients and receive another rejection
        await login(1, stores[1]);
        expect(state.rejectors, hasLength(4));

        // One other login and the threshold of failure is attained
        await login(2, stores[2]);

        expect(ctx.api.state.sigRequests.values, isEmpty);

        final evs = await tcs.first.evCollector.getEvents();
        expect(evs, hasLength(3));
        expect(evs.take(2), everyElement(isA<ParticipantStatusClientEvent>()));
        final ev = evs.last as SignaturesFailureClientEvent;
        expect(ev.request.details.id, sigDetails.id);

      });

      test("ignore signatures request that doesn't exist", () async {
        await tcs.first.client.rejectSignaturesRequest(missingReqId);
        await tcs.first.client.acceptSignaturesRequest(missingReqId);
      });

      test("remove signatures request upon expiry", () async {

        final state = getHiddenClientStateForTestsDoNotUse(tcs.first.client);
        state.sigRequests[reqDetails.id] = ClientSigsState(
          details: reqDetails,
          creator: ids.first,
          expiry: Expiry(Duration(seconds: -1)),
        );

        // Should get an expiry event
        final ev = await tcs.first.evCollector
          .getExpectOneEvent<SignaturesExpiryClientEvent>();
        expect(ev.request.details.id, reqDetails.id);

        // No requests should exist
        expect(tcs.first.client.signaturesRequests, isEmpty);

      });

      test("handles premature completed signatures", () async {

        final mockServ = MockPrematureSigsApi();
        final newTcs = await Future.wait(
          List.generate(
            2,
            (i) => TestClient.login(mockServ, i, storage: tcs[i].store),
          ),
        );

        await newTcs.last.client.requestSignatures(reqDetails);
        await waitFor(() => newTcs.first.client.signaturesRequests.isNotEmpty);

        await expectMisbehaviour(
          () => newTcs.first.client.acceptSignaturesRequest(reqDetails.id),
        );

      });

      group("given signature request", () {

        late SigningCommitment firstCommitment;
        late SignatureRoundStart validRound;
        late SignaturesCoordinationState sigState;
        late cl.SchnorrSignature validFirstSig;
        late List<SignatureNewRoundsEvent> badNewRounds;

        setUp(() async {

          await tcs.first.client.requestSignatures(reqDetails);
          sigState = ctx.api.state.sigRequests.values.first;

          for (final tc in tcs.skip(1)) {
            await waitFor(() => tc.client.signaturesRequests.isNotEmpty);
            await tc.evCollector.getEvents();
          }

          firstCommitment = (
            sigState.sigs.first as SingleSignatureInProgressState
          ).nextCommitments[ids.first]!;

          validRound = SignatureRoundStart(
            sigI: 0,
            commitments: SigningCommitmentSet({
              ids.first: firstCommitment,
              for (final id in ids.skip(1).take(2))
                id: getSignPart1().commitment,
            }),
          );

          // Get a valid signature for the first requested signature
          final part1s = List.generate(3, (i) => getSignPart1());
          final commitments = SigningCommitmentSet({
            for (int i = 0; i < 3; i++)
              ids[i]: part1s[i].commitment,
          });
          final sigDetails = reqDetails.requiredSigs.first;
          final shares = List.generate(
            3,
            (i) => SignPart2(
              identifier: ids[i],
              details: sigDetails.signDetails,
              ourNonces: part1s[i].nonces,
              commitments: commitments,
              info: sigDetails.derive(
                HDParticipantKeyInfo.masterFromInfo(infosForKeys.first[i]),
              ).signing,
            ),
          );
          validFirstSig = SignatureAggregation(
            commitments: commitments,
            details: reqDetails.requiredSigs.first.signDetails,
            shares: [for (int i = 0; i < 3; i++) (ids[i], shares[i].share)],
            info: sigDetails.derive(
              HDAggregateKeyInfo.masterFromInfo(
                infosForKeys.first.first.aggregate,
              ),
            ) as AggregateKeyInfo,
          ).signature;

          badNewRounds = [

            for (final multiRounds in [
              // Empty rounds
              <SignatureRoundStart>[],
              // Duplicate round
              [validRound, validRound],
            ]) SignatureNewRoundsEvent(
              reqId: reqDetails.id,
              rounds: multiRounds,
            ),

            for (final singleRound in [
              // Incorrect number of commitments
              SignatureRoundStart(
                sigI: 0,
                commitments: SigningCommitmentSet({ ids.first: firstCommitment }),
              ),
              // Doesn't contain participant
              SignatureRoundStart(
                sigI: 0,
                commitments: SigningCommitmentSet({
                  for (final id in ids.skip(1).take(3))
                    id: getSignPart1().commitment,
                }),
              ),
              // Invalid identifier for commitment
              SignatureRoundStart(
                sigI: 0,
                commitments: SigningCommitmentSet({
                  ids.first: firstCommitment,
                  ids[1]: getSignPart1().commitment,
                  Identifier.fromUint16(11): getSignPart1().commitment,
                }),
              ),
            ]) SignatureNewRoundsEvent(
              reqId: reqDetails.id,
              rounds: [singleRound],
            ),

            // Signature out of range
            for (final badI in [2, -1]) SignatureNewRoundsEvent(
              reqId: reqDetails.id,
              rounds: [
                SignatureRoundStart(
                  sigI: badI, commitments: validRound.commitments,
                ),
              ],
            ),

          ];

        });

        test("invalid login sigRounds", () async {

          final signedDetails = signObject(reqDetails);
          final validEv = SignatureNewRoundsEvent(
            reqId: reqDetails.id,
            rounds: [validRound],
          );

          for (final badSigRounds in [
            ...badNewRounds.map((nre) => [nre]),
            // Missing request
            [SignatureNewRoundsEvent(reqId: missingReqId, rounds: [validRound])],
            // Duplicate request
            [validEv, validEv],
          ]) {
            await tcs.first.logout();
            ctx = TestContext(
              LoginRespMockApi(
                sigRequests: [
                  SignaturesRequestEvent(
                    details: signedDetails,
                    creator: ids.first,
                  ),
                ],
                sigRounds: badSigRounds,
              ),
            );
            await expectMisbehaviour(() => login(0, stores.first));
          }

        });

        test("invalid login completedSigs", () async {

          // Create new request requiring only one 3-of-3 sig
          final singleReq = getSigDetailsWithKeys(
            keys: groupKeys.take(1).toList(),
          );

          await tcs.first.logout();

          for (final completedSig in [
            // Invalid signature for details
            CompletedSignaturesRequest(
              details: signObject(singleReq, 1),
              signatures: [validFirstSig],
              creator: ids.first,
            ),
            // Invalid signature
            CompletedSignaturesRequest(
              details: signObject(singleReq),
              signatures: [dummySig],
              creator: ids.first,
            ),
            // Incorrect number of signatures for request requiring 2
            CompletedSignaturesRequest(
              details: signObject(reqDetails),
              signatures: [validFirstSig],
              creator: ids.first,
            ),
          ]) {
            ctx = TestContext(LoginRespMockApi(completedSigs: [completedSig]));
            await expectMisbehaviour(() => login(0, stores.first));
          }

          // Check that the validFirstSig does pass for correct request
          ctx = TestContext(
            LoginRespMockApi(
              completedSigs: [
                CompletedSignaturesRequest(
                  details: signObject(singleReq),
                  signatures: [validFirstSig],
                  creator: ids.first,
                ),
              ],
            ),
          );

          await login(0, stores.first);

        });

        void expectStatus(TestClient tc, SignaturesRequestStatus status)
          => expect(tc.client.signaturesRequests.first.status, status);

        void expectRejectors(Set<Identifier> ids) => expect(
          sigState.rejectors, ids,
        );

        test("signature requests can be rejected", () async {

          // 1-4 reject, leaving 0 and 5-9 able to sign
          for (final tc in tcs.skip(1).take(4)) {
            await tc.client.rejectSignaturesRequest(reqDetails.id);
            expectStatus(tc, SignaturesRequestStatus.rejected);
          }

          // Still rejected state after login again
          await reloginAll();

          expectStatus(tcs.first, SignaturesRequestStatus.accepted);
          for (final tc in tcs.skip(1).take(4)) {
            expectStatus(tc, SignaturesRequestStatus.rejected);
          }
          for (final tc in tcs.skip(5)) {
            expectStatus(tc, SignaturesRequestStatus.waiting);
          }

          expectRejectors(ids.skip(1).take(4).toSet());

          // Creator can reject causing failure
          tcs.first.client.rejectSignaturesRequest(reqDetails.id);

          // Everyone gets failure event and signature request is removed
          for (final tc in tcs) {
            final ev = await tc.evCollector
              .getExpectOneEvent<SignaturesFailureClientEvent>();
            expect(ev.request.details.id, reqDetails.id);
            expect(tc.client.signaturesRequests, isEmpty);
            expect(tc.store.sigsRejected, isEmpty);
            expect(tc.store.sigNonces, isEmpty);
          }

          expect(ctx.api.state.sigRequests.values, isEmpty);

        });

        test("ignore SignatureNewRoundsEvent for missing request", () async {
          ctx.api.state.sendEventToAll(
            SignatureNewRoundsEvent(reqId: missingReqId, rounds: [validRound]),
          );
          await tcs.first.evCollector.expectNoError();
        });

        Future<void> waitForAndExpectRejected(int i) async {
          await waitFor(
            () => tcs[i].client.signaturesRequests.first.status
            == SignaturesRequestStatus.rejected,
          );
          expectRejectors({ids[i]});
        }

        test("reject SignatureNewRoundsEvent if missing nonces", () async {
          sendEventToClient(
            tcs[1],
            SignatureNewRoundsEvent(reqId: reqDetails.id, rounds: [validRound]),
          );
          await waitForAndExpectRejected(1);
        });

        test("reject SignatureNewRoundsEvent if wrong nonce", () async {
          sendEventToClient(
            tcs.first,
            SignatureNewRoundsEvent(
              reqId: reqDetails.id,
              rounds: [
                // Round contains commitments that participant doesn't have
                SignatureRoundStart(
                  sigI: 0,
                  commitments: SigningCommitmentSet({
                    for (final id in ids.take(3)) id: getSignPart1().commitment,
                  }),
                ),
              ],
            ),
          );
          await waitForAndExpectRejected(0);
        });

        Future<void> expectRejectAfterReloginAndRound() async {

          await tcs.first.client.logout();

          // Get to 3-of-3 round
          for (final tc in tcs.skip(1).take(2)) {
            await tc.client.acceptSignaturesRequest(reqDetails.id);
          }

          // Login again and reject signature as a result of not having nonce
          tcs.first = await login(0, tcs.first.store);
          await waitForAndExpectRejected(0);

        }

        test("reject request if missing nonce for round on login", () async {
          tcs.first.store.sigNonces.clear();
          await expectRejectAfterReloginAndRound();
        });

        test("reject request if wrong nonce for round on login", () async {
          tcs.first.store.sigNonces.values.first.map[0]
            = getSignPart1().nonces;
          await expectRejectAfterReloginAndRound();
        });

        test("invalid SignatureNewRoundsEvent", () async {

          for (final badEv in badNewRounds) {
            await expectBadEvent(tcs.first, badEv);
          }

          // Reject signature so signing is not attempted when sending round
          // initially
          await tcs.first.client.rejectSignaturesRequest(reqDetails.id);

          // Round sent twice
          final newRoundEv = SignatureNewRoundsEvent(
            reqId: reqDetails.id,
            rounds: [validRound],
          );
          sendEventToClient(tcs.first, newRoundEv);
          await tcs.first.evCollector.expectNoError();
          await expectBadEvent(tcs.first, newRoundEv);

        });

        test("ignore SignaturesCompleteEvent for missing request", () async {
          ctx.api.state.sendEventToAll(
            SignaturesCompleteEvent(
              reqId: missingReqId,
              signatures: [validFirstSig],
            ),
          );
          await tcs.first.evCollector.expectNoError();
        });

        test("invalid SignaturesCompleteEvent", () async {

          // No signatures
          await expectBadEvent(
            tcs.first,
            SignaturesCompleteEvent(reqId: missingReqId, signatures: []),
          );

          for (
            // Only one sig, or incorrect sig for second
            final sigs in [[validFirstSig], [validFirstSig, validFirstSig]]
          ) {
            await expectBadEvent(
              tcs.first,
              SignaturesCompleteEvent(reqId: reqDetails.id, signatures: sigs),
            );
          }

        });

        Future<void> massAccept(Iterable<TestClient> tcs) => Future.wait(
          tcs.map((tc) => tc.client.acceptSignaturesRequest(reqDetails.id)),
        );

        Future<void> waitForSig() => waitFor(
          () => ctx.api.state.completedSigs.values.isNotEmpty,
        );

        Future<void> expectSigsEv(TestClient tc) async {
          final ev = await tc.evCollector
            .getExpectOneEvent<SignaturesCompleteClientEvent>();
          expect(ev.details.id, reqDetails.id);
          expect(ev.creator, ids.first);
          expect(ev.signatures, hasLength(2));
        }

        Future<void> expectNoEvents() => Future.wait(
          tcs.map((tc) => tc.evCollector.expectNoEvents()),
        );

        Future<void> expectOnlyStatusEvents(Iterable<TestClient> tcs)
          => Future.wait(
            tcs.map(
              (tc) => tc.evCollector
              .expectOnlyOneEventType<ParticipantStatusClientEvent>(),
            ),
          );

        test("can create valid signature", () async {

          // Last logs out to come back to signatures later
          await tcs.last.logout();
          await expectOnlyStatusEvents(tcs.take(9));

          // Not completed after 2 more approvals
          // First is ignored
          await massAccept(tcs.take(3));
          await expectNoEvents();

          // 3 more approvals completes signatures
          await massAccept(tcs.skip(3).take(3));

          await waitForSig();

          for (final tc in tcs.take(9)) {
            await expectSigsEv(tc);
          }

          // Completed signatures provided on login
          tcs.last = await login(9, tcs.last.store);
          await expectSigsEv(tcs.last);

          // Removed from storage
          for (final tc in tcs) {
            expect(tc.client.signaturesRequests, hasLength(0));
            expect(tc.store.sigNonces, hasLength(0));
            expect(tc.store.sigsRejected, hasLength(0));
          }

        });

        test("can approve after rejection and complete next round", () async {

          // Approve 5
          await massAccept(tcs.take(5));

          // Of approvers, reject 3, leaving 2 accepted
          for (final tc in tcs.take(3)) {
            await tc.client.rejectSignaturesRequest(reqDetails.id);
          }

          // Approve 3 more
          await massAccept(tcs.skip(5).take(3));
          await expectNoEvents();

          // Of original rejectors, accept again giving 6 in total
          // This creates round with 4, 5, 6, 7, 8, 1
          await massAccept(tcs.take(1));
          await waitForSig();
          for (final tc in tcs) {
            await expectSigsEv(tc);
          }

        });

        test("can continue round after re-login", () async {

          // Approve another
          await massAccept(tcs.take(2));

          // First logs out
          await tcs.first.logout();

          // Second rejects before round and logs out
          await tcs[1].client.rejectSignaturesRequest(reqDetails.id);
          await tcs[1].logout();

          // Approve four more, leading to completion of first sig
          await massAccept(tcs.skip(2).take(4));

          await expectOnlyStatusEvents(tcs.skip(2));

          // First and second comes back
          // Second should remember it has rejected
          tcs.first = await login(0, tcs.first.store);
          tcs[1] = await login(1, tcs[1].store);

          await expectOnlyStatusEvents([tcs.first, ...tcs.skip(2)]);

          // Second accepts and completes second signature
          await tcs[1].client.acceptSignaturesRequest(reqDetails.id);

          await waitForSig();
          for (final tc in tcs) {
            await expectSigsEv(tc);
          }

        });

      });

    });

  });
}
