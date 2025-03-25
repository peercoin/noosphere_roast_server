import 'package:noosphere_roast_server/src/server/state/ring_buffer.dart';
import 'package:test/test.dart';

void main() {

  group("RingBuffer", () {

    test("must be a positive maxSize", () {
      expect(() => RingBuffer<int>(-1), throwsArgumentError);
    });

    group("given RingBuffer of 10 max", () {

      late RingBuffer<int> buffer;
      setUp(() => buffer = RingBuffer(10));

      void expectFlushEmpty() => expect(buffer.flushBuffer(), isEmpty);

      test("can flush empty", () {
        for (int i = 0; i < 2; i++) {
          expectFlushEmpty();
        }
      });

      test("can flush less than full", () {
        buffer.add(1);
        buffer.add(2);
        expect(buffer.flushBuffer(), [1, 2]);
        expectFlushEmpty();
      });

      test("can flush filled", () {
        for (int i = 0; i < 10; i++) {
          buffer.add(i);
        }
        expect(buffer.flushBuffer(), List.generate(10, (i) => i));
        expectFlushEmpty();
      });

      test("can flush one more than filled", () {
        for (int i = 0; i < 11; i++) {
          buffer.add(i);
        }
        expect(buffer.flushBuffer(), List.generate(10, (i) => i+1));
        expectFlushEmpty();
      });

    });

  });

}

