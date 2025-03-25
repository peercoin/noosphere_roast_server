import 'dart:async';
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'ring_buffer.dart';

class ClientSession implements Expirable {

  final Identifier participantId;
  final SessionID sessionID;
  @override
  Expiry expiry;
  late StreamController<Event> eventController;
  // Buffer up-to 100 events when the event stream is paused.
  final eventBuffer = RingBuffer<Event>(100);

  ClientSession({
    required this.participantId,
    required this.sessionID,
    required this.expiry,
    required void Function() onLostStream,
  }) {

    void flushEvents() {
      for (final event in eventBuffer.flushBuffer()) {
        eventController.add(event);
      }
    }

    eventController = StreamController<Event>(
      onListen: flushEvents,
      onResume: flushEvents,
      // Treat cancelation of event stream as logout as clients should maintain
      // a connection to the event stream
      onCancel: onLostStream,
    );

  }

  void sendEvent(Event e) {
    if (eventController.isPaused) {
      // Save event in ring buffer for later
      eventBuffer.add(e);
    } else {
      // Stream is active so send events
      eventController.add(e);
    }
  }

}
