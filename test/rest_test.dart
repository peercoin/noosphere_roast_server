import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'package:noosphere_roast_server/src/server/state/client_session.dart';
import 'package:noosphere_roast_server/src/server/state/state.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

String _b64(List<int> bytes) => base64Encode(bytes);
Uint8List _dataBytes(String body) {
  final json = jsonDecode(body) as Map<String, dynamic>;
  return base64Decode(json['data'] as String);
}

Request _jsonPost(String path, Map<String, dynamic> body) => Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

Request _get(String path) => Request('GET', Uri.parse('http://localhost$path'));

Request _options(String path) => Request(
      'OPTIONS',
      Uri.parse('http://localhost$path'),
    );

Future<Response> _post(
  Handler handler,
  String path,
  Map<String, dynamic> body,
) async =>
    await handler(_jsonPost(path, body));

Future<HttpServer> _serve(Handler handler) =>
    shelf_io.serve(handler, 'localhost', 0);

String _wsUrl(HttpServer server, String path) =>
    'ws://localhost:${server.port}$path';

SessionID _sid([int lastByte = 1]) =>
    SessionID.fromBytes(Uint8List(16)..last = lastByte);

class _FakeSession implements ClientSession {
  @override
  final SessionID sessionID;

  @override
  final Expiry expiry;

  @override
  final StreamController<Event> eventController;

  _FakeSession({
    SessionID? sid,
    Expiry? expiry,
    void Function()? onCancel,
  })  : sessionID = sid ?? _sid(),
        expiry = expiry ?? Expiry(Duration(minutes: 5)),
        eventController = StreamController<Event>(onCancel: onCancel);

  void send(Event event) => sendEvent(event);

  @override
  void sendEvent(Event event) => eventController.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RestTestApi implements ServerApiHandler {
  final expiry = Expiry(Duration(minutes: 5));
  final sessions = <SessionID, ClientSession>{};

  @override
  final logger = createNoosphereRoastServerLogger();

  @override
  Future<Expiry> extendSession(SessionID sid) async {
    if (!sessions.containsKey(sid)) throw InvalidRequest.noSession();
    return expiry;
  }

  @override
  ClientSession getSession(SessionID id) {
    final session = sessions[id];
    if (session == null) throw InvalidRequest.noSession();
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('RestWebSocketNoosphereService', () {
    late _RestTestApi api;
    late Handler handler;

    setUp(() {
      api = _RestTestApi();
      handler = RestWebSocketNoosphereService(
        api: api,
        allowOrigin: 'https://app.example',
      ).handler;
    });

    test('handles CORS preflight requests', () async {
      final response = await handler(_options('/extend-session'));

      expect(response.statusCode, 200);
      expect(
        response.headers['access-control-allow-origin'],
        'https://app.example',
      );
      expect(
        response.headers['access-control-allow-methods'],
        contains('POST'),
      );
    });

    test('can leave CORS headers to a reverse proxy', () async {
      final noCorsHandler = RestWebSocketNoosphereService(
        api: api,
        allowOrigin: null,
      ).handler;

      final response = await _post(noCorsHandler, '/extend-session', {});

      expect(response.statusCode, 400);
      expect(response.headers, isNot(contains('access-control-allow-origin')));
    });

    test('maps invalid requests to JSON errors with CORS headers', () async {
      final response = await _post(handler, '/extend-session', {});

      expect(response.statusCode, 400);
      expect(response.headers['content-type'], 'application/json');
      expect(
        response.headers['access-control-allow-origin'],
        'https://app.example',
      );

      final body = jsonDecode(await response.readAsString());
      expect(body, {'error': 'Expected "sid" to be a string'});
    });

    test('extends a session through REST', () async {
      final sid = _sid();
      api.sessions[sid] = _FakeSession();

      final response = await _post(handler, '/extend-session', {
        'sid': _b64(sid.toBytes()),
      });

      expect(response.statusCode, 200);
      expect(
        Expiry.fromBytes(_dataBytes(await response.readAsString()))
            .time
            .millisecondsSinceEpoch,
        api.expiry.time.millisecondsSinceEpoch,
      );
    });

    test('streams websocket events and cancels the session stream', () async {
      final canceled = Completer<void>();
      final sid = _sid();
      final session = _FakeSession(
        onCancel: () {
          if (!canceled.isCompleted) canceled.complete();
        },
      );
      api.sessions[sid] = session;

      final server = await _serve(handler);
      try {
        final socket = await WebSocket.connect(
          _wsUrl(server, restWebSocketSessionPath(sid)),
        );

        session.send(KeepaliveEvent());

        final message = await socket.first.timeout(Duration(seconds: 2));
        expect(jsonDecode(message as String), {
          'type': 'keepalive',
          'data': '',
        });

        await socket.close();
        await canceled.future.timeout(Duration(seconds: 2));
      } finally {
        await server.close(force: true);
      }
    });

    test('streams websocket events sent through server state fanout', () async {
      final state = ServerState();
      final creatorSid = _sid(1);
      final receiverSid = _sid(2);

      state.clientSessions[creatorSid] = _FakeSession(sid: creatorSid);
      final receiverSession = _FakeSession(sid: receiverSid);
      state.clientSessions[receiverSid] = receiverSession;
      api.sessions[receiverSid] = receiverSession;

      final server = await _serve(handler);
      try {
        final socket = await WebSocket.connect(
          _wsUrl(server, restWebSocketSessionPath(receiverSid)),
        );

        final event = KeepaliveEvent();
        state.sendEventToOthers(event, creatorSid);

        final message = await socket.first.timeout(Duration(seconds: 2));
        expect(jsonDecode(message as String), {
          'type': 'keepalive',
          'data': '',
        });

        await socket.close();
      } finally {
        await server.close(force: true);
      }
    });

    test('returns a clean error for an unknown websocket session', () async {
      final response = await handler(_get(restWebSocketSessionPath(_sid(2))));

      expect(response.statusCode, 400);
      final body = jsonDecode(await response.readAsString());
      expect(body, {'error': InvalidRequest.noSession().message});
    });

    test('rejects websocket connections from a different origin', () async {
      final sid = _sid();
      api.sessions[sid] = _FakeSession();

      final server = await _serve(handler);
      try {
        await expectLater(
          WebSocket.connect(
            _wsUrl(server, restWebSocketSessionPath(sid)),
            headers: {'Origin': 'https://other.example'},
          ),
          throwsA(isA<WebSocketException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });
}
