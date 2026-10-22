import 'props.dart';

/// The adjustable rules of a game. They travel inside the [StartAction], so a saved game
/// replays with the rules it was started under and both phones of a linked match play by the
/// host's settings; they are part of the state digest too.
class Rules with Props {
  const Rules({this.startingLife = 20, this.handSize = 7, this.londonMulligan = true, this.freeMulligan = false, this.firstPlayerDraws = false, this.maxHandSize = true});

  static const standard = Rules();

  /// Life each player starts with (20 in a normal game; Commander uses 40).
  final int startingLife;

  /// Cards in the opening hand, and the maximum hand size when [maxHandSize] is on.
  final int handSize;

  /// London mulligan: draw a full hand again and put one card per mulligan on the bottom of the
  /// library. Off, each mulligan simply draws one card fewer.
  final bool londonMulligan;

  /// The first mulligan costs nothing (the Commander convention).
  final bool freeMulligan;

  /// Whether the player going first also draws on turn one (normally they skip it).
  final bool firstPlayerDraws;

  /// Discard down to [handSize] at the end of the turn.
  final bool maxHandSize;

  Rules copyWith({int? startingLife, int? handSize, bool? londonMulligan, bool? freeMulligan, bool? firstPlayerDraws, bool? maxHandSize}) => Rules(
    startingLife: startingLife ?? this.startingLife,
    handSize: handSize ?? this.handSize,
    londonMulligan: londonMulligan ?? this.londonMulligan,
    freeMulligan: freeMulligan ?? this.freeMulligan,
    firstPlayerDraws: firstPlayerDraws ?? this.firstPlayerDraws,
    maxHandSize: maxHandSize ?? this.maxHandSize,
  );

  Map<String, dynamic> toJson() => {'life': startingLife, 'hand': handSize, 'london': londonMulligan, 'freeMulligan': freeMulligan, 'firstDraws': firstPlayerDraws, 'maxHand': maxHandSize};

  /// Missing keys take the standard value, so older saves and peers still load.
  static Rules fromJson(Map<String, dynamic>? j) {
    if (j == null) return standard;
    return Rules(
      startingLife: (j['life'] as num?)?.toInt() ?? 20,
      handSize: (j['hand'] as num?)?.toInt() ?? 7,
      londonMulligan: j['london'] as bool? ?? true,
      freeMulligan: j['freeMulligan'] as bool? ?? false,
      firstPlayerDraws: j['firstDraws'] as bool? ?? false,
      maxHandSize: j['maxHand'] as bool? ?? true,
    );
  }

  /// One line for the captain's log and lobbies.
  String get summary {
    final parts = <String>['$startingLife life', '$handSize-card hands', londonMulligan ? 'London mulligan' : 'classic mulligan'];
    if (freeMulligan) parts.add('first mulligan free');
    if (firstPlayerDraws) parts.add('first player draws');
    if (!maxHandSize) parts.add('no maximum hand size');
    return parts.join(', ');
  }

  bool get isStandard => this == standard;

  @override
  List<Object?> get props => [startingLife, handSize, londonMulligan, freeMulligan, firstPlayerDraws, maxHandSize];

  String digest() => props.join('/');
}
