import 'props.dart';
import 'rules.dart';
import 'state.dart';

/// Everything a player can do. Actions are the unit of replay and of lockstep sync: a game is
/// its seed plus its ordered actions.
sealed class GameAction with Props {
  const GameAction();

  Map<String, dynamic> toJson();

  static GameAction fromJson(Map<String, dynamic> j) {
    switch (j['t'] as String) {
      case 'start':
        return StartAction((j['decks'] as List).map((d) => (d as List).cast<String>()).toList(), rules: Rules.fromJson(j['rules'] as Map<String, dynamic>?));
      case 'respond':
        return RespondAction(DecisionResponse.fromJson(j['r'] as Map<String, dynamic>));
      case 'land':
        return PlayLandAction(j['id'] as int);
      case 'cast':
        return CastAction(
          j['id'] as int,
          targets: (j['targets'] as List?)?.cast<int>() ?? const [],
          kicked: j['kicked'] as bool? ?? false,
          mode: j['mode'] as int?,
          beamUpBounce: j['bounce'] as int?,
          x: j['x'] as int? ?? 0,
        );
      case 'activate':
        return ActivateAbilityAction(j['id'] as int, j['ability'] as int, targets: (j['targets'] as List?)?.cast<int>() ?? const [], sacrifice: j['sacrifice'] as int?, discard: j['discard'] as int?);
      case 'station':
        return StationAction(j['ship'] as int, j['creature'] as int);
      case 'equip':
        return EquipAction(j['id'] as int, j['to'] as int);
      case 'cycle':
        return CycleAction(j['id'] as int);
      case 'attackers':
        return DeclareAttackersAction((j['ids'] as List).cast<int>());
      case 'pass':
        return const PassPhaseAction();
      case 'passPriority':
        return const PassPriorityAction();
      case 'endTurn':
        return const EndTurnAction();
      case 'concede':
        return const ConcedeAction();
      case 'timeout':
        return TimeOutAction(j['p'] as int);
    }
    throw ArgumentError('Unknown action ${j['t']}');
  }
}

class StartAction extends GameAction {
  const StartAction(this.decks, {this.rules = Rules.standard}); // card ids per player, in seat order
  final List<List<String>> decks;
  final Rules rules;
  @override
  List<Object?> get props => [decks, rules];
  @override
  Map<String, dynamic> toJson() => {'t': 'start', 'decks': decks, if (!rules.isStandard) 'rules': rules.toJson()};
}

class RespondAction extends GameAction {
  const RespondAction(this.response);
  final DecisionResponse response;
  @override
  List<Object?> get props => [response];
  @override
  Map<String, dynamic> toJson() => {'t': 'respond', 'r': response.toJson()};
}

class PlayLandAction extends GameAction {
  const PlayLandAction(this.id);
  final ObjectID id;
  @override
  List<Object?> get props => [id];
  @override
  Map<String, dynamic> toJson() => {'t': 'land', 'id': id};
}

class CastAction extends GameAction {
  const CastAction(this.id, {this.targets = const [], this.kicked = false, this.mode, this.beamUpBounce, this.x = 0});
  final ObjectID id;
  final List<ObjectID> targets;
  final bool kicked;
  final int? mode;
  final ObjectID? beamUpBounce;

  /// The value of X for a spell with {X} in its cost.
  final int x;
  @override
  List<Object?> get props => [id, targets, kicked, mode, beamUpBounce, x];
  @override
  Map<String, dynamic> toJson() => {'t': 'cast', 'id': id, 'targets': targets, 'kicked': kicked, 'mode': mode, 'bounce': beamUpBounce, if (x != 0) 'x': x};
}

class ActivateAbilityAction extends GameAction {
  const ActivateAbilityAction(this.id, this.ability, {this.targets = const [], this.sacrifice, this.discard});
  final ObjectID id;
  final int ability;
  final List<ObjectID> targets;
  final ObjectID? sacrifice, discard;
  @override
  List<Object?> get props => [id, ability, targets, sacrifice, discard];
  @override
  Map<String, dynamic> toJson() => {'t': 'activate', 'id': id, 'ability': ability, 'targets': targets, 'sacrifice': sacrifice, 'discard': discard};
}

class StationAction extends GameAction {
  const StationAction(this.spacecraft, this.creature);
  final ObjectID spacecraft, creature;
  @override
  List<Object?> get props => [spacecraft, creature];
  @override
  Map<String, dynamic> toJson() => {'t': 'station', 'ship': spacecraft, 'creature': creature};
}

class EquipAction extends GameAction {
  const EquipAction(this.equipment, this.to);
  final ObjectID equipment, to;
  @override
  List<Object?> get props => [equipment, to];
  @override
  Map<String, dynamic> toJson() => {'t': 'equip', 'id': equipment, 'to': to};
}

class CycleAction extends GameAction {
  const CycleAction(this.id);
  final ObjectID id;
  @override
  List<Object?> get props => [id];
  @override
  Map<String, dynamic> toJson() => {'t': 'cycle', 'id': id};
}

class DeclareAttackersAction extends GameAction {
  const DeclareAttackersAction(this.ids);
  final List<ObjectID> ids;
  @override
  List<Object?> get props => [ids];
  @override
  Map<String, dynamic> toJson() => {'t': 'attackers', 'ids': ids};
}

class PassPhaseAction extends GameAction {
  const PassPhaseAction();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'pass'};
}

/// Declines to respond: the spell on top of the stack resolves, or the game moves on.
class PassPriorityAction extends GameAction {
  const PassPriorityAction();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'passPriority'};
}

class EndTurnAction extends GameAction {
  const EndTurnAction();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'endTurn'};
}

class ConcedeAction extends GameAction {
  const ConcedeAction();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'concede'};
}

class TimeOutAction extends GameAction {
  const TimeOutAction(this.player);
  final PlayerID player;
  @override
  List<Object?> get props => [player];
  @override
  Map<String, dynamic> toJson() => {'t': 'timeout', 'p': player};
}

class GameError implements Exception {
  GameError(this.message);
  final String message;
  @override
  String toString() => message;
}
