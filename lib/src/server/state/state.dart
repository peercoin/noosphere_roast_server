import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/common.dart';
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'client_session.dart';
import 'dkg.dart';
import 'signatures_coordination.dart';

class ChallengeDetails implements Expirable {
  final Identifier id;
  @override
  final Expiry expiry;
  ChallengeDetails({ required this.id, required this.expiry });
}

/// Caches DKG acknowledgements to support sharing amongst participants. The
/// entirety of the cache will expire together. Participants should usually be
/// online immediately after the DKG is complete so that repopulation of the
/// cache is unlikely required.
class DkgAckCache implements Expirable {
  final Map<Identifier, Signed<DkgAck>> acks = {};
  @override
  final Expiry expiry;
  DkgAckCache(this.expiry);
}

class CompletedSignatures implements Expirable {
  final Signed<SignaturesRequestDetails> details;
  final List<cl.SchnorrSignature> signatures;
  final Identifier creator;
  /// This is not set, but in the future can contain acknowledgements from
  /// participants when they have received the signature so that they do not
  /// receive it again and so that signatures can be removed when enough
  /// participants have obtained it.
  final Set<Identifier> acks = {};
  @override
  final Expiry expiry;
  CompletedSignatures({
    required this.details,
    required this.signatures,
    required this.expiry,
    required this.creator,
  });
}

class ServerState {

  final challenges = ExpirableMap<AuthChallenge, ChallengeDetails>();
  late final ExpirableMap<SessionID, ClientSession> clientSessions;
  final participantToSession = ExpirableMap<Identifier, ClientSession>();
  final nameToDkg = ExpirableMap<String, DkgState>();
  final dkgAckCache = ExpirableMap<cl.ECPublicKey, DkgAckCache>();
  final sigRequests = ExpirableMap<
    SignaturesRequestId, SignaturesCoordinationState
  >();
  final completedSigs = ExpirableMap<
    SignaturesRequestId, CompletedSignatures
  >();

  ServerState() {
    clientSessions = ExpirableMap(
      onExpired: (_, session) => onEndSession(session),
    );
  }

  void onEndSession(ClientSession session) {

    // Reset DKGs to round 1 as all participants need to remain online to
    // complete them
    for (final dkg in nameToDkg.values) {
      if (dkg.round is! DkgRound1State) dkg.round = DkgRound1State([]);
    }

    // Remove public commitment from participant for any round 1 DKGs
    for (final dkg in round1Dkgs) {
      dkg.round1.commitments.removeWhere((c) => c.$1 == session.participantId);
    }

    // Close the client's event stream
    if (!session.eventController.isClosed) session.eventController.close();

    // Send logout event to other participants
    sendEventToAll(
      ParticipantStatusEvent(id: session.participantId, loggedIn: false),
    );

  }

  Iterable<DkgState> get round1Dkgs => nameToDkg.values.where(
    (dkg) => dkg.round is DkgRound1State,
  );

  void sendEventToAll(Event e, { List<SessionID> exclude = const [] }) {
    for (final session in clientSessions.values) {
      if (!exclude.contains(session.sessionID)) session.sendEvent(e);
    }
  }

}
