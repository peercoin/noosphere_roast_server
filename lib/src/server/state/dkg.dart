import 'dart:typed_data';
import 'package:noosphere_roast_client/noosphere_roast_client.dart';

abstract class DkgRoundState {}

/// Round 1 collects commitments from all the participants after they've
/// received the signed DKG details
class DkgRound1State extends DkgRoundState {
  final DkgCommitmentList commitments;
  DkgRound1State(this.commitments);
}

/// Round 2 collects signatures to verify the common dkg hash from all
/// participants and the encrypted secrets to share with particular
/// participants.
class DkgRound2State extends DkgRoundState {
  final Uint8List expectedHash;
  final List<Identifier> participantsProvided = [];
  DkgRound2State({ required this.expectedHash });
}

class DkgState implements Expirable {

  // Saved across the state so that details are available if round 1 needs to
  // be done again.
  final Signed<NewDkgDetails> details;
  final Identifier creator;

  /// The current round information
  DkgRoundState round;

  DkgState({
    required this.details,
    required this.creator,
    required DkgCommitmentList commitments,
  }) : round = DkgRound1State(commitments);

  @override
  Expiry get expiry => details.obj.expiry;

  DkgRound1State get round1 => round as DkgRound1State;
  DkgRound2State get round2 => round as DkgRound2State;

}
