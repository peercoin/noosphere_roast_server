import 'dart:async';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:grpc/grpc.dart' as grpc;
import 'package:noosphere_roast_client/pbgrpc.dart' as pb;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'package:noosphere_roast_server/src/logging.dart';
import 'package:noosphere_roast_server/src/server/api_handler.dart';
import 'package:noosphere_roast_server/src/server/state/client_session.dart';

Uint8List _bytes(List<int> li) => Uint8List.fromList(li);
SessionID _sid(List<int> li) => SessionID.fromBytes(_bytes(li));
SignaturesRequestId _sigReqId(List<int> li) =>
    SignaturesRequestId.fromBytes(_bytes(li));
pb.Bytes _returnWritable(cl.Writable writable) => pb.Bytes(
      data: writable.toBytes(),
    );

class FrostNoosphereService extends pb.NoosphereServiceBase {
  final ServerApiHandler api;
  final Logger logger;

  FrostNoosphereService({
    required this.api,
    Logger? logger,
  }) : logger = logger ?? api.logger;

  grpc.Server createServer() => grpc.Server.create(services: [this]);

  grpc.GrpcError _wrapException(
    String method,
    Exception e, [
    StackTrace? stackTrace,
  ]) {
    if (e is InvalidRequest) {
      logger.w("gRPC $method rejected: ${e.message}");
    } else {
      logger.e(
        "gRPC $method failed",
        error: e,
        stackTrace: stackTrace,
      );
    }
    return grpc.GrpcError.unknown(e.toString());
  }

  Future<T> _handleExceptions<T>(
    String method,
    Future<T> Function() f,
  ) async {
    logger.d("gRPC $method received");
    try {
      final result = await f();
      logger.d("gRPC $method completed");
      return result;
    } on Exception catch (e, stackTrace) {
      throw _wrapException(method, e, stackTrace);
    }
  }

  Future<pb.Empty> _handleEmpty(
    String method,
    Future<void> Function() f,
  ) async {
    await _handleExceptions(method, f);
    return pb.Empty();
  }

  @override
  Future<pb.Bytes> login(
    grpc.ServiceCall call,
    pb.LoginRequest request,
  ) =>
      _handleExceptions("login", () async {
        final resp = await api.login(
          groupFingerprint: _bytes(request.groupFingerprint),
          participantId: Identifier.fromBytes(
            _bytes(request.participantId),
          ),
          protocolVersion: request.protocolVersion,
        );

        return _returnWritable(resp);
      });

  @override
  Future<pb.Bytes> respondToChallenge(
    grpc.ServiceCall call,
    pb.SignedAuthChallenge request,
  ) =>
      _handleExceptions("respondToChallenge", () async {
        final resp = await api.respondToChallenge(
          Signed<AuthChallenge>(
            obj: AuthChallenge.fromBytes(_bytes(request.challenge)),
            signature: cl.SchnorrSignature(_bytes(request.signature)),
          ),
        );

        return _returnWritable(resp);
      });

