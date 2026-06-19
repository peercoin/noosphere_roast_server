import 'package:noosphere_roast_client/noosphere_roast_client.dart';

class KeyShareFromSender {
  final EncryptedKeyShare share;
  final Identifier sender;
  KeyShareFromSender({required this.share, required this.sender});
}

/// The encrypted key shares stored by the server for a given FROST key
class KeySharingState {
  /// The stored encrypted shares for a given recipient.
  final Map<Identifier, ParticipantShareState> receiverShares = {};

  /// Returns true if the receiver can use the share and it was added to the
  /// state
  bool maybeAddShare(
    Identifier sender,
    Identifier receiver,
    EncryptedKeyShare share,
  ) {
    final shareState =
        receiverShares[receiver] ??= ParticipantPendingShareState();

    if (shareState is ParticipantPendingShareState &&
        !shareState.haveForSender(sender)) {
      shareState.pendingForSender[sender] = share;
      return true;
    }

    return false;
  }

  List<KeyShareFromSender> getSharesForReceiver(Identifier receiver) =>
      receiverShares[receiver]?.pendingShares ?? [];

  List<ConstructedKeyEvent> eventsForCompleted(Iterable<Identifier> ids) => ids
      .map((id) => receiverShares[id])
      .whereType<ParticipantDoneShareState>()
      .map((state) => state.constructedEvent)
      .toList();
}

sealed class ParticipantShareState {
  List<KeyShareFromSender> get pendingShares => [];
}

class ParticipantPendingShareState extends ParticipantShareState {
  /// The encrypted key shares that the server has for the participant
  final Map<Identifier, EncryptedKeyShare> pendingForSender = {};

  bool haveForSender(Identifier sender) => pendingForSender.containsKey(sender);

  @override
  List<KeyShareFromSender> get pendingShares => pendingForSender.entries
      .map(
        (entry) => KeyShareFromSender(share: entry.value, sender: entry.key),
      )
      .toList();
}

/// Used after the participant acknowledged the completion of the construction
/// of the FROST key's private key
class ParticipantDoneShareState extends ParticipantShareState {
  final ConstructedKeyEvent constructedEvent;
  ParticipantDoneShareState(this.constructedEvent);
}
