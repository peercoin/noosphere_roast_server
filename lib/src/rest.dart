import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'package:noosphere_roast_server/src/logging.dart';
import 'package:noosphere_roast_server/src/server/api_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Uint8List _bytes(List<int> li) => Uint8List.fromList(li);
SessionID _sid(List<int> li) => SessionID.fromBytes(_bytes(li));
SignaturesRequestId _sigReqId(List<int> li) =>
    SignaturesRequestId.fromBytes(_bytes(li));

String _encodeBytes(List<int> bytes) => base64Encode(bytes);
String _encodeUrlBytes(List<int> bytes) => base64UrlEncode(bytes).replaceAll(
      RegExp(r'=+$'),
      '',
    );

Uint8List _decodeBytes(String value) {
  final base64Value = value.replaceAll('-', '+').replaceAll('_', '/');
  final padding = (4 - base64Value.length % 4) % 4;
  return base64Decode(base64Value.padRight(base64Value.length + padding, '='));
}

Map<String, String> _corsHeaders(String allowOrigin) => {
      'access-control-allow-origin': allowOrigin,
      'access-control-allow-methods': 'GET, POST, OPTIONS',
      'access-control-allow-headers': 'content-type',
      'access-control-max-age': '86400',
    };

Middleware restWebSocketCors({
  String allowOrigin = '*',
}) =>
    (innerHandler) => (request) async {
          final headers = _corsHeaders(allowOrigin);
          if (request.method == 'OPTIONS') {
            return Response.ok('', headers: headers);
          }

          final response = await innerHandler(request);
          return response.change(headers: {...response.headers, ...headers});
        };

class RestWebSocketNoosphereService {
  final ServerApiHandler api;
  final String? allowOrigin;
  final Logger logger;

  RestWebSocketNoosphereService({
    required this.api,
    this.allowOrigin = '*',
    Logger? logger,
  }) : logger = logger ?? api.logger;

  Handler get handler {
    final router = Router()
      ..post('/login', _login)
      ..post('/respond-to-challenge', _respondToChallenge)
      ..post('/extend-session', _extendSession)
      ..post('/dkg/new', _requestNewDkg)
      ..post('/dkg/reject', _rejectDkg)
      ..post('/dkg/commitment', _submitDkgCommitment)
      ..post('/dkg/round2', _submitDkgRound2)
      ..post('/dkg/acks', _sendDkgAcks)
      ..post('/dkg/request-acks', _requestDkgAcks)
      ..post('/signatures/request', _requestSignatures)
      ..post('/signatures/reject', _rejectSignaturesRequest)
      ..post('/signatures/replies', _submitSignatureReplies)
      ..post('/secret-share', _shareSecretShare)
      ..post('/key-constructed/ack', _ackKeyConstructed)
      ..get('/sessions/<sid>/events', _fetchEventWebSocket);

    var pipeline = const Pipeline();
    final allowOrigin = this.allowOrigin;
    if (allowOrigin != null) {
      pipeline = pipeline.addMiddleware(
        restWebSocketCors(allowOrigin: allowOrigin),
      );
    }
    return pipeline.addHandler(router.call);
  }

  Future<HttpServer> serve({
    Object address = 'localhost',
    int port = 8080,
  }) =>
      shelf_io.serve(handler, address, port);

  Future<Response> _login(Request request) =>
      _handleJson(request, logger, () async {
        final json = await _readJson(request);
        final resp = await api.login(
          groupFingerprint: _fieldBytes(json, 'groupFingerprint'),
          participantId:
              Identifier.fromBytes(_fieldBytes(json, 'participantId')),
          protocolVersion: _optionalInt(json, 'protocolVersion') ??
              ServerApiHandler.currentProtocolVersion,
        );
        return _bytesResponse(resp.toBytes());
      });

  Future<Response> _respondToChallenge(Request request) => _handleJson(
        request,
        logger,
        () async {
          final json = await _readJson(request);
          final resp = await api.respondToChallenge(
            Signed<AuthChallenge>(
              obj: AuthChallenge.fromBytes(_fieldBytes(json, 'challenge')),
              signature: cl.SchnorrSignature(_fieldBytes(json, 'signature')),
            ),
          );
          return _bytesResponse(resp.toBytes());
        },
      );

