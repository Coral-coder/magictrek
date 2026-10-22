import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

enum Fx { tap, confirm, deny, draw, attack, damage, alert, victory, defeat, chirp }

/// Haptics and the little LCARS console beeps, synthesised at launch so no audio files are needed.
class Console {
  Console._();
  static final Console shared = Console._();
  bool soundOn = true, hapticsOn = true;
  final Map<Fx, Uint8List> _waves = {};
  final List<AudioPlayer> _players = [];
  int _next = 0;

  Future<void> init() async {
    for (final fx in Fx.values) {
      _waves[fx] = _wave(fx);
    }
    for (var i = 0; i < 3; i++) {
      try {
        final p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setVolume(0.5);
        _players.add(p);
      } catch (_) {
        break; // no audio on this platform (tests)
      }
    }
  }

  void play(Fx fx) {
    if (soundOn && _players.isNotEmpty) {
      final p = _players[_next++ % _players.length];
      final bytes = _waves[fx];
      if (bytes != null) p.play(BytesSource(bytes, mimeType: 'audio/wav')).catchError((_) {});
    }
    if (!hapticsOn) return;
    switch (fx) {
      case Fx.tap:
      case Fx.draw:
      case Fx.chirp:
        HapticFeedback.lightImpact();
      case Fx.attack:
      case Fx.damage:
        HapticFeedback.heavyImpact();
      case Fx.confirm:
      case Fx.victory:
        HapticFeedback.mediumImpact();
      case Fx.deny:
      case Fx.defeat:
      case Fx.alert:
        HapticFeedback.vibrate();
    }
  }

  /// A short tone sequence as 16-bit mono WAV.
  static Uint8List _wave(Fx fx) {
    const rate = 22050.0;
    final notes = switch (fx) {
      Fx.tap => [(1400.0, 0.03)],
      Fx.chirp => [(1800.0, 0.03), (2400.0, 0.04)],
      Fx.confirm => [(900.0, 0.05), (1300.0, 0.07)],
      Fx.deny => [(400.0, 0.08), (300.0, 0.1)],
      Fx.draw => [(1100.0, 0.03), (1500.0, 0.03)],
      Fx.attack => [(600.0, 0.05), (900.0, 0.05), (1200.0, 0.08)],
      Fx.damage => [(200.0, 0.12)],
      Fx.alert => [(880.0, 0.12), (660.0, 0.12), (880.0, 0.12)],
      Fx.victory => [(660.0, 0.1), (880.0, 0.1), (1100.0, 0.1), (1320.0, 0.25)],
      Fx.defeat => [(500.0, 0.15), (400.0, 0.15), (300.0, 0.3)],
    };
    final samples = <int>[];
    for (final (f, d) in notes) {
      final n = (rate * d).round();
      for (var i = 0; i < n; i++) {
        final t = i / rate;
        final env = math.min(1.0, i / 200) * math.min(1.0, (n - i) / 400);
        samples.add((math.sin(2 * math.pi * f * t) * 12000 * env).round());
      }
    }
    final byteCount = samples.length * 2;
    final b = BytesBuilder();
    void put32(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
    void put16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
    b.add('RIFF'.codeUnits);
    put32(36 + byteCount);
    b.add('WAVE'.codeUnits);
    b.add('fmt '.codeUnits);
    put32(16);
    put16(1);
    put16(1);
    put32(rate.toInt());
    put32(rate.toInt() * 2);
    put16(2);
    put16(16);
    b.add('data'.codeUnits);
    put32(byteCount);
    for (final s in samples) {
      put16(s & 0xFFFF);
    }
    return b.toBytes();
  }
}
