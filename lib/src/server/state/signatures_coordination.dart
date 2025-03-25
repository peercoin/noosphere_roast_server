import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';

/// The ROAST round state for a single signature
class SignatureRoundState {
  final SigningCommitmentSet commitments;
  final ShareList shares = [];
  SignatureRoundState(this.commitments);
}

/// State for a single signature
sealed class SingleSignatureState {}

/// ROAST state for a signature that is not finished
class SingleSignatureInProgressState extends SingleSignatureState {

  /// The master key info required for this signature
  final AggregateKeyInfo key;
  /// The collected commitments for the next round
  final SigningCommitmentMap nextCommitments = {};
  /// Maps the participant identifiers to the ROAST rounds.
  final Map<Identifier, SignatureRoundState> roundForId = {};

  SingleSignatureInProgressState(this.key);

}

/// A completed signature
class SingleSignatureFinishedState extends SingleSignatureState {
  final cl.SchnorrSignature signature;
  SingleSignatureFinishedState(this.signature);
}

/// Handles the state for ROAST signature coordination for a set of requested
/// signatures.
class SignaturesCoordinationState implements Expirable {

  final Signed<SignaturesRequestDetails> details;
  final Identifier creator;
  final List<SingleSignatureState> sigs;

  /// Participants that are determined to be malicious
  final Set<Identifier> malicious = {};
  /// Participants that reject a request will be stored here unless they
  /// withdraw the rejection.
  final Set<Identifier> rejectors = {};

  SignaturesCoordinationState({
    required this.details,
    required this.creator,
    required Set<AggregateKeyInfo> keys,
  }) : sigs = details.obj.requiredSigs.map(
    (reqSig) => SingleSignatureInProgressState(
      keys.firstWhere((k) => k.groupKey == reqSig.groupKey),
    ) as SingleSignatureState,
  ).toList();

  @override
  Expiry get expiry => details.obj.expiry;

  List<SignatureRoundStart> pendingRoundsForId(Identifier id) {

    final List<SignatureRoundStart> rounds = [];

    for (int i = 0; i < sigs.length; i++) {

      final sig = sigs[i];

      // Id must be in a round
      if (
        sig is! SingleSignatureInProgressState
        || !sig.roundForId.containsKey(id)
      ) {
        continue;
      }

      final round = sig.roundForId[id]!;

      // Cannot have already provided a share
      if (round.shares.any((share) => share.$1 == id)) continue;

      rounds.add(SignatureRoundStart(sigI: i, commitments: round.commitments));

    }

    return rounds;

  }

}