  Future<Response> _extendSession(Request request) =>
      _handleJson(request, logger, () async {
        final json = await _readJson(request);
        final resp = await api.extendSession(_sid(_fieldBytes(json, 'sid')));
        return _bytesResponse(resp.toBytes());
      });

  Future<Response> _requestNewDkg(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.requestNewDkg(
          sid: _sid(_fieldBytes(json, 'sid')),
          signedDetails: Signed<NewDkgDetails>.fromBytes(
            _fieldBytes(json, 'signedDetails'),
            (reader) => NewDkgDetails.fromReader(reader),
          ),
          commitment: DkgPublicCommitment.fromBytes(
            _fieldBytes(json, 'commitment'),
          ),
        );
      });

  Future<Response> _rejectDkg(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.rejectDkg(
          sid: _sid(_fieldBytes(json, 'sid')),
          name: _fieldString(json, 'name'),
        );
      });

  Future<Response> _submitDkgCommitment(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.submitDkgCommitment(
          sid: _sid(_fieldBytes(json, 'sid')),
          name: _fieldString(json, 'name'),
          commitment: DkgPublicCommitment.fromBytes(
            _fieldBytes(json, 'commitment'),
          ),
        );
      });

  Future<Response> _submitDkgRound2(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.submitDkgRound2(
          sid: _sid(_fieldBytes(json, 'sid')),
          name: _fieldString(json, 'name'),
          commitmentSetSignature: cl.SchnorrSignature(
            _fieldBytes(json, 'commitmentSetSignature'),
          ),
          secrets: {
            for (final secret in _fieldList(json, 'secrets'))
              Identifier.fromBytes(_fieldBytes(secret, 'id')):
                  DkgEncryptedSecret(
                ECCiphertext.fromBytes(_fieldBytes(secret, 'secret')),
              ),
          },
        );
      });

  Future<Response> _sendDkgAcks(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.sendDkgAcks(
          sid: _sid(_fieldBytes(json, 'sid')),
          acks: _fieldStringList(json, 'acks')
              .map((ack) => SignedDkgAck.fromBytes(_decodeBytes(ack)))
              .toSet(),
        );
      });

  Future<Response> _requestDkgAcks(Request request) =>
      _handleJson(request, logger, () async {
        final json = await _readJson(request);
        final resp = await api.requestDkgAcks(
          sid: _sid(_fieldBytes(json, 'sid')),
          requests: _fieldStringList(json, 'requests')
              .map((req) => DkgAckRequest.fromBytes(_decodeBytes(req)))
              .toSet(),
        );
        return _repeatedBytesResponse(resp.map((ack) => ack.toBytes()));
      });

  Future<Response> _requestSignatures(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.requestSignatures(
          sid: _sid(_fieldBytes(json, 'sid')),
          keys: _fieldStringList(json, 'keys')
              .map((key) => AggregateKeyInfo.fromBytes(_decodeBytes(key)))
              .toSet(),
          signedDetails: Signed.fromBytes(
            _fieldBytes(json, 'signedDetails'),
            (reader) => SignaturesRequestDetails.fromReader(reader),
          ),
          commitments: _fieldStringList(json, 'commitments')
              .map(
                (commitment) => SigningCommitment.fromBytes(
                  _decodeBytes(commitment),
                ),
              )
              .toList(),
        );
      });

  Future<Response> _rejectSignaturesRequest(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.rejectSignaturesRequest(
          sid: _sid(_fieldBytes(json, 'sid')),
          reqId: _sigReqId(_fieldBytes(json, 'reqId')),
        );
      });

  Future<Response> _submitSignatureReplies(Request request) =>
      _handleJson(request, logger, () async {
        final json = await _readJson(request);
        final resp = await api.submitSignatureReplies(
          sid: _sid(_fieldBytes(json, 'sid')),
          reqId: _sigReqId(_fieldBytes(json, 'reqId')),
          replies: _fieldStringList(json, 'replies')
              .map((reply) => SignatureReply.fromBytes(_decodeBytes(reply)))
              .toList(),
        );

        return _jsonResponse({
          'type': switch (resp) {
            SignatureNewRoundsResponse() => 'new_round',
            SignaturesCompleteResponse() => 'complete',
            null => 'empty',
          },
          'data': resp == null ? null : _encodeBytes(resp.toBytes()),
        });
      });

  Future<Response> _shareSecretShare(Request request) =>
      _handleJson(request, logger, () async {
        final json = await _readJson(request);
        final resp = await api.shareSecretShare(
          sid: _sid(_fieldBytes(json, 'sid')),
          groupKey: cl.ECCompressedPublicKey(_fieldBytes(json, 'groupKey')),
          encryptedSecrets: {
            for (final secret in _fieldList(json, 'secrets'))
              Identifier.fromBytes(_fieldBytes(secret, 'id')):
                  EncryptedKeyShare(
                ECCiphertext.fromBytes(_fieldBytes(secret, 'share')),
              ),
          },
        );
        return _repeatedBytesResponse(resp.map((ev) => ev.toBytes()));
      });

  Future<Response> _ackKeyConstructed(Request request) =>
      _handleEmpty(request, logger, () async {
        final json = await _readJson(request);
        await api.ackKeyConstructed(
          sid: _sid(_fieldBytes(json, 'sid')),
          constructedKey: Signed<KeyWasConstructed>.fromBytes(
            _fieldBytes(json, 'constructedKey'),
            (reader) => KeyWasConstructed.fromReader(reader),
          ),
        );
      });

  FutureOr<Response> _fetchEventWebSocket(Request request, String sid) {
    final description = _requestDescription(request);
    logger.d("REST $description received");
    try {
      final session = api.getSession(_sid(_decodeBytes(sid)));
      final handler = webSocketHandler(
        (WebSocketChannel webSocket, String? _) {
          logger.d("REST $description opened");
          final eventSubscription = session.eventController.stream.listen(
            (event) => webSocket.sink.add(_webSocketEvent(event, logger)),
            onDone: () {
              unawaited(webSocket.sink.close(WebSocketStatus.normalClosure));
            },
            onError: (Object e, StackTrace stackTrace) {
              logger.e(
                "REST $description event stream failed",
                error: e,
                stackTrace: stackTrace,
              );
              unawaited(
                webSocket.sink.close(WebSocketStatus.internalServerError),
              );
            },
            cancelOnError: true,
          );
          webSocket.stream.listen(
            (_) {},
            onDone: () {
              unawaited(eventSubscription.cancel());
              logger.d("REST $description closed");
            },
            onError: (Object e) {
              logger.w(
                "REST $description socket failed: $e",
              );
              unawaited(eventSubscription.cancel());
            },
            cancelOnError: true,
          );
        },
        allowedOrigins: _webSocketAllowedOrigins,
      );
      return handler(request);
    } on InvalidRequest catch (e) {
      logger.w(
        "REST $description rejected: ${e.message}",
      );
      return _jsonResponse({'error': e.message}, status: 400);
    } on FormatException catch (e) {
      logger.w(
        "REST $description rejected: ${e.message}",
      );
      return _jsonResponse({'error': e.message}, status: 400);
    } on HijackException {
      rethrow;
    } on Exception catch (e, stackTrace) {
      logger.e(
        "REST $description failed",
        error: e,
        stackTrace: stackTrace,
      );
      return _jsonResponse({'error': 'Internal server error'}, status: 500);
    }
  }

  Iterable<String>? get _webSocketAllowedOrigins {
    final allowOrigin = this.allowOrigin;
    if (allowOrigin == null || allowOrigin == '*') return null;
    return [allowOrigin];
  }
}