  @override
  Stream<pb.Events> fetchEventStream(
    grpc.ServiceCall call,
    pb.Bytes request,
  ) {
    final sessionId = _sid(request.data);
    late final ClientSession session;
    try {
      session = api.getSession(sessionId);
    } on Exception catch (e, stackTrace) {
      throw _wrapException("fetchEventStream", e, stackTrace);
    }

    logger.d(
      "gRPC fetchEventStream opened for participant ${session.participantId}",
    );

    // sendTrailers is not always called automatically when the stream ends
    // despite the documentation.
    // Without calling this, the grpc stream may hang and never close.
    final controller = StreamController<Event>(
      onCancel: () {
        logger.d(
          "gRPC fetchEventStream canceled for participant "
          "${session.participantId}",
        );
        call.sendTrailers();
      },
    );
    // When upstream stream is done, cancel this one
    controller.addStream(session.eventController.stream).then(
      (_) {
        logger.d(
          "gRPC fetchEventStream closed for participant "
          "${session.participantId}",
        );
        return controller.close();
      },
    );

    // Pass across all events
    return controller.stream.map(
      (ev) => pb.Events(
        data: ev.toBytes(),
        type: switch (ev) {
          ParticipantStatusEvent() => pb.EventType.PARTICIPANT_STATUS_EVENT,
          NewDkgEvent() => pb.EventType.NEW_DKG_EVENT,
          DkgCommitmentEvent() => pb.EventType.DKG_COMMITMENT_EVENT,
          DkgRejectEvent() => pb.EventType.DKG_REJECT_EVENT,
          DkgRound2ShareEvent() => pb.EventType.DKG_ROUND2_SHARE_EVENT,
          DkgAckEvent() => pb.EventType.DKG_ACK_EVENT,
          DkgAckRequestEvent() => pb.EventType.DKG_ACK_REQUEST_EVENT,
          SignaturesRequestEvent() => pb.EventType.SIG_REQ_EVENT,
          SignatureNewRoundsEvent() => pb.EventType.SIG_NEW_ROUNDS_EVENT,
          SignaturesCompleteEvent() => pb.EventType.SIG_COMPLETE_EVENT,
          SignaturesFailureEvent() => pb.EventType.SIG_FAILURE_EVENT,
          SecretShareEvent() => pb.EventType.SECRET_SHARE_EVENT,
          ConstructedKeyEvent() => pb.EventType.CONSTRUCTED_KEY_EVENT,
          KeepaliveEvent() => pb.EventType.KEEPALIVE_EVENT,
        },
      ),
    );
  }

  @override
  Future<pb.Bytes> extendSession(
    grpc.ServiceCall call,
    pb.Bytes request,
  ) =>
      _handleExceptions("extendSession", () async {
        final resp = await api.extendSession(_sid(request.data));
        return _returnWritable(resp);
      });

  @override
  Future<pb.Empty> requestNewDkg(
    grpc.ServiceCall call,
    pb.DkgRequest request,
  ) =>
      _handleEmpty(
        "requestNewDkg",
        () => api.requestNewDkg(
          sid: _sid(request.sid),
          signedDetails: Signed<NewDkgDetails>.fromBytes(
            _bytes(request.signedDetails),
            (reader) => NewDkgDetails.fromReader(reader),
          ),
          commitment: DkgPublicCommitment.fromBytes(
            _bytes(request.commitment),
          ),
        ),
      );

  @override
  Future<pb.Empty> rejectDkg(
    grpc.ServiceCall call,
    pb.DkgToReject request,
  ) =>
      _handleEmpty(
        "rejectDkg",
        () => api.rejectDkg(sid: _sid(request.sid), name: request.name),
      );

  @override
  Future<pb.Empty> submitDkgCommitment(
    grpc.ServiceCall call,
    pb.DkgCommitment request,
  ) =>
      _handleEmpty(
        "submitDkgCommitment",
        () => api.submitDkgCommitment(
          sid: _sid(request.sid),
          name: request.name,
          commitment: DkgPublicCommitment.fromBytes(
            _bytes(request.commitment),
          ),
        ),
      );

  @override
  Future<pb.Empty> submitDkgRound2(
    grpc.ServiceCall call,
    pb.DkgRound2 request,
  ) =>
      _handleEmpty(
        "submitDkgRound2",
        () => api.submitDkgRound2(
          sid: _sid(request.sid),
          name: request.name,
          commitmentSetSignature: cl.SchnorrSignature(
            _bytes(request.commitmentSetSignature),
          ),
          secrets: {
            for (final secret in request.secrets)
              Identifier.fromBytes(_bytes(secret.id)): DkgEncryptedSecret(
                ECCiphertext.fromBytes(_bytes(secret.secret)),
              ),
          },
        ),
      );

  @override
  Future<pb.Empty> sendDkgAcks(
    grpc.ServiceCall call,
    pb.DkgAcks request,
  ) =>
      _handleEmpty(
        "sendDkgAcks",
        () => api.sendDkgAcks(
          sid: _sid(request.sid),
          acks: request.acks
              .map(
                (ack) => SignedDkgAck.fromBytes(_bytes(ack)),
              )
              .toSet(),
        ),
      );

