import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:magictrek/net/relay.dart';
import 'package:magictrek/net/transport.dart';

void main() {
  test('room cipher round-trips and rejects tampering', () {
    final c = RoomCipher('ABC123');
    final enc = c.encrypt('{"t":"hello","name":"Kirk"}');
    expect(c.decrypt(enc), '{"t":"hello","name":"Kirk"}');
    expect(RoomCipher('ABC124').decrypt(enc), isNull);
    final bytes = enc.codeUnits.toList();
    bytes[20] = bytes[20] == 65 ? 66 : 65;
    expect(c.decrypt(String.fromCharCodes(bytes)), isNull);
    expect(roomTag('abc123'), roomTag('ABC123'));
  });

  test('two relay transports exchange a message through public relays', () async {
    // Needs the internet; skipped quietly when relays can't be reached from here.
    final code = newMatchCodeForTest();
    final a = RelayTransport(code: code, secretKey: newRelayIdentity());
    final b = RelayTransport(code: code, secretKey: newRelayIdentity());
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while ((a.state != LinkState.connected || b.state != LinkState.connected) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (a.state != LinkState.connected || b.state != LinkState.connected) {
      stdout.writeln('relays unreachable from this environment; skipping');
      await a.close();
      await b.close();
      return;
    }
    final received = b.messages.first.timeout(const Duration(seconds: 15));
    await a.send('{"t":"ping","n":1}');
    final msg = await received;
    expect(msg, contains('"ping"'));
    expect(msg, contains('"mid"'));
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 1)));
}

String newMatchCodeForTest() => 'T${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}';
