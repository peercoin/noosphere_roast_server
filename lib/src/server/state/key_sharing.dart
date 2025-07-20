import 'package:noosphere_roast_client/noosphere_roast_client.dart';

class KeyShareFromSender {
  final EncryptedKeyShare share;
  final Identifier sender;
  KeyShareFromSender({ required this.share, required this.sender});
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

    final shareState = receiverShares[receiver] ??= ParticipantPendingShareState();

    if (
      shareState is ParticipantPendingShareState
      && !shareState.haveForSender(sender)
    ) {
      shareState.pendingForSender[sender] = share;
      return true;
    }

    return false;

  }

  List<KeyShareFromSender> getSharesForReceiver(Identifier receiver)
    => receiverShares[receiver]?.pendingShares ?? [];

}

sealed class ParticipantShareState {
  List<KeyShareFromSender> get pendingShares => [];
}

class ParticipantPendingShareState extends ParticipantShareState {

  /// The encrypted key shares that have not been acknowledged as received
  final Map<Identifier, EncryptedKeyShare> pendingForSender = {};
  /// The senders of the key shares that have been acknowledged as received
  final Set<Identifier> acknowledgedForSender = {};

  bool haveForSender(Identifier sender)
    => pendingForSender.containsKey(sender)
    || acknowledgedForSender.contains(sender);

  @override
  List<KeyShareFromSender> get pendingShares => pendingForSender.entries.map(
    (entry) => KeyShareFromSender(share: entry.value, sender: entry.key),
  ).toList();

}

class ParticipantDoneShareState extends ParticipantShareState {}