Future<Response> _handleEmpty(
  Request request,
  Logger logger,
  Future<void> Function() action,
) async {
  final description = _requestDescription(request);
  logger.d("REST $description received");
  try {
    await action();
    logger.d("REST $description completed");
    return _jsonResponse({});
  } on InvalidRequest catch (e) {
    logger.w(
      "REST $description rejected: ${e.message}",
    );
    return _jsonResponse({'error': e.message}, status: 400);
  } on FormatException catch (e) {
    logger.w(
      "REST $description rejected: ${e.message}",
    );
    return _jsonResponse({'error': e.message}, status: 400);
  } on Exception catch (e, stackTrace) {
    logger.e(
      "REST $description failed",
      error: e,
      stackTrace: stackTrace,
    );
    return _jsonResponse({'error': 'Internal server error'}, status: 500);
  }
}

Future<Response> _handleJson(
  Request request,
  Logger logger,
  Future<Response> Function() action,
) async {
  final description = _requestDescription(request);
  logger.d("REST $description received");
  try {
    final response = await action();
    logger.d("REST $description completed");
    return response;
  } on InvalidRequest catch (e) {
    logger.w(
      "REST $description rejected: ${e.message}",
    );
    return _jsonResponse({'error': e.message}, status: 400);
  } on FormatException catch (e) {
    logger.w(
      "REST $description rejected: ${e.message}",
    );
    return _jsonResponse({'error': e.message}, status: 400);
  } on Exception catch (e, stackTrace) {
    logger.e(
      "REST $description failed",
      error: e,
      stackTrace: stackTrace,
    );
    return _jsonResponse({'error': 'Internal server error'}, status: 500);
  }
}

