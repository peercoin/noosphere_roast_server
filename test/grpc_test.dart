import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/pbgrpc.dart' as pbrpc;
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'package:test/test.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'context.dart';
import 'data.dart';
import 'helpers.dart';
import 'sig_data.dart';
import 'test_keys.dart';

void main() {

  setUpAll(loadFrosty);

  group("GrpcClientApi + FrostNoosphereService", () {

    // Port hopefully unused
    final port = 13543;
    late ServerApiHandler apiHandler;
    late grpc.Server server;

    grpc.ClientChannel getChannel() => grpc.ClientChannel(
      "127.0.0.1",
      port: port,
      options: const grpc.ChannelOptions(
        credentials: grpc.ChannelCredentials.insecure(),
      ),
    );

    GrpcClientApi getApi() => GrpcClientApi(getChannel());

    Future<TestClient> login(
      int i, { void Function()? onDisconnect, }
    ) async {
      final client = await TestClient.login(
        getApi(), i,
        onDisconnect: onDisconnect,
      );
      await client.expectOnlyLoginEvents();
      return client;
    }

    setUp(() async {
      apiHandler = ServerApiHandler(config: serverConfig);
      final service = FrostNoosphereService(api: apiHandler);
      server = service.createServer();
      await server.serve(port: port);
    });

    tearDown(() => server.shutdown());

    // Give wrong fingerprint and expect error
    test("handles error", () => expectLater(
      () => getApi().login(
        groupFingerprint: Uint8List(32),
        participantId: ids.first,
      ),
      throwsA(isA<InvalidRequest>()),
    ),);

    test("can login and logout with events", () async {

      final clients = await Future.wait(List.generate(10, login));

      // Logout first client
      await clients.first.logout();

      // Session should be removed when sessions are accessed
      await waitFor(
        () => apiHandler.state.clientSessions.values.length == 9,
      );

      for (final client in clients.skip(1)) {
        await waitFor(
          () => client.client.onlineParticipants.length == 8,
        );
        final ev = await client.evCollector
          .getExpectOneEvent<ParticipantStatusClientEvent>();
        expect(ev.id, ids.first);
        expect(ev.loggedIn, false);
      }

    });

    test("client handles server being offline", () async {
      await server.shutdown();
      expectLater(() => login(0), throwsA(isA<grpc.GrpcError>()));
    });

    test("client handles server shutdown without callback", () async {
      await login(0);
      await apiHandler.shutdown();
      await server.shutdown();
    });

    test("client handles server shutdown with callback", () async {
      final completer = Completer<void>();
      await login(0, onDisconnect: () => completer.complete());
      await apiHandler.shutdown();
      await completer.future.timeout(Duration(seconds: 2));
      await server.shutdown();
    });

    test("fetchEventStream fails for wrong session ID", () async {
      final wireApi = pbrpc.NoosphereClient(getChannel());
      final stream = wireApi.fetchEventStream(pbrpc.Bytes(data: Uint8List(16)));
      await expectLater(
        () async { await for (final _ in stream) {} },
        throwsA(isA<grpc.GrpcError>()),
      );
    });

    group("given DKG request and clients", () {

      late List<TestClient> tcs;

      setUp(() async {
        tcs = await Future.wait(List.generate(10, login));
        await tcs.first.client.requestDkg(getDkgDetails());
        for (final tc in tcs.skip(1)) {
          await waitFor(() => tc.client.dkgRequests.length == 1);
          await tc.evCollector.getExpectOneEvent<UpdatedDkgClientEvent>();
        }
      });

      test("can reject DKG", () async {
        await tcs.last.client.rejectDkg("123");
        for (final tc in tcs.take(9)) {

          await waitFor(() => tc.client.dkgRequests.isEmpty);

          final ev = await tc.evCollector
            .getExpectOneEvent<RejectedDkgClientEvent>();

          expect(ev.details.name, "123");
          expect(ev.participant, ids.last);
          expect(ev.fault, DkgFault.none);

        }
      });

      group("given key and signatures request", () {

        late SignaturesRequestId reqId;

        setUp(() async {

          // All other clients accept DKG
          await Future.wait(
            tcs.skip(1).map((tc) => tc.client.acceptDkg("123")),
          );

          // Check key was generated.
          await Future.wait(
            tcs.map((tc) => tc.store.waitForKeyWithName("123", 10)),
          );
          for (final tc in tcs) {
            expect(tc.store.keys.values.first.name, "123");
            await tc.evCollector
              .expectOnlyOneEventType<UpdatedDkgClientEvent>();
          }

          // Create signature request for 2-of-10
          final sigReq = SignaturesRequestDetails(
            requiredSigs: [
              SingleSignatureDetails(
                signDetails: getSignDetails(0),
                groupKey: cl.ECCompressedPublicKey.fromPubkey(
                  tcs.first.store.keys.keys.first,
                ),
                hdDerivation: [0],
              ),
            ],
            expiry: futureExpiry,
          );
          await tcs.first.client.requestSignatures(sigReq);
          reqId = sigReq.id;

          // Expect all other clients to receive
          for (final tc in tcs.skip(1)) {
            await waitFor(() => tc.client.signaturesRequests.length == 1);
            await tc.evCollector.getExpectOneEvent<SignaturesRequestClientEvent>();
          }

        });

        test("can reject request", () async {

          // 9 total rejections causes failure
          for (final tc in tcs.take(9)) {
            await tc.client.rejectSignaturesRequest(reqId);
          }

          for (final tc in tcs) {
            await tc.waitForNoSigsReqs();
            final ev = await tc.evCollector
              .getExpectOneEvent<SignaturesFailureClientEvent>();
            expect(ev.request.details.id, reqId);
          }

        });

        test(
          "can accept request and receive completed signature on login",
          () async {

            // Logout last to receive signature on login
            await tcs.last.client.logout();
            await Future.wait(
              tcs.take(9).map((tc) => tc.expectOnlyLoginEvents()),
            );

            // One more accepted causes success
            await tcs[1].client.acceptSignaturesRequest(reqId);

            Future<SignaturesCompleteClientEvent> expectSigsEv(
              TestClient tc,
            ) async {
              final ev = await tc.evCollector
                .getExpectOneEvent<SignaturesCompleteClientEvent>();
              expect(ev.details.id, reqId);
              expect(ev.creator, ids.first);
              expect(ev.signatures, hasLength(1));
              return ev;
            }

            for (final tc in tcs.take(9)) {
              await tc.waitForNoSigsReqs();
              await expectSigsEv(tc);
            }

            // Login last and the signature should be received
            tcs.last = await TestClient.login(
              getApi(), 9,
              storage: tcs.last.store,
            );
            final ev = await expectSigsEv(tcs.last);

            // Ensure signature is valid
            final derivedInternalKey = HDParticipantKeyInfo.masterFromInfo(
              tcs.first.store.keys.values.first.keyInfo,
            ).derive(0).groupKey;
            final tr = cl.Taproot(internalKey: derivedInternalKey);
            expect(
              ev.signatures.first.verify(tr.tweakedKey, Uint8List(32)),
              true,
            );

          },
        );

      });

    });

    test("can receive needed DKG acks", () async {

      // Clients login with own ACKs
      List<TestClient> tcs = await Future.wait(
        List.generate(
          10, (i) => TestClient.login(
            getApi(), i,
            storage: storeWithKeyAndAcks(i, { getDkgAck(i, true) }),
          ),
        ),
      );

      // Should receive all ACKs
      await Future.wait(
        tcs.map((tc) => tc.store.waitForKeyWithName("123", 10)),
      );

    });

  });

}
