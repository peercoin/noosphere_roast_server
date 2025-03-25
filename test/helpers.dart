import 'package:coinlib/coinlib.dart' as cl;
import 'package:test/test.dart';

void writableTest(
  cl.Writable Function() getWritable,
  cl.Writable Function(cl.BytesReader) fromReader,
) => test("read/write", () {
  final bytes = getWritable().toBytes();
  expect(fromReader(cl.BytesReader(bytes)).toBytes(), bytes);
});

Future<void> waitFor(bool Function() test) {

  final start = DateTime.now();
  final duration = Duration(seconds: 2);

  return Future.doWhile(() async {
    if (DateTime.now().difference(start).compareTo(duration) > 0) {
      fail("Took too long to complete action");
    }
    final cont = !test();
    if (cont) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return cont;
  });

}
