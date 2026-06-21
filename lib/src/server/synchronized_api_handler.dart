import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'package:noosphere_roast_server/src/server/api_handler.dart';

class _ApiCallQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<T>();

    _tail = previous.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }
}

/// A [ServerApiHandler] that serializes state-mutating API calls.
///
/// Use one shared instance of this class when exposing the same coordinator
/// through multiple transports, such as gRPC for desktop clients and
/// REST/WebSocket for web clients.
class SynchronizedServerApiHandler extends ServerApiHandler {
  final _queue = _ApiCallQueue();

  SynchronizedServerApiHandler({
    required super.config,
    super.state,
    super.logger,
  });

  @override
  Future<ExpirableAuthChallengeResponse> login({
    required Uint8List groupFingerprint,
    required Identifier participantId,
    int protocolVersion = ServerApiHandler.currentProtocolVersion,
  }) =>
      _queue.run(
        () => super.login(
          groupFingerprint: groupFingerprint,
          participantId: participantId,
          protocolVersion: protocolVersion,
        ),
      );

  @override
  Future<LoginCompleteResponse> respondToChallenge(
    Signed<AuthChallenge> signedChallenge,
  ) =>
      _queue.run(() => super.respondToChallenge(signedChallenge));

  @override
  Future<Expiry> extendSession(SessionID sid) =>
      _queue.run(() => super.extendSession(sid));

  @override
  Future<void> requestNewDkg({
    required SessionID sid,
    required Signed<NewDkgDetails> signedDetails,
    required DkgPublicCommitment commitment,
  }) =>
      _queue.run(
        () => super.requestNewDkg(
          sid: sid,
          signedDetails: signedDetails,
          commitment: commitment,
        ),
      );

  @override
  Future<void> rejectDkg({
    required SessionID sid,
    required String name,
  }) =>
      _queue.run(() => super.rejectDkg(sid: sid, name: name));

  @override
  Future<void> submitDkgCommitment({
    required SessionID sid,
    required String name,
    required DkgPublicCommitment commitment,
  }) =>
      _queue.run(
        () => super.submitDkgCommitment(
          sid: sid,
          name: name,
          commitment: commitment,
        ),
      );

  @override
  Future<void> submitDkgRound2({
    required SessionID sid,
    required String name,
    required cl.SchnorrSignature commitmentSetSignature,
    required Map<Identifier, DkgEncryptedSecret> secrets,
  }) =>
      _queue.run(
        () => super.submitDkgRound2(
          sid: sid,
          name: name,
          commitmentSetSignature: commitmentSetSignature,
          secrets: secrets,
        ),
      );

  @override
  Future<void> sendDkgAcks({
    required SessionID sid,
    required Set<SignedDkgAck> acks,
  }) =>
      _queue.run(() => super.sendDkgAcks(sid: sid, acks: acks));

  @override
  Future<Set<SignedDkgAck>> requestDkgAcks({
    required SessionID sid,
    required Set<DkgAckRequest> requests,
  }) =>
      _queue.run(
        () => super.requestDkgAcks(sid: sid, requests: requests),
      );

  @override
  Future<void> requestSignatures({
    required SessionID sid,
    required Set<AggregateKeyInfo> keys,
    required Signed<SignaturesRequestDetails> signedDetails,
    required List<SigningCommitment> commitments,
  }) =>
      _queue.run(
        () => super.requestSignatures(
          sid: sid,
          keys: keys,
          signedDetails: signedDetails,
          commitments: commitments,
        ),
      );

  @override
  Future<void> rejectSignaturesRequest({
    required SessionID sid,
    required SignaturesRequestId reqId,
  }) =>
      _queue.run(
        () => super.rejectSignaturesRequest(sid: sid, reqId: reqId),
      );

  @override
  Future<SignaturesResponse?> submitSignatureReplies({
    required SessionID sid,
    required SignaturesRequestId reqId,
    required List<SignatureReply> replies,
  }) =>
      _queue.run(
        () => super.submitSignatureReplies(
          sid: sid,
          reqId: reqId,
          replies: replies,
        ),
      );

  @override
  Future<List<ConstructedKeyEvent>> shareSecretShare({
    required SessionID sid,
    required cl.ECCompressedPublicKey groupKey,
    required Map<Identifier, EncryptedKeyShare> encryptedSecrets,
  }) =>
      _queue.run(
        () => super.shareSecretShare(
          sid: sid,
          groupKey: groupKey,
          encryptedSecrets: encryptedSecrets,
        ),
      );

  @override
  Future<void> ackKeyConstructed({
    required SessionID sid,
    required Signed<KeyWasConstructed> constructedKey,
  }) =>
      _queue.run(
        () => super.ackKeyConstructed(
          sid: sid,
          constructedKey: constructedKey,
        ),
      );
}
