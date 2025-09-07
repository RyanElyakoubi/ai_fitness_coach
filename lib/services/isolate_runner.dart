import 'dart:async';
import 'dart:isolate';

typedef IsoFn<I, O> = FutureOr<O> Function(I input);

class IsolateRunner {
  static Future<O> run<I, O>(IsoFn<I, O> fn, I input) async {
    final rp = ReceivePort();
    await Isolate.spawn<_IsoPacket<I, O>>(
      _entry<I, O>,
      _IsoPacket(fn, input, rp.sendPort),
      errorsAreFatal: true,
      paused: false,
      onExit: null,
    );
    final res = await rp.first;
    if (res is _IsoErr) {
      throw res.error;
    }
    return (res as O);
  }

  static void _entry<I, O>(_IsoPacket<I, O> packet) async {
    try {
      final out = await packet.fn(packet.input);
      packet.send.send(out);
    } catch (e, st) {
      packet.send.send(_IsoErr(Exception('$e\n$st')));
    }
  }
}

class _IsoPacket<I, O> {
  final IsoFn<I, O> fn;
  final I input;
  final SendPort send;
  _IsoPacket(this.fn, this.input, this.send);
}

class _IsoErr {
  final Exception error;
  _IsoErr(this.error);
}