String _requestDescription(Request request) {
  final path = request.url.path.isEmpty ? '/' : '/${request.url.path}';
  return '${request.method} $path';
}

Future<Map<String, dynamic>> _readJson(Request request) async {
  final body = await request.readAsString();
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw const FormatException('Expected JSON object');
  return {
    for (final entry in decoded.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Response _jsonResponse(Object value, {int status = 200}) => Response(
      status,
      body: jsonEncode(value),
      headers: {'content-type': 'application/json'},
    );

Response _bytesResponse(List<int> bytes) =>
    _jsonResponse({'data': _encodeBytes(bytes)});

Response _repeatedBytesResponse(Iterable<List<int>> bytes) =>
    _jsonResponse({'data': bytes.map(_encodeBytes).toList()});

String _fieldString(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! String) {
    throw FormatException('Expected "$name" to be a string');
  }
  return value;
}

int? _optionalInt(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value == null) return null;
  if (value is! int) throw FormatException('Expected "$name" to be an int');
  return value;
}

Uint8List _fieldBytes(Map<String, dynamic> json, String name) =>
    _decodeBytes(_fieldString(json, name));

List<Map<String, dynamic>> _fieldList(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! List) throw FormatException('Expected "$name" to be a list');
  return value.map((entry) {
    if (entry is! Map) {
      throw FormatException('Expected "$name" entries to be objects');
    }
    return {
      for (final mapEntry in entry.entries)
        if (mapEntry.key is String) mapEntry.key as String: mapEntry.value,
    };
  }).toList();
}

List<String> _fieldStringList(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! List) throw FormatException('Expected "$name" to be a list');
  return value.map((entry) {
    if (entry is! String) {
      throw FormatException('Expected "$name" entries to be strings');
    }
    return entry;
  }).toList();
}

String _webSocketEvent(Event event, Logger logger) {
  final type = _eventType(event);
  logger.d("REST WebSocket sent $type");
  return jsonEncode({
    'type': type,
    'data': _encodeBytes(event.toBytes()),
  });
}

String _eventType(Event event) => switch (event) {
      ParticipantStatusEvent() => 'participant_status',
      NewDkgEvent() => 'new_dkg',
      DkgCommitmentEvent() => 'dkg_commitment',
      DkgRejectEvent() => 'dkg_reject',
      DkgRound2ShareEvent() => 'dkg_round2_share',
      DkgAckEvent() => 'dkg_ack',
      DkgAckRequestEvent() => 'dkg_ack_request',
      SignaturesRequestEvent() => 'signatures_request',
      SignatureNewRoundsEvent() => 'signature_new_rounds',
      SignaturesCompleteEvent() => 'signatures_complete',
      SignaturesFailureEvent() => 'signatures_failure',
      SecretShareEvent() => 'secret_share',
      ConstructedKeyEvent() => 'constructed_key',
      KeepaliveEvent() => 'keepalive',
    };

String restWebSocketSessionPath(SessionID sid) =>
    '/sessions/${_encodeUrlBytes(sid.n)}/events';
