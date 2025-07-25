import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'package:noosphere_roast_server/src/server/state/client_session.dart';
import 'package:noosphere_roast_server/src/server/state/dkg.dart';
import 'package:noosphere_roast_server/src/server/state/key_sharing.dart';
import 'package:noosphere_roast_server/src/server/state/signatures_coordination.dart';
import 'package:noosphere_roast_server/src/server/state/state.dart';
import 'package:test/test.dart';
import '../context.dart';
import '../data.dart';
import '../sig_data.dart';
import '../test_keys.dart';

void main() {
  group("ServerApiHander", () {

    setUpAll(loadFrosty);

    late TestContext ctx;
    setUp(() => ctx = TestContext());

    Future<void> expectInvalid(void Function() f) async => await expectLater(
      f, throwsA(isA<InvalidRequest>()),
    );

    void expectSigned(Signed signed) => expect(
      signed.verify(getPrivkey(0).pubkey),
      true,
    );

    Future<void> expectOnlyLoginEventsForAll() async {
      for (final client in ctx.clients) {
        await client.expectOnlyOneEventType<ParticipantStatusEvent>();
      }
    }

    group(".login()", () {

      test("invalid request", () async {

        // Invalid version
        await expectInvalid(
          () => ctx.api.login(
            groupFingerprint: groupConfig.fingerprint,
            participantId: ids.first,
            protocolVersion: 1,
          ),
        );

        // Invalid Identifier
        await expectInvalid(
          () => ctx.api.login(
            groupFingerprint: groupConfig.fingerprint,
            participantId: badId,
          ),
        );

        // Invalid fingerprint
        await expectInvalid(
          () => ctx.api.login(
            groupFingerprint: Uint8List(32),
            participantId: ids.first,
          ),
        );

      });

      test("success", () async {

        final response = await ctx.api.login(
          groupFingerprint: groupConfig.fingerprint,
          participantId: ids.first,
        );
        expect(ctx.api.state.challenges[response.challenge]!.id, ids.first);
        expect(response.expiry.isExpired, false);
        expect(response.challenge.n.length, 16);

      });

    });

    group(".respondToChallenge()", () {

      late AuthChallenge challenge;
      late Signed<AuthChallenge> validResp;

      setUp(() async {

        final response = await ctx.api.login(
          groupFingerprint: groupConfig.fingerprint,
          participantId: ids.first,
        );

        challenge = response.challenge;
        validResp = Signed.sign(obj: challenge, key: getPrivkey(0));

      });

      test("invalid request", () async {

        // No challenge
        await expectInvalid(
          () => ctx.api.respondToChallenge(
            Signed.sign(obj: AuthChallenge(), key: getPrivkey(0)),
          ),
        );

        // Bad signature
        await expectInvalid(
          () => ctx.api.respondToChallenge(
            Signed.sign(obj: challenge, key: getPrivkey(1)),
          ),
        );

      });

      test("expired challenge", () async {

        // Create challenge to be immediately expired for participant 2
        final challenge = AuthChallenge();
        ctx.api.state.challenges[challenge] = ChallengeDetails(
          id: ids[1], expiry: Expiry(Duration(days: -1)),
        );

        await expectInvalid(
          () => ctx.api.respondToChallenge(
            Signed.sign(obj: challenge, key: getPrivkey(1)),
          ),
        );

        expect(ctx.api.state.challenges[challenge], null);

      });

      test("success", () async {

        // Add round2 DKG that should be removed
        ctx.addDkgRound2(ids[1], "round2");

        // Add a DKG where the commitment should be removed
        void addRound1Dkg() => ctx.addDkgRound1(ids.first, "123", [0, 1]);
        addRound1Dkg();

        // Test that DKG info is reset to round 1 on logout
        void expectDkgCommitments(String name, List<Identifier> ids) {
          expect(ctx.api.state.nameToDkg.containsKey(name), true);
          final commitments = ctx.api.state.nameToDkg[name]!.round1.commitments;
          expect(commitments.map((e) => e.$1), ids);
        }
        void expectResetDkgInfo() {
          expectDkgCommitments("123", [ids[1]]);
          expectDkgCommitments("round2", []);
        }

        // Add existing session that should get removed
        final oldSid = (await ctx.login(0)).sid;

        // Add other participant session
        final other = await ctx.login(1);

        // Do response
        final response = await ctx.api.respondToChallenge(validResp);

        // Expect response
        expect(response.expiry.isExpired, false);
        expect(response.id.n.length, 16);
        expect(response.startTime, ctx.api.startTime);
        expect(response.onlineParticipants, {ids[1]});
        expect(response.secretShares, isEmpty);

        // DKGs
        final newDkgs = response.newDkgs;
        expect(newDkgs, hasLength(2));

        void expectDkg(
          NewDkgEvent newDkg,
          String name,
          Identifier creator,
          List<Identifier> ids,
        ) {
          final ev = newDkg;
          expect(ev.details.obj.name, name);
          expectSigned(ev.details);
          expect(ev.creator, creator);
          expect(newDkg.commitments.map((c) => c.$1), ids);
        }
        expectDkg(newDkgs.first, "123", ids.first, [ids[1]]);
        expectDkg(newDkgs.last, "round2", ids[1], []);

        // Expect state changes
        expect(ctx.api.state.challenges[challenge], null);
        final sess = ctx.api.state.clientSessions[response.id]!;
        expect(sess.participantId, ids.first);
        expect(sess.sessionID, response.id);
        expect(sess, ctx.api.state.participantToSession[ids.first]);
        expectResetDkgInfo();

        // Second login removes old session
        expect(ctx.api.state.clientSessions[oldSid], null);

        // Other participant received logout and login event

        void expectLoginEvent(Event ev, bool loggedIn) => expect(
          ev,
          isA<ParticipantStatusEvent>()
          .having((e) => e.id, "id", ids[0])
          .having((e) => e.loggedIn, "loggedIn", loggedIn),
        );
        {
          final events = await other.getEvents();
          expect(events.length, 2);
          expectLoginEvent(events.first, false);
          expectLoginEvent(events.last, true);
        }

        // If session expires, other participant should receive event
        // round2 DKGs should be reset to round1 and the round1 commitment of
        // the logged out participant should be removed
        addRound1Dkg();
        ctx.addDkgRound2(ids.first, "round2");

        ctx.api.state.clientSessions[response.id] = ClientSession(
          participantId: ids[0],
          sessionID: response.id,
          expiry: Expiry(Duration(minutes: -1)),
          onLostStream: () {},
        );
        {
          final events = await other.getEvents();
          expect(events.length, 1);
          expectLoginEvent(events.first, false);
        }
        expectResetDkgInfo();

      });

      test("provides signature data on success", () async {

        // Add signature requests with pending rounds on second and third only
        final sigStates = [
          ctx.addSigReq(ids.first, [0,1]),
          ctx.addSigReq(ids.first, [2,3,4]),
          ctx.addSigReq(ids.first, [5,6]),
        ];
        final sigIds = sigStates.map((state) => state.details.obj.id).toList();

        SignatureRoundState addRound(int reqI, int sigI, Set<Identifier> ids) {
          final sigState = sigStates[reqI].sigs[sigI]
            as SingleSignatureInProgressState;
          final round = SignatureRoundState(
            SigningCommitmentSet(
              { for (final id in ids) id: getSignPart1(i:0).commitment },
            ),
          );
          for (final id in ids) {
            sigState.roundForId[id] = round;
          }
          return round;
        }

        // First request has round for others
        addRound(0, 0, ids.skip(1).toSet());

        // Second request's 0 round is for others and the 1 and 2 rounds
        // includes the participant
        addRound(1, 0, ids.skip(1).toSet());
        addRound(1, 1, ids.take(3).toSet());
        // Signature 2 has share for participant already
        addRound(1, 2, ids.take(4).toSet())
          .shares.add((ids.first, dummyPart2().share));

        // Third request has rounds for all
        addRound(2, 0, ids.take(2).toSet());
        addRound(2, 1, ids.take(3).toSet());

        // Add one completed signature with ack by client and one without
        ctx.addCompletedSig({ids.first}, 0);
        final noAckCompletedSigs = ctx.addCompletedSig({}, 1);

        // Do response
        final response = await ctx.api.respondToChallenge(validResp);

        // Sig requests
        final reqs = response.sigRequests;
        expect(reqs, hasLength(3));
        expect(reqs.map((req) => req.details.obj.id).toSet(), sigIds.toSet());

        for (int i = 0; i < 3; i++) {
          final req = reqs[i];
          expect(req.creator, ids.first);
          expect(req.details.obj.id, isIn(sigIds));
        }

        // Rounds

        final rounds = response.sigRounds;
        expect(rounds, hasLength(2));

        void expectRounds(int reqI, List<int> sigIs) {
          final roundsEv = rounds.firstWhere((r) => r.reqId == sigIds[reqI]);
          expect(roundsEv.rounds.map((r) => r.sigI).toList(), sigIs);
        }

        expectRounds(1, [1]);
        expectRounds(2, [0,1]);

        // Completed sigs. Only include the one without the ACK
        expect(response.completedSigs, hasLength(1));
        expect(
          response.completedSigs.first.details.obj.id,
          noAckCompletedSigs.details.obj.id,
        );

      });

    });

    group(".extendSession()", () {

      late SessionID sid;
      setUp(() async => sid = (await ctx.login(0)).sid);

      test(
        "invalid request",
        () async => await expectInvalid(() => ctx.api.extendSession(SessionID())),
      );

      test("success", () async {
        final newExpiry = await ctx.api.extendSession(sid);
        expect(newExpiry.isExpired, false);
        expect(ctx.api.state.clientSessions[sid]!.expiry.time, newExpiry.time);
      });

    });

    group(".requestNewDkg()", () {

      late ServerTestClient client;
      late DkgPublicCommitment commitment;

      setUp(() async {

        client = await ctx.login(0);
        commitment = getDkgPart1(0).public;

        // Already existing DKG request
        ctx.addDkg(ids.first, "other");

      });

      test("invalid request", () async {

        // Invalid session id
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: SessionID(),
            signedDetails: signObject(getDkgDetails()),
            commitment: commitment,
          ),
        );

        // Name exists
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: client.sid,
            signedDetails: signObject(getDkgDetails(name:"other")),
            commitment: commitment,
          ),
        );

        // Expiry too soon
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: client.sid,
            signedDetails: signObject(
              getDkgDetails(expiry: Expiry(Duration(minutes: 28, seconds: 59))),
            ),
            commitment: commitment,
          ),
        );

        // Expiry too late
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: client.sid,
            signedDetails: signObject(
              getDkgDetails(expiry: Expiry(Duration(days: 7, seconds: 1))),
            ),
            commitment: commitment,
          ),
        );

        // Invalid threshold for group
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: client.sid,
            signedDetails: signObject(getDkgDetails(threshold: 11)),
            commitment: commitment,
          ),
        );

        // Invalid signature
        await expectInvalid(
          () => ctx.api.requestNewDkg(
            sid: client.sid,
            signedDetails: signObject(getDkgDetails(), 1),
            commitment: commitment,
          ),
        );

      });

      test("success", () async {

        // Add other participant session to obtain an event
        final other = await ctx.login(1);

        await expectOnlyLoginEventsForAll();

        await ctx.api.requestNewDkg(
          sid: client.sid,
          signedDetails: signObject(getDkgDetails()),
          commitment: commitment,
        );

        final dkg = ctx.api.state.nameToDkg["123"]!;
        expect(dkg.expiry.time, futureExpiry.time);
        expect(dkg.creator, ids.first);
        expect(dkg.details.obj.name, "123");
        expectSigned(dkg.details);
        expect(dkg.round.runtimeType, DkgRound1State);

        void expectCommitments(DkgCommitmentList list) {
          expect(list.length, 1);
          expect(list.first.$1, ids.first);
          expect(list.first.$2.toBytes(), commitment.toBytes());
        }

        final round1 = dkg.round as DkgRound1State;
        expectCommitments(round1.commitments);

        // Other participant should receive event for new DKG
        final events = await other.getEvents();
        expect(events.length, 1);
        final ev = events.first as NewDkgEvent;
        expect(ev.creator, ids.first);
        expect(ev.details.obj.name, "123");
        expect(ev.details.verify(getPrivkey(0).pubkey), true);
        expectCommitments(ev.commitments);

        // Sending participant shouldn't receive event
        await client.expectNoEvents();

      });

    });

    group(".rejectDkg()", () {

      late ServerTestClient client, other;

      setUp(() async {
        client = await ctx.login(0);
        other = await ctx.login(1);
        await expectOnlyLoginEventsForAll();
        ctx.addDkg(ids.first, "123");
      });

      test("invalid request", () async {
        await expectInvalid(() => ctx.api.rejectDkg(sid: SessionID(), name: "123"));
      });

      test("success", () async {

        void expectExists(bool exists) => expect(
          ctx.api.state.nameToDkg.containsKey("123"), exists,
        );

        await ctx.api.rejectDkg(sid: client.sid, name: "other");
        expectExists(true);
        await ctx.api.rejectDkg(sid: client.sid, name: "123");
        expectExists(false);

        // Expect reject event to other participant but not to rejecting
        // participant
        expect((await client.getEvents()).length, 0);
        final events = await other.getEvents();
        expect(events.length, 1);
        expect(
          events.first,
          isA<DkgRejectEvent>()
          .having((e) => e.name, "name", "123")
          .having((e) => e.participant, "participant", ids.first),
        );

      });

    });

    group(".submitDkgCommitment()", () {

      late List<DkgPart1> commitments;

      setUp(() async {
        commitments = List.generate(10, (i) => getDkgPart1(i));
        await ctx.multiLogin(10);
        ctx.addDkg(ids.first, "123").round1.commitments.add(
          (ids.first, commitments.first.public),
        );
        ctx.addDkgRound2(ids.first, "round2");
      });

      test("invalid request", () async {
        // Invalid session ID
        await expectInvalid(
          () => ctx.api.submitDkgCommitment(
            sid: SessionID(),
            name: "123",
            commitment: commitments[1].public,
          ),
        );
        // DKG doesn't exist
        await expectInvalid(
          () => ctx.api.submitDkgCommitment(
            sid: ctx.clients[1].sid,
            name: "abc",
            commitment: commitments[1].public,
          ),
        );
        // Already have commitment
        await expectInvalid(
          () => ctx.api.submitDkgCommitment(
            sid: ctx.clients.first.sid,
            name: "123",
            commitment: commitments.first.public,
          ),
        );
        // DKG is the wrong round
        await expectInvalid(
          () => ctx.api.submitDkgCommitment(
            sid: ctx.clients[1].sid,
            name: "round2",
            commitment: commitments[1].public,
          ),
        );
      });

      test("success", () async {

        await expectOnlyLoginEventsForAll();

        for (int i = 1; i < 10; i++) {

          await ctx.api.submitDkgCommitment(
            sid: ctx.clients[i].sid,
            name: "123",
            commitment: commitments[i].public,
          );

          // Expect events
          for (final client in ctx.clients) {

            if (client.sid == ctx.clients[i].sid) {
              await client.expectNoEvents();
              continue;
            }

            final events = await client.getEvents();
            expect(events.length, 1);
            expect(events.first, isA<DkgCommitmentEvent>());

            final ev = (events.first as DkgCommitmentEvent);
            expect(ev.name, "123");
            expect(ev.participant, ids[i]);
            expect(ev.commitment.toBytes(), commitments[i].public.toBytes());

          }

        }

        // Expect moving onto round 2
        expect(
          ctx.api.state.nameToDkg["123"]!.round,
          isA<DkgRound2State>(),
        );

      });

    });

    group(".submitDkgRound2()", () {

      late List<DkgPart2> part2s;
      late List<cl.SchnorrSignature> commitmentSetSigs;
      late List<Map<Identifier, DkgEncryptedSecret>> secretMaps;

      setUp(() async {

        await ctx.multiLogin(10);
        final part1s = List.generate(10, (i) => getDkgPart1(i));
        final commitmentSet = DkgCommitmentSet(
          List.generate(10, (i) => (ids[i], part1s[i].public)),
        );
        part2s = List.generate(
          10,
          (i) => DkgPart2(
            identifier: ids[i],
            round1Secret: part1s[i].secret,
            commitments: commitmentSet,
          ),
        );
        commitmentSetSigs = List.generate(
          10,
          (i) => cl.SchnorrSignature.sign(getPrivkey(i), commitmentSet.hash),
        );
        secretMaps = List.generate(
          10,
          (i) => {
            for (int j = 0; j < 10; j++)
              if (j != i) ids[j]: DkgEncryptedSecret.encrypt(
                secretShare: part2s[i].sharesToGive[ids[j]]!,
                recipientKey: getPrivkey(j).pubkey,
                senderKey: getPrivkey(i),
              ),
          },
        );

        ctx.addDkg(ids.first, "round1");

        // Add round 2 with last participant already having provided
        ctx.addDkgRound2(ids.first, "round2", commitmentSet.hash)
          .round2.participantsProvided.add(ids.last);

      });

      test("invalid request", () async {

        // Invalid session ID or already provided round 2
        for (final badSid in [SessionID(), ctx.clients.last.sid]) {
          await expectInvalid(
            () => ctx.api.submitDkgRound2(
              sid: badSid,
              name: "round2",
              commitmentSetSignature: commitmentSetSigs.last,
              secrets: secretMaps.last,
            ),
          );
        }

        // Dkg doesn't exist or is round 1
        for (final badDkg in ["noexist", "round1"]) {
          await expectInvalid(
            () => ctx.api.submitDkgRound2(
              sid: ctx.clients.first.sid,
              name: badDkg,
              commitmentSetSignature: commitmentSetSigs.first,
              secrets: secretMaps.first,
            ),
          );
        }

        // Invalid signature
        await expectInvalid(
          () => ctx.api.submitDkgRound2(
            sid: ctx.clients.first.sid,
            name: "round2",
            commitmentSetSignature: commitmentSetSigs.last,
            secrets: secretMaps.first,
          ),
        );

        for (final badSecrets in [
          // Contains self
          secretMaps.last,
          // Identifier doesn't exist Add first 8 and then give false ID for
          // last
          {
            for (int j = 1; j < 9; j++) ids[j]: secretMaps.first[ids[j]]!,
            Identifier.fromUint16(100): secretMaps.first[ids[9]]!,
          },
          // Too few secrets
          {
            for (int j = 1; j < 9; j++) ids[j]: secretMaps.first[ids[j]]!,
          },
          // Too many secrets
          {
            for (int j = 1; j < 10; j++) ids[j]: secretMaps.first[ids[j]]!,
            Identifier.fromUint16(100): secretMaps.first[ids[9]]!,
          },
        ]) {
          await expectInvalid(
            () => ctx.api.submitDkgRound2(
              sid: ctx.clients.first.sid,
              name: "round2",
              commitmentSetSignature: commitmentSetSigs.first,
              secrets: badSecrets,
            ),
          );
        }

      });

      test("success", () async {

        await expectOnlyLoginEventsForAll();

        // All ctx.clients except last to give secrets
        for (int i = 0; i < 9; i++) {

          await ctx.api.submitDkgRound2(
            sid: ctx.clients[i].sid,
            name: "round2",
            commitmentSetSignature: commitmentSetSigs[i],
            secrets: secretMaps[i],
          );

          // Expect state to record participant except for last
          if (i < 8) {
            final provided
              = ctx.api.state.nameToDkg["round2"]!.round2.participantsProvided;
            expect(provided.length, i+2);
            expect(provided, contains(ids[i]));
          }

          // Expect all other ctx.clients to receive event
          for (int j = 0; j < 10; j++) {
            if (j != i) {

              final events = await ctx.clients[j].getEvents();
              expect(events.length, 1);
              expect(
                events.first,
                isA<DkgRound2ShareEvent>(),
              );

              final ev = events.first as DkgRound2ShareEvent;
              expect(ev.name, "round2");
              expect(ev.commitmentSetSignature, commitmentSetSigs[i]);
              expect(ev.sender, ids[i]);
              expect(
                ev.secret.ciphertext.toBytes(),
                secretMaps[i][ids[j]]!.ciphertext.toBytes(),
              );

            }
          }
        }

        // Expect DKG state removed after all participants provided
        expect(ctx.api.state.nameToDkg["round2"], null);

      });

    });

    group(".sendDkgAcks()", () {

      late List<SignedDkgAck> acks;

      setUp(() async {
        // Not everyone is logged in
        await ctx.multiLogin(8);
        acks = List.generate(10, (i) => getDkgAck(i, i % 2 == 0));
      });

      test("invalid request", () async {

        // Invalid session ID
        await expectInvalid(
          () => ctx.api.sendDkgAcks(sid: SessionID(), acks: acks.toSet()),
        );

        // Invalid signature
        await expectInvalid(
          () => ctx.api.sendDkgAcks(
            sid: ctx.clients.first.sid,
            acks: {
              SignedDkgAck(signer: ids.last, signed: acks.first.signed),
            },
          ),
        );

        // No such participant
        await expectInvalid(
          () => ctx.api.sendDkgAcks(
            sid: ctx.clients.first.sid,
            acks: {
              SignedDkgAck(
                signer: badId,
                signed: acks.first.signed,
              ),
            },
          ),
        );

      });

      test("success", () async {

        await expectOnlyLoginEventsForAll();

        // Add all ACKs and expect events
        for (int i = 0; i < 9; i++) {

          // Allow any sender
          final senderI = i % 3;

          await ctx.api.sendDkgAcks(
            sid: ctx.clients[senderI].sid,
            // Include last ACK three times
            acks: {acks[i], if (i < 3) acks.last},
          );

          // Check events given to participants except for sender and signer
          for (int j = 0; j < 8; j++) {

            final evs = await ctx.clients[j].getEvents();

            if (j == i || j == senderI) {
              expect(evs, isEmpty);
            } else {

              expect(evs.length, 1);
              final acks = (evs.first as DkgAckEvent).acks;

              expect(acks.length, i == 0 ? 2 : 1);

              expect(acks.first.signer, ids[i]);
              expect(acks.first.signed.obj.accepted, i % 2 == 0);

              if (i == 0) {
                expect(acks.last.signer, ids.last);
                expect(acks.last.signed.obj.accepted, false);
              }

            }

          }

          // Check state
          final ackMap = ctx.api.state.dkgAckCache[groupPublicKey]!.acks;
          expect(ackMap.length, i+2);
          expect(ackMap, contains(ids[i]));
          expect(ackMap, contains(ids.last));
          expect(ackMap[ids[i]]!.obj.accepted, i % 2 == 0);
          expect(ackMap[ids.last]!.obj.accepted, false);

        }

      });

    });

    group(".requestDkgAcks()", () {

      late cl.ECCompressedPublicKey altKey, altKey2;
      // The ones the server has and will be given to the first participant
      late Set<SignedDkgAck> toHave;

      setUp(() async {

        // Not everyone is logged in
        await ctx.multiLogin(8);

        toHave = {};

        // Include three existing acks for main key
        final expiry = Expiry(Duration(minutes: 1));
        final cache
          = ctx.api.state.dkgAckCache[groupPublicKey]
          = DkgAckCache(expiry);
        for (int i = 0; i < 3; i++) {
          final ack = getDkgAck(i, true);
          if (i != 0) toHave.add(ack);
          cache.acks[ids[i]] = ack.signed;
        }

        // Include additional ack for another key
        altKey = groupPublicKey.tweak(Uint8List(32)..last = 1)!;
        final ack = getDkgAck(1, true, groupKey: altKey);
        toHave.add(ack);
        ctx.api.state.dkgAckCache[altKey]
          = DkgAckCache(expiry)..acks[ids[1]] = ack.signed;

        // Another key without a cached ACK
        altKey2 = groupPublicKey.tweak(Uint8List(32)..last = 2)!;

        await expectOnlyLoginEventsForAll();

      });

      DkgAckRequest getReq(
        Set<int> idIs,
        [ cl.ECCompressedPublicKey? key, ]
      ) => DkgAckRequest(
        ids: idIs.map((i) => ids[i]).toSet(),
        groupPublicKey: key ?? groupPublicKey,
      );

      test("invalid request", () async {

        // Invalid Session ID
        await expectInvalid(
          () => ctx.api.requestDkgAcks(
            sid: SessionID(),
            requests: { getReq({0}) },
          ),
        );

        // Invalid requested id
        await expectInvalid(
          () => ctx.api.requestDkgAcks(
            sid: ctx.clients.first.sid,
            requests: {
              DkgAckRequest(ids: { badId }, groupPublicKey: groupPublicKey),
            },
          ),
        );

        // Can't request self
        await expectInvalid(
          () => ctx.api.requestDkgAcks(
            sid: ctx.clients.first.sid,
            requests: { getReq({0}) },
          ),
        );

      });

      test("success", () async {

        // Ask for two cached ACKs from the first key and a cached ACK for the
        // second, two ACKs that doesn't exist for the first key and another ACK
        // for a key without a cache
        final haveAcks = await ctx.api.requestDkgAcks(
          sid: ctx.clients.first.sid,
          requests: {
            getReq({ 1, 2, 3, 4 }),
            getReq({ 1 }, altKey),
            getReq({ 1 }, altKey2),
          },
        );

        expect(haveAcks, toHave);

        // Calling client shouldn't receive request
        await ctx.clients.first.expectNoEvents();

        // Other clients should receive requests for missing ACKs
        for (final client in ctx.clients.skip(1)) {

          final evs = await client.getEvents();
          expect(evs.length, 1);
          final reqs = (evs.first as DkgAckRequestEvent).requests;

          expect(reqs.length, 2);
          expect(
            reqs.firstWhere((req) => req.groupPublicKey == groupPublicKey).ids,
            { ids[3], ids[4] },
          );
          expect(
            reqs.firstWhere((req) => req.groupPublicKey == altKey2).ids,
            { ids[1] },
          );
        }

      });

      test("do not send DkgAckRequestEvent when there are no needed", () async {

        final haveAcks = await ctx.api.requestDkgAcks(
          sid: ctx.clients.first.sid,
          // Request only what the server has
          requests: { getReq({ 1, 2 }), getReq({1}, altKey) },
        );
        expect(haveAcks, toHave);

        // No events should be had as all ACKs were returned
        await ctx.expectNoEventsOrError();

      });

    });

    group(".requestSignatures()", () {

      late ServerTestClient client;
      late List<AggregateKeyInfo> keys;
      late Signed<SignaturesRequestDetails> existing;
      late Set<AggregateKeyInfo> validKeys, keysForExisting;
      late SignaturesRequestDetails validDetails;
      late Signed<SignaturesRequestDetails> validSignedDetails;
      late List<SigningCommitment> validCommitments;

      setUp(() async {

        client = await ctx.login(0);
        keys = List.generate(2, (i) => getAggregateKeyInfo(tweak: i));
        existing = signObject(getSignaturesDetails(singleSigTweaks: [0xff]));
        validKeys = {keys[0]};
        keysForExisting = { getAggregateKeyInfo(tweak: 0xff) };
        validDetails = getSignaturesDetails();
        validSignedDetails = signObject(validDetails);
        validCommitments = [getSignPart1(tweak: 0).commitment];

        ctx.addSigReq(ids.first, [0xff]);

      });

      test("invalid request", () async {

        Future<void> expectInvalidSigReq({
          SessionID? sid,
          Set<AggregateKeyInfo>? keys,
          Signed<SignaturesRequestDetails>? signedDetails,
          List<SigningCommitment>? commitments,
        }) => expectInvalid(
          () => ctx.api.requestSignatures(
            sid: sid ?? client.sid,
            keys: keys ?? validKeys,
            signedDetails: signedDetails ?? validSignedDetails,
            commitments: commitments ?? validCommitments,
          ),
        );

        // Invalid Session ID
        await expectInvalidSigReq(sid: SessionID());

        // Wrong number of commitments
        await expectInvalidSigReq(commitments: []);

        // Too few keys
        await expectInvalidSigReq(keys: {});

        // Too many keys
        await expectInvalidSigReq(keys: keys.take(2).toSet());

        // Expiry too soon or late
        for (final duration in [
          Duration(seconds: 24),
          Duration(days: 14, seconds: 1),
        ]) {
          await expectInvalidSigReq(
            signedDetails: signObject(
              getSignaturesDetails(expiry: Expiry(duration)),
            ),
          );
        }

        // Request exists
        await expectInvalidSigReq(
          signedDetails: existing,
          keys: keysForExisting,
        );

        // Bad signature
        await expectInvalidSigReq(
          signedDetails: signObject(getSignaturesDetails(), 1),
        );

      });

      test("success", () async {

        // Add other participant session to obtain an event
        final other = await ctx.login(1);

        await expectOnlyLoginEventsForAll();

        await ctx.api.requestSignatures(
          sid: client.sid,
          keys: validKeys,
          signedDetails: validSignedDetails,
          commitments: validCommitments,
        );

        final req = ctx.api.state.sigRequests[validDetails.id]!;
        expect(req.expiry.time, futureExpiry.time);
        expect(req.details.obj.id, validDetails.id);
        expect(req.creator, ids.first);

        expect(req.sigs, hasLength(1));
        expect(
          (req.sigs.first as SingleSignatureInProgressState)
          .nextCommitments[ids.first],
          validCommitments.first,
        );

        final events = await other.getEvents();
        expect(events.length, 1);
        final ev = events.first as SignaturesRequestEvent;
        expect(ev.details.obj.id, validDetails.id);
        expect(ev.details.verify(getPrivkey(0).pubkey), true);
        expect(ev.creator, ids.first);

        await client.expectNoEventsOrError();

      });

    });

    group("given signatures request", () {

      late List<ServerTestClient> clients;
      late List<ParticipantKeyInfo> k1shares;
      late List<ParticipantKeyInfo> k2shares;
      late SignaturesRequestDetails sigsDetails;
      late SignaturesCoordinationState reqState;
      late List<SignPart1> creatorPart1s;

      setUp(() async {

        clients = await ctx.multiLogin(10);

        // Request with two root keys: k1 and k2
        // k1 is 3-of-10. k2 is 4-of-10
        // Sigs:
        // 1. k1/0
        // 2. k1/1/0x7fffffff
        // 3. k2/0
        // 4. k1/0

        k1shares = generateNewKey(3);
        k2shares = generateNewKey(4);

        sigsDetails = SignaturesRequestDetails(
          requiredSigs: [
            SingleSignatureDetails(
              signDetails: getSignDetails(0),
              groupKey: k1shares.first.groupKey,
              hdDerivation: [0],
            ),
            SingleSignatureDetails(
              signDetails: getSignDetails(1),
              groupKey: k1shares.first.groupKey,
              hdDerivation: [1, 0x7fffffff],
            ),
            SingleSignatureDetails(
              signDetails: getSignDetails(2),
              groupKey: k2shares.first.groupKey,
              hdDerivation: [0],
            ),
            SingleSignatureDetails(
              signDetails: getSignDetails(3),
              groupKey: k1shares.first.groupKey,
              hdDerivation: [0],
            ),
          ],
          // Expire in 1 hour
          expiry: Expiry(Duration(hours: 1)),
        );

        creatorPart1s = [k1shares, k1shares, k2shares, k1shares].map(
          (li) => SignPart1(privateShare: li.first.private.share),
        ).toList();

        await ctx.api.requestSignatures(
          sid: clients.first.sid,
          keys: { k1shares.first.aggregate, k2shares.first.aggregate },
          signedDetails: Signed.sign(obj: sigsDetails, key: getPrivkey(0)),
          commitments: creatorPart1s.map((part1) => part1.commitment).toList(),
        );

        reqState = ctx.api.state.sigRequests[sigsDetails.id]!;

      });

      void expectSigReqExists(bool exists) => expect(
        ctx.api.state.sigRequests.containsKey(sigsDetails.id),
        exists,
      );

      Future<void> expectFailedReq() async {
        for (final client in clients) {
          final evs = await client.getEvents();
          expect(evs, hasLength(1));
          final failEvent = evs.first as SignaturesFailureEvent;
          expect(failEvent.reqId, sigsDetails.id);
        }
        expectSigReqExists(false);
      }

      group(".rejectSignaturesRequest()", () {

        test("invalid request", () async {
          // Invalid Session ID
          await expectInvalid(
            () => ctx.api.rejectSignaturesRequest(
              sid: SessionID(),
              reqId: sigsDetails.id,
            ),
          );
        });

        test(
          "ignore non-existent id without exception",
          () => ctx.api.rejectSignaturesRequest(
            sid: clients.first.sid,
            reqId: getSignaturesDetails().id,
          ),
        );

        test("success", () async {

          Future<void> doReject(int i) => ctx.api.rejectSignaturesRequest(
            sid: clients[i].sid,
            reqId: sigsDetails.id,
          );

          await ctx.clearEvents();

          // Add existing rejector and malicious
          reqState.rejectors.add(ids[1]);
          reqState.malicious.add(ids[2]);

          // Creator can reject
          await doReject(0);

          // 7 malicious or rejected causes failure. 3 already. Add 3 more
          for (int i = 3; i < 6; i++) {
            // Can reject multiple times with no effect
            await doReject(i);
            await doReject(i);
          }

          void expectNearlyFailed() {
            expect(
              reqState.rejectors,
              { ...ids.take(2), ...ids.skip(3).take(3) },
            );
            expect(reqState.malicious, { ids[2] });
          }

          expectNearlyFailed();

          // A malicious participant can reject but it changes nothing
          await doReject(2);
          expectNearlyFailed();

          // No events before failure
          await ctx.expectNoEventsOrError();

          // Add one more rejection leading to failure
          await doReject(6);
          await expectFailedReq();

        });

      });

      group(".submitSignatureReplies()", () {

        HDParticipantKeyInfo deriveInfo(
          ParticipantKeyInfo info, List<int> indicies,
        ) => indicies.fold(
          HDParticipantKeyInfo.masterFromInfo(info),
          (key, i) => key.derive(i),
        );

        late List<List<ParticipantKeyInfo>> sigInfos;

        setUp(() async {
          final sharedk1Info
            = k1shares.map((info) => deriveInfo(info, [0])).toList();
          sigInfos = [
            sharedk1Info,
            k1shares.map((info) => deriveInfo(info, [1, 0x7fffffff])).toList(),
            k2shares.map((info) => deriveInfo(info, [0])).toList(),
            sharedk1Info,
          ];
        });

        SignPart1 doPart1(int i, int sigI) => SignPart1(
          privateShare: sigInfos[sigI][i].private.share,
        );

        SignatureReply getReply(
          int i, int sigI, {
            SigningCommitment? commitment,
            SigningNonces? nonce,
            SigningCommitmentSet? commitments,
            SignDetails? signDetailsOverride,
          }
        ) => SignatureReply(
          sigI: sigI,
          nextCommitment: (commitment ?? doPart1(i, sigI).commitment),
          share: commitments == null ? null : SignPart2(
            identifier: ids[i],
            details: signDetailsOverride
              ?? sigsDetails.requiredSigs[sigI].signDetails,
            ourNonces: nonce!,
            commitments: commitments,
            info: sigInfos[sigI][i].signing,
          ).share,
        );

        test("invalid request", () async {

          final validResp = getReply(1, 0);

          // Invalid Session ID
          await expectInvalid(
            () => ctx.api.submitSignatureReplies(
              sid: SessionID(),
              reqId: sigsDetails.id,
              replies: [validResp],
            ),
          );

          // Already malicious
          reqState.malicious.add(ids.last);
          await expectInvalid(
            () => ctx.api.submitSignatureReplies(
              sid: clients.last.sid,
              reqId: sigsDetails.id,
              replies: [getReply(9, 0)],
            ),
          );

          // Malicious invalid requests

          Future<void> expectMalicious(List<SignatureReply> responses) async {
            await expectInvalid(
              () => ctx.api.submitSignatureReplies(
                sid: clients[1].sid,
                reqId: sigsDetails.id,
                replies: responses,
              ),
            );
            expect(reqState.malicious, contains(ids[1]));
            // Remove for next test
            reqState.malicious.remove(ids[1]);
          }

          // Empty responses
          await expectMalicious([]);

          // Duplicate response
          await expectMalicious([validResp, validResp]);

          // Invalid signature index
          await expectMalicious([
            SignatureReply(
              sigI: 4,
              nextCommitment: getReply(1, 3).nextCommitment,
            ),
          ]);

          // Commitment exists
          final part1 = doPart1(1, 3);
          (reqState.sigs[3] as SingleSignatureInProgressState)
            .nextCommitments[ids[1]] = part1.commitment;
          await expectMalicious([getReply(1, 3)]);

          // Start round for next tests by adding commitment from 3rd
          await ctx.api.submitSignatureReplies(
            sid: clients[2].sid,
            reqId: sigsDetails.id,
            replies: [getReply(2, 3)],
          );

          // Get commitment set from event
          final evs = await clients[1].getEvents();
          final commitments = (evs.last as SignatureNewRoundsEvent)
            .rounds.first.commitments;

          // Missing share
          await expectMalicious([getReply(1, 3)]);

          // Share unnecessary
          await expectMalicious([
            getReply(
              1, 1,
              nonce: part1.nonces,
              commitments: commitments,
            ),
          ]);

          // Invalid share due to wrong sign details
          await expectMalicious([
            getReply(
              1, 3,
              nonce: part1.nonces,
              commitments: commitments,
              // Wrong details
              signDetailsOverride: getSignDetails(0),
            ),
          ]);

        });

        test(
          "ignore non-existent id without exception",
          () => ctx.api.submitSignatureReplies(
            sid: clients.first.sid,
            reqId: getSignaturesDetails().id,
            replies: [getReply(1, 0)],
          ),
        );

        Future<void> doMalicious(int i) => expectInvalid(
          () => ctx.api.submitSignatureReplies(
            sid: clients[i].sid,
            reqId: sigsDetails.id,
            replies: [
              SignatureReply(
                // Malicious due to wrong index
                sigI: 4,
                nextCommitment: doPart1(i, 0).commitment,
              ),
            ],
          ),
        );

        test("can process multiple rounds to success", () async {

          final List<List<SignPart1?>> part1s = List.generate(
            10, (i) => i == 0 ? creatorPart1s : [null, null, null, null],
          );

          final List<List<SigningCommitmentSet?>> commitmentSets
            = List.generate(
              10, (i) => [null, null, null, null],
            );

          void expectAndProcessRounds(
            int i,
            List<SignatureRoundStart> rounds,
            List<int> sigIs,
          ) {
            expect(rounds.map((r) => r.sigI), sigIs);
            for (final round in rounds) {
              commitmentSets[i][round.sigI] = round.commitments;
            }
          }

          void expectNewRoundsResponse(
            int i,
            SignaturesResponse? resp,
            List<int> sigIs,
          ) {
            expect(resp, isA<SignatureNewRoundsResponse>());
            expectAndProcessRounds(
              i,
              (resp as SignatureNewRoundsResponse).rounds,
              sigIs,
            );
          }

          Future<void> expectAndProcessNewRoundsEvent(
            int i, List<int> sigIs,
          ) async {
            final evs = await clients[i].getEvents();
            expect(evs, hasLength(1));
            final newRoundsEv = evs.first as SignatureNewRoundsEvent;
            expect(newRoundsEv.reqId, sigsDetails.id);
            expectAndProcessRounds(i, newRoundsEv.rounds, sigIs);
          }

          Future<SignaturesResponse?> submit(int i, List<int> sigIs) {
            final thisPart1s = [...part1s[i]];
            for (final sigI in sigIs) {
              part1s[i][sigI] = doPart1(i, sigI);
            }
            return ctx.api.submitSignatureReplies(
              sid: clients[i].sid,
              reqId: sigsDetails.id,
              replies: sigIs.map(
                (sigI) => getReply(
                  i,
                  sigI,
                  commitment: part1s[i][sigI]!.commitment,
                  nonce: thisPart1s[sigI]?.nonces,
                  commitments: commitmentSets[i][sigI],
                ),
              ).toList(),
            );
          }

          await ctx.clearEvents();

          // Add first three IDs as rejectors which will be unrejected when the
          // replies are provided.
          reqState.rejectors.addAll(ids.take(3));

          // Three commitments for all sigs. 0, 1 and 3 enter round
          // r=round, p=pending
          // 0: r=[0,1,2] p=[]
          // 1: r=[0,1,2] p=[]
          // 2: p=[0,1,2]
          // 3: r=[0,1,2] p=[]
          for (int i = 1; i < 3; i++) {

            final resp = await submit(i, [0,1,2,3]);

            if (i == 2) {
              expectNewRoundsResponse(2, resp, [0,1,3]);
              for (int j = 0; j < 2; j++) {
                await expectAndProcessNewRoundsEvent(j, [0,1,3]);
              }
            } else {
              expect(resp, null);
            }

          }

          // Only has 0 left as rejector
          expect(reqState.rejectors, {ids[0]});

          // Two sucessful shares. One more commitment for all sigs.
          // 0: r=[0ok,1ok,2] r=[0,1,3] p=[]
          // 1: r=[0ok,1ok,2] r=[0,1,3] p=[]
          // 2: r=[0,1,2,3] p=[]
          // 3: r=[0ok,1ok,2] r=[0,1,3] p=[]
          for (int i = 0; i < 2; i++) {
            expect(await submit(i, [0,1,3]), null);
          }
          // No more rejectors
          expect(reqState.rejectors, isEmpty);
          expectNewRoundsResponse(
            3,
            await submit(3, [0,1,2,3]),
            [0,1,2,3],
          );
          for (int i = 0; i < 2; i++) {
            await expectAndProcessNewRoundsEvent(i, [0,1,2,3]);
          }
          await expectAndProcessNewRoundsEvent(2, [2]);

          // 2 gives malicious
          await doMalicious(2);
          expect(reqState.malicious, contains(ids[2]));

          // Two successful for new round, plus commitments for new rounds from
          // unique IDs
          // 0: r=[0ok,1ok,2] r=[0,1ok,3ok] r=[1,3,4] p=[]
          // 1: r=[0ok,1ok,2] r=[0,1ok,3ok] r=[1,3,5] p=[]
          // 2: r=[0,1ok,2,3ok] r=[1,3,6,7] p=[]
          // 3: r=[0ok,1ok,2] r=[0,1ok,3ok] r=[1,3,8] p=[]
          for (final i in [1, 3]) {
            await submit(i, [0,1,2,3]);
          }
          Future<void> newRoundFor1And3(int newId, int sigI) async {
            expectNewRoundsResponse(newId, await submit(newId, [sigI]), [sigI]);
            for (final i in [1,3]) {
              await expectAndProcessNewRoundsEvent(i, [sigI]);
            }
          }
          await newRoundFor1And3(4, 0);
          await newRoundFor1And3(5, 1);
          await submit(6, [2]);
          await newRoundFor1And3(7, 2);
          await expectAndProcessNewRoundsEvent(6, [2]);
          await newRoundFor1And3(8, 3);

          // Malicious 2 has no effect
          await expectInvalid(() => submit(2, [0,1,2,3]));
          await ctx.expectNoEventsOrError();

          // Complete 0 and 1 with successful share in 1nd round by 0, but do
          // not complete 3
          // 0: r=[0ok,1ok,2] r=[0ok,1ok,3ok] r=[1,3,4] DONE
          // 1: r=[0ok,1ok,2] r=[0ok,1ok,3ok] r=[1,3,5] DONE
          // 2: r=[0ok,1ok,2,3ok] r=[1,3,6,7] p=[]
          // 3: r=[0ok,1ok,2] r=[0,1ok,3ok] r=[1,3,8] p=[]
          await submit(0, [0,1]);
          await ctx.expectNoEventsOrError();

          // Give 6 malicious int total (5 more) without failure
          Future.wait([5,6,7,8,9].map(doMalicious));

          // Complete 2 and 3 in last round by last remaining good participants:
          // 0,1,3,4
          // 0 and 1 should still be accepted even though previously complete
          // 0: r=[0ok,1ok,2] r=[0ok,1ok,3ok] r=[1,3,4] DONE
          // 1: r=[0ok,1ok,2] r=[0ok,1ok,3ok] r=[1,3,5] DONE
          // 2: r=[0ok,1ok,2,3ok] r=[1ok,3,6,7] r=[0ok,1ok,3ok,4ok] DONE
          // 3: r=[0ok,1ok,2] r=[0ok,1ok,3ok] r=[1,3,8] p=[0] DONE
          for (final i in [0,1,3,4]) {
            final resp = await submit(i, i == 0 ? [2, 3] : [0,1,2,3]);
            if (i == 4) {
              // New round for 2
              expectNewRoundsResponse(4, resp, [2]);
              for (final i2 in [0,1,3]) {
                await expectAndProcessNewRoundsEvent(i2, [2]);
              }
            } else {
              expect(resp, null);
            }
          }

          // Finalise sig 2 with participants 0,1,3,4 and collect resulting
          // signatures
          late List<cl.SchnorrSignature> sigs;
          for (final i in [0,1,3,4]) {
            final resp = await submit(i, [2]);
            if (i == 4) {
              // Response has signatures
              expect(resp, isA<SignaturesCompleteResponse>());
              sigs = (resp as SignaturesCompleteResponse).signatures;
              expect(sigs, hasLength(4));
            } else {
              expect(resp, null);
            }
          }

          // Signatures valid and stored in completedSigs
          final completed = ctx.api.state.completedSigs[sigsDetails.id]!;
          // Expiry should be updated to minimum
          expect(
            completed.expiry.time.millisecondsSinceEpoch,
            greaterThan(sigsDetails.expiry.time.millisecondsSinceEpoch),
          );
          expect(completed.acks, isEmpty);
          for (int i = 0; i < 4; i++) {
            final singleSigDetails = sigsDetails.requiredSigs[i];
            expect(completed.signatures[i].data, sigs[i].data);
            expect(
              sigs[i].verify(
                cl.Taproot(internalKey: sigInfos[i].first.groupKey).tweakedKey,
                singleSigDetails.signDetails.message,
              ),
              true,
            );
          }

          // Expect events
          for (int i = 0; i < 10; i++) {
            if (i == 4) continue;
            final evs = await clients[i].getEvents();
            expect(evs, hasLength(1));
            final completeEv = evs.first as SignaturesCompleteEvent;
            expect(
              completeEv.signatures.map((s) => s.data),
              sigs.map((s) => s.data),
            );
          }

          // Request no longer exists after signatures have been made
          expectSigReqExists(false);

        });

        test("fails with too many malicious", () async {

          await ctx.clearEvents();

          // Complete signature 2 so that the max threshold is only 3
          reqState.sigs[2] = SingleSignatureFinishedState(
            // Dummy signature
            cl.SchnorrSignature.sign(getPrivkey(0), Uint8List(32)),
          );

          // Do not double count rejector and malicious
          reqState.rejectors.add(ids.first);

          // Two additional rejectors
          reqState.rejectors.addAll({ids[6], ids[7]});

          for (int i = 0; i < 6; i++) {
            await clients[i].expectNoEventsOrError();
            await doMalicious(i);
          }

          await expectFailedReq();

        });

      });

    });

    group(".shareSecretShare", () {

      late List<ServerTestClient> clients;
      late EncryptedKeyShare dummyShare;

      setUp(() async {
        clients = await ctx.multiLogin(5);
        dummyShare = EncryptedKeyShare.encrypt(
          keyShare: getPrivkey(0),
          recipientKey: groupPublicKey,
          senderKey: getPrivkey(0),
        );
        await expectOnlyLoginEventsForAll();
      });

      test("invalid request", () async {

          // Invalid Session ID
          await expectInvalid(
            () => ctx.api.shareSecretShare(
              sid: SessionID(),
              groupKey: groupPublicKey,
              encryptedSecrets: { ids.last: dummyShare },
            ),
          );

          Future<void> expectInvalidSecrets(
            Map<Identifier, EncryptedKeyShare> secrets,
          ) => expectInvalid(
            () => ctx.api.shareSecretShare(
              sid: clients.first.sid,
              groupKey: groupPublicKey,
              encryptedSecrets: secrets,
            ),
          );

          // Cannot be empty
          await expectInvalidSecrets({});

          // Cannot send to self
          await expectInvalidSecrets({ ids.first: dummyShare });

          // Identifiers must be in group
          await expectInvalidSecrets({ Identifier.fromUint16(11): dummyShare });

      });

      test("success", () async {

        Future<void> sendToAll(int from) => ctx.api.shareSecretShare(
          sid: clients[from].sid,
          groupKey: groupPublicKey,
          encryptedSecrets: {
            for (final id in ids) if (id != ids[from]) id: dummyShare,
          },
        );

        // First and second sends to everyone
        for (int from = 0; from < 2; from++) {

          await sendToAll(from);

          // Expect events to logged in
          for (int i = 0; i < 5; i++) {
            if (i == from) continue;
            final ev = await clients[i].getExpectOneEvent<SecretShareEvent>();
            expect(ev.sender, ids[from]);
            expect(ev.groupKey, groupPublicKey);
          }

        }

        // Others obtain both on login
        final furtherClients = await ctx.multiLogin(5, skip: 5);
        for (final client in furtherClients) {
          final shares = client.loginResponse.secretShares;
          expect(shares.map((s) => s.sender), unorderedEquals(ids.take(2)));
          expect(shares.map((s) => s.groupKey), everyElement(groupPublicKey));
        }
        await expectOnlyLoginEventsForAll();

        // Ignore resend, inc. when done
        ctx.api.state.secretShares[groupPublicKey]?.receiverShares[ids.last]
          = ParticipantDoneShareState();
        await sendToAll(0);

        for (final client in ctx.clients) {
          await client.expectNoEvents();
        }

      });

    });

  });
}