  @override
  Future<pb.RepeatedBytes> requestDkgAcks(
    grpc.ServiceCall call,
    pb.DkgAckRequest request,
  ) =>
      _handleExceptions("requestDkgAcks", () async {
        final resp = await api.requestDkgAcks(
          sid: _sid(request.sid),
          requests: request.requests
              .map(
                (request) => DkgAckRequest.fromBytes(_bytes(request)),
              )
              .toSet(),
        );

        return pb.RepeatedBytes(data: resp.map((ack) => ack.toBytes()));
      });

  @override
  Future<pb.Empty> requestSignatures(
    grpc.ServiceCall call,
    pb.SignaturesRequest request,
  ) =>
      _handleEmpty(
        "requestSignatures",
        () => api.requestSignatures(
          sid: _sid(request.sid),
          keys: request.keys
              .map(
                (key) => AggregateKeyInfo.fromBytes(_bytes(key)),
              )
              .toSet(),
          signedDetails: Signed.fromBytes(
            _bytes(request.signedDetails),
            (reader) => SignaturesRequestDetails.fromReader(reader),
          ),
          commitments: request.commitments
              .map(
                (commitment) => SigningCommitment.fromBytes(_bytes(commitment)),
              )
              .toList(),
        ),
      );

  @override
  Future<pb.Empty> rejectSignaturesRequest(
    grpc.ServiceCall call,
    pb.SignaturesRejection request,
  ) =>
      _handleEmpty(
        "rejectSignaturesRequest",
        () => api.rejectSignaturesRequest(
          sid: _sid(request.sid),
          reqId: _sigReqId(request.reqId),
        ),
      );

  @override
  Future<pb.SignaturesResponse> submitSignatureReplies(
    grpc.ServiceCall call,
    pb.SignaturesReplies request,
  ) =>
      _handleExceptions("submitSignatureReplies", () async {
        final resp = await api.submitSignatureReplies(
          sid: _sid(request.sid),
          reqId: _sigReqId(request.reqId),
          replies: request.replies
              .map(
                (reply) => SignatureReply.fromBytes(_bytes(reply)),
              )
              .toList(),
        );

        return pb.SignaturesResponse(
          type: switch (resp) {
            SignatureNewRoundsResponse() =>
              pb.SignaturesResponseType.SIGNATURES_RESPONSE_NEW_ROUND,
            SignaturesCompleteResponse() =>
              pb.SignaturesResponseType.SIGNATURES_RESPONSE_COMPLETE,
            null => pb.SignaturesResponseType.SIGNATURES_RESPONSE_EMPTY,
          },
          data: resp?.toBytes(),
        );
      });

  @override
  Future<pb.RepeatedBytes> shareSecretShare(
    grpc.ServiceCall call,
    pb.SecretShare request,
  ) =>
      _handleExceptions("shareSecretShare", () async {
        final resp = await api.shareSecretShare(
          sid: _sid(request.sid),
          groupKey: cl.ECCompressedPublicKey(_bytes(request.groupKey)),
          encryptedSecrets: {
            for (final secret in request.secrets)
              Identifier.fromBytes(_bytes(secret.id)): EncryptedKeyShare(
                ECCiphertext.fromBytes(_bytes(secret.share)),
              ),
          },
        );

        return pb.RepeatedBytes(data: resp.map((ev) => ev.toBytes()));
      });

  @override
  Future<pb.Empty> ackKeyConstructed(
    grpc.ServiceCall call,
    pb.ConstructedKey request,
  ) =>
      _handleEmpty(
        "ackKeyConstructed",
        () => api.ackKeyConstructed(
          sid: _sid(request.sid),
          constructedKey: Signed<KeyWasConstructed>.fromBytes(
            _bytes(request.constructedKey),
            (reader) => KeyWasConstructed.fromReader(reader),
          ),
        ),
      );
}
