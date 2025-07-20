import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'package:noosphere_roast_server/src/config/server.dart';
import 'package:noosphere_roast_server/src/server/state/key_sharing.dart';
import 'state/signatures_coordination.dart';
import 'state/client_session.dart';
import 'state/dkg.dart';
import 'state/state.dart';

/// Provides the logic of the server, implementing the [ApiRequestInterface].
/// Throws an [InvalidRequest] when the server cannot satisfy the request.
///
/// There is no anti-DoS protection.
///
/// The methods should be called sequentially without concurrency.
class ServerApiHandler implements ApiRequestInterface {

  static const currentProtocolVersion = 1;

  final ServerConfig config;
  final ServerState state;

  /// Creates a backend API handler with the [config]. A blank [state] will be
  /// created if not provided.
  ServerApiHandler({
    required this.config,
    ServerState? state,
  }) : state = state ?? ServerState();

  int get _participantN => config.group.participants.length;

  ClientSession getSession(SessionID id) {
    final session = state.clientSessions[id];
    if (session == null) throw InvalidRequest.noSession();
    return session;
  }

  cl.ECPublicKey _getParticipantPubkeyForId(Identifier id) {
    final pubkey = config.group.participants[id];
    if (pubkey == null) throw InvalidRequest.noParticipant();
    return pubkey;
  }

  cl.ECPublicKey _getParticipantPubkeyForSession(ClientSession session)
    => _getParticipantPubkeyForId(session.participantId);

  void _checkParticipantId(Identifier id) => _getParticipantPubkeyForId(id);

  DkgState _getDkg(String name) {
    final dkg = state.nameToDkg[name];
    if (dkg == null) throw InvalidRequest.noDkg();
    return dkg;
  }

  void _verifyExpiry(Expiry expiry, Duration minTTL, Duration maxTTL) {
    if (expiry.ttl.compareTo(minTTL) < 0) throw InvalidRequest.expiryTooSoon();
    if (expiry.ttl.compareTo(maxTTL) > 0) throw InvalidRequest.expiryTooLate();
  }

  @override
  Future<ExpirableAuthChallengeResponse> login({
    required Uint8List groupFingerprint,
    required Identifier participantId,
    int protocolVersion = currentProtocolVersion,
  }) async {

    // Only allow version 1
    if (protocolVersion != currentProtocolVersion) {
      throw InvalidRequest.invalidProtoVersion();
    }

    // Check fingerprint
    if (!cl.bytesEqual(groupFingerprint, config.group.fingerprint)) {
      throw InvalidRequest.groupMismatch();
    }

    _checkParticipantId(participantId);

    // Create challenge
    final challenge = AuthChallenge();
    final expiry = Expiry(config.challengeTTL);

    state.challenges[challenge] = ChallengeDetails(
      id: participantId,
      expiry: expiry,
    );

    return ExpirableAuthChallengeResponse(challenge: challenge, expiry: expiry);

  }

  @override
  Future<LoginCompleteResponse> respondToChallenge(
    Signed<AuthChallenge> signedChallenge,
  ) async {

    // Get participant id for challenge and check expiry
    final details = state.challenges[signedChallenge.obj];
    if (details == null) throw InvalidRequest.noChallenge();
    final participantId = details.id;

    // Verify participant has signed the challenge
    final publickey = config.group.participants[participantId];
    if (publickey == null) throw InvalidRequest.noParticipant();
    if (!signedChallenge.verify(publickey)) {
      throw InvalidRequest.invalidChallengeSig();
    }

    // Success

    // Remove challenge
    state.challenges.remove(signedChallenge.obj);

    // Remove any old session
    final oldSession = state.participantToSession[participantId];
    if (oldSession != null) {
      state.clientSessions.remove(oldSession.sessionID);
      // Ensure removal of old session is handled
      state.onEndSession(oldSession);
    }

    // Obtain other logged in participants
    final online = state.clientSessions.values.map(
      (sess) => sess.participantId,
    ).toSet();

    // Notify other sessions of login before new session is added
    state.sendEventToAll(
      ParticipantStatusEvent(id: participantId, loggedIn: true),
    );

    // Create session
    final sessionId = SessionID();
    final expiry = Expiry(config.sessionTTL);

    final session
      = state.participantToSession[participantId]
      = state.clientSessions[sessionId]
      = ClientSession(
        participantId: participantId,
        sessionID: sessionId,
        expiry: expiry,
        // When the session stream is lost, remove the session and process the
        // logout immediately
        onLostStream: () {
          final sess = state.clientSessions.remove(sessionId);
          if (sess != null) {
            state.participantToSession.remove(participantId);
            state.onEndSession(sess);
          }
        },
      );

    // If using keepalive, send periodic events
    if (config.keepAliveFreq != null) {
      Timer.periodic(config.keepAliveFreq!, (timer) {
        final session = state.clientSessions[sessionId];
        if (session == null) timer.cancel();
        session?.sendEvent(KeepaliveEvent());
      });
    }

    return LoginCompleteResponse(

      id: sessionId,
      expiry: expiry,
      onlineParticipants: online,
      events: session.eventController.stream,

      newDkgs: state.round1Dkgs.map(
        (dkg) => NewDkgEvent(
          details: dkg.details,
          creator: dkg.creator,
          commitments: dkg.round1.commitments,
        ),
      ).toList(),

      sigRequests: state.sigRequests.values.map(
        (sig) => SignaturesRequestEvent(
          details: sig.details, creator: sig.creator,
        ),
      ).toList(),

      // Find rounds that the user is part of and hasn't provided a share yet
      sigRounds: state.sigRequests.values.map(
        (sigReq) => SignatureNewRoundsEvent(
          reqId: sigReq.details.obj.id,
          rounds: sigReq.pendingRoundsForId(participantId),
        ),
      ).where((newRounds) => newRounds.rounds.isNotEmpty).toList(),

      completedSigs: state.completedSigs.values
      .where((sigs) => !sigs.acks.contains(participantId))
      .map(
        (sigs) => CompletedSignaturesRequest(
          details: sigs.details,
          signatures: sigs.signatures,
          creator: sigs.creator,
        ),
      ).toList(),

      secretShares: [
        for (
          final MapEntry(key: groupKey, value: sharingState)
          in state.secretShares.entries
        ) ...sharingState.getSharesForReceiver(participantId).map(
          (share) => SecretShareEvent(
            sender: share.sender,
            keyShare: share.share,
            groupKey: groupKey,
          ),
        ),
      ],

    );

  }

  @override
  Future<Expiry> extendSession(SessionID sid) async {
    final session = getSession(sid);
    return session.expiry = Expiry(config.sessionTTL);
  }

  @override
  Future<void> requestNewDkg({
    required SessionID sid,
    required Signed<NewDkgDetails> signedDetails,
    required DkgPublicCommitment commitment,
  }) async {

    final session = getSession(sid);
    final details = signedDetails.obj;

    // Check threshold
    if (details.threshold > _participantN) {
      throw InvalidRequest.invalidThreshold();
    }

    // Check expiry is within bounds
    _verifyExpiry(
      details.expiry, config.minDkgRequestTTL, config.maxDkgRequestTTL,
    );

    // Check if name exists in DKG requests already
    if (state.nameToDkg.containsKey(details.name)) {
      throw InvalidRequest.dkgRequestExists();
    }

    // Verify details
    if (!signedDetails.verify(_getParticipantPubkeyForSession(session))) {
      throw InvalidRequest.invalidDkgReqSig();
    }

    // Create event to share with participants
    final commitments = [(session.participantId, commitment)];
    final dkgEvent = NewDkgEvent(
      details: signedDetails,
      creator: session.participantId,
      commitments: commitments,
    );

    // Store request
    state.nameToDkg[details.name] = DkgState(
      details: dkgEvent.details,
      creator: dkgEvent.creator,
      commitments: commitments,
    );

    // Broadcast to other participants
    state.sendEventToAll(dkgEvent, exclude: [sid]);

  }

  @override
  Future<void> rejectDkg({required SessionID sid, required String name}) async {
    final participantId = getSession(sid).participantId;
    if (state.nameToDkg.remove(name) != null) {
      // Send an event to all other participants that the DKG was removed
      state.sendEventToAll(
        DkgRejectEvent(name: name, participant: participantId),
        exclude: [sid],
      );
    }
  }

  @override
  Future<void> submitDkgCommitment({
    required SessionID sid,
    required String name,
    required DkgPublicCommitment commitment,
  }) async {

    final session = getSession(sid);
    final pid = session.participantId;

    // Look for round1 DKG of the name
    final dkg = _getDkg(name);
    if (dkg.round is! DkgRound1State) throw InvalidRequest.notRound1Dkg();

    // Add commitment if it doesn't already exist for this participant
    final commitments = dkg.round1.commitments;
    if (commitments.any((c) => c.$1 == pid)) {
      throw InvalidRequest.dkgCommitmentExists();
    }
    commitments.add((pid, commitment));

    // If all commitments have been received, move onto round 2
    if (commitments.length == _participantN) {
      final commitmentSet = DkgCommitmentSet(commitments);
      dkg.round = DkgRound2State(
        expectedHash: dkg.details.obj.hashWithCommitments(commitmentSet),
      );
    }

    // Send commitment to other participants
    state.sendEventToAll(
      DkgCommitmentEvent(name: name, participant: pid, commitment: commitment),
      exclude: [sid],
    );

  }

  @override
  Future<void> submitDkgRound2({
    required SessionID sid,
    required String name,
    required cl.SchnorrSignature commitmentSetSignature,
    required Map<Identifier, DkgEncryptedSecret> secrets,
  }) async {

    final session = getSession(sid);
    final dkg = _getDkg(name);
    if (dkg.round is! DkgRound2State) throw InvalidRequest.notRound2Dkg();
    final round = dkg.round2;

    // Verify signature
    if (
      !commitmentSetSignature.verify(
        _getParticipantPubkeyForSession(session),
        round.expectedHash,
      )
    ) {
      throw InvalidRequest.invalidDkgCommitmentSetSignature();
    }

    // Do not allow a participant to submit round2 twice
    if (round.participantsProvided.contains(session.participantId)) {
      throw InvalidRequest.dkgRound2Sent();
    }

    if (secrets.length != _participantN - 1) {
      throw InvalidRequest.invalidSecretMap();
    }

    // Send the signature and secrets to other participants
    for (final otherSess in state.clientSessions.values) {
      if (otherSess.sessionID != sid) {

        final secret = secrets[otherSess.participantId];
        if (secret == null) throw InvalidRequest.invalidSecretMap();

        otherSess.sendEvent(
          DkgRound2ShareEvent(
            name: name,
            commitmentSetSignature: commitmentSetSignature,
            sender: session.participantId,
            secret: secret,
          ),
        );

      }
    }

    // If all participants have provided a signature, the DKG is complete
    if (round.participantsProvided.length == _participantN - 1) {
      // Remove DKG
      state.nameToDkg.remove(name);
      // No details of the key are stored on the server as only the participants
      // can generate the public information at this point.
    } else {
      // Record that the participant has provided round 2
      round.participantsProvided.add(session.participantId);
    }

  }

  @override
  Future<void> sendDkgAcks({
    required SessionID sid,
    required Set<SignedDkgAck> acks,
  }) async {

    getSession(sid);

    // Verify signatures
    if (
      acks.any(
        (ack) => !ack.signed.verify(_getParticipantPubkeyForId(ack.signer)),
      )
    ) {
      throw InvalidRequest.invalidDkgAckSignature();
    }

    final Set<SignedDkgAck> newAcks = {};

    for (final ack in acks) {

      final ackCache = state.dkgAckCache[ack.signed.obj.groupKey]
        ??= DkgAckCache(Expiry(config.ackCacheTTL));

      // If ACK already exists in cache, override if changing from false to true
      // Otherwise do nothing and continue
      final prevAck = ackCache.acks[ack.signer]?.obj;
      if (prevAck != null && (prevAck.accepted || !ack.signed.obj.accepted)) {
        continue;
      }

      // Add new ACK to cache
      ackCache.acks[ack.signer] = ack.signed;

      // Record as new ACK to send
      newAcks.add(ack);

    }

    // Do not send events if there are no new ACKs
    if (newAcks.isEmpty) return;

    // Send ACKs to participants, ensuring that their own ACKs aren't sent
    // Do not send to calling participant
    for (
      final session in state.clientSessions.values.where(
        (s) => s.sessionID != sid,
      )
    ) {
      final toSend = newAcks.where(
        (ack) => ack.signer != session.participantId,
      ).toSet();
      if (toSend.isNotEmpty) session.sendEvent(DkgAckEvent(toSend));
    }

  }

  @override
  Future<Set<SignedDkgAck>> requestDkgAcks({
    required SessionID sid,
    required Set<DkgAckRequest> requests,
  }) async {

    final session = getSession(sid);

    // Ensure all ids exist
    for (final id in [for (final req in requests) ...req.ids]) {
      _checkParticipantId(id);
      if (id == session.participantId) {
        throw InvalidRequest.cannotRequestSelfAck();
      }
    }

    // Record ACKs that the server has
    final Set<SignedDkgAck> have = {};

    // Add requests for ACKs we do not have
    final Set<DkgAckRequest> need = {};

    for (final request in requests) {

      // Get cache for this key
      final cache = state.dkgAckCache[request.groupPublicKey];

      if (cache == null) {
        // No DKGs for this key so pass full request
        need.add(request);
        continue;
      }

      // Obtain those we have and request what we don't
      final Set<Identifier> idsToReq = {};
      for (final id in request.ids) {
        final ack = cache.acks[id];
        if (ack == null) {
          idsToReq.add(id);
        } else {
          have.add(SignedDkgAck(signer: id, signed: ack));
        }
      }

      // If we have any missing ACKs, add a request
      if (idsToReq.isNotEmpty) {
        need.add(
          DkgAckRequest(
            ids: idsToReq, groupPublicKey: request.groupPublicKey,
          ),
        );
      }

    }

    if (need.isNotEmpty) {
      // Send DkgAckRequestEvents for missing ACKs
      state.sendEventToAll(DkgAckRequestEvent(need), exclude: [sid]);
    }

    // Return found ACKS
    return have;

  }

  @override
  Future<void> requestSignatures({
    required SessionID sid,
    required Set<AggregateKeyInfo> keys,
    required Signed<SignaturesRequestDetails> signedDetails,
    required List<SigningCommitment> commitments,
  }) async {

    final session = getSession(sid);
    final details = signedDetails.obj;
    final pid = session.participantId;

    // Require commitments for all signatures
    final numSigs = details.requiredSigs.length;
    if (commitments.length != numSigs) {
      throw InvalidRequest.wrongCommitmentNum();
    }

    // Require all keys for requested signatures and no more
    if (
      !SetEquality<cl.ECCompressedPublicKey>().equals(
        keys.map((info) => info.groupKey).toSet(),
        details.requiredSigs.map((sig) => sig.groupKey).toSet(),
      )
    ) {
      throw InvalidRequest.wrongSigKeys();
    }

    // Verify expiry
    _verifyExpiry(
      details.expiry,
      config.minSignaturesRequestTTL,
      config.maxSignaturesRequestTTL,
    );

    // Verify request doesn't already exist
    if (state.sigRequests.containsKey(details.id)) {
      throw InvalidRequest.sigRequestExists();
    }

    // Verify request signature
    if (!signedDetails.verify(_getParticipantPubkeyForSession(session))) {
      throw InvalidRequest.invalidSigReqSignature();
    }

    // Create state for request
    final reqState = state.sigRequests[details.id] = SignaturesCoordinationState(
      details: signedDetails,
      creator: pid,
      keys: keys,
    );

    // Add commitments from creator
    for (int i = 0; i < numSigs; i++) {
      (reqState.sigs[i] as SingleSignatureInProgressState)
        .nextCommitments[pid] = commitments[i];
    }

    // Send request event to participants
    state.sendEventToAll(
      SignaturesRequestEvent(
        details: signedDetails,
        creator: session.participantId,
      ),
      exclude: [sid],
    );

  }

  void _checkSigReqFail(SignaturesCoordinationState sigReqState) {

    final malAndRej
      = sigReqState.malicious.length + sigReqState.rejectors.length;
    final available = _participantN - malAndRej;

    final maxThreshold
      = sigReqState.sigs
      .whereType<SingleSignatureInProgressState>()
      .fold(0, (v, e) => max(v, e.key.group.threshold));

    if (available < maxThreshold) {
      // Cannot sign one of the signatures as threshold is too high
      final id = sigReqState.details.obj.id;
      state.sendEventToAll(SignaturesFailureEvent(id));
      state.sigRequests.remove(id);
    }

  }

  @override
  Future<void> rejectSignaturesRequest({
    required SessionID sid,
    required SignaturesRequestId reqId,
  }) async {

    final pid = getSession(sid).participantId;

    final sigReq = state.sigRequests[reqId];
    // Ignore if the request doesn't exist as this may have been previously
    // rejected or completed before the client knows
    if (sigReq == null) return;

    // If already malicious, do not consider as rejector
    if (sigReq.malicious.contains(pid)) return;

    sigReq.rejectors.add(pid);
    _checkSigReqFail(sigReq);

  }

  @override
  Future<SignaturesResponse?> submitSignatureReplies({
    required SessionID sid,
    required SignaturesRequestId reqId,
    required List<SignatureReply> replies,
  }) async {

    final pid = getSession(sid).participantId;

    final sigReq = state.sigRequests[reqId];
    // Ignore if the request doesn't exist in case it was rejected or completed
    if (sigReq == null) return null;

    final sigDetails = sigReq.details.obj;

    void throwMalicious(InvalidRequest exp) {
      sigReq.malicious.add(pid);
      _checkSigReqFail(sigReq);
      throw exp;
    }

    if (sigReq.malicious.contains(pid)) {
      throw InvalidRequest.markedMalicious();
    }

    // No longer consider a rejector if it was
    sigReq.rejectors.remove(pid);

    if (replies.isEmpty) {
      throwMalicious(InvalidRequest.emptySigReply());
    }

    // Ensure no duplicate replies
    if (replies.map((resp) => resp.sigI).toSet().length != replies.length) {
      throwMalicious(InvalidRequest.duplicateSigReply());
    }

    // Record new rounds that are started for each participant
    final Map<Identifier, List<SignatureRoundStart>> newRounds = {};

    // Loop through provided replies and process for each signature
    for (final reply in replies) {

      final sigI = reply.sigI;

      if (sigI >= sigDetails.requiredSigs.length) {
        throwMalicious(InvalidRequest.invalidSigIndex());
      }

      var sigState = sigReq.sigs[sigI];

      if (sigState is! SingleSignatureInProgressState) {
        // Ignore signatures that are done
        continue;
      }

      if (sigState.nextCommitments.containsKey(pid)) {
        // Already have commitment waiting for complete set
        throwMalicious(InvalidRequest.nextCommitmentExists());
      }

      final round = sigState.roundForId[pid];
      final threshold = sigState.key.group.threshold;

      if (round == null) {
        if (reply.share != null) {
          throwMalicious(InvalidRequest.unsolicitedShare());
        }
      } else {
        // Process signature share

        final share = reply.share;
        if (share == null) {
          throwMalicious(InvalidRequest.missingShare());
          return null;
        }

        final singleSigDetails = sigDetails.requiredSigs[sigI];
        final derivedKey = singleSigDetails.derive(
          HDAggregateKeyInfo.masterFromInfo(sigState.key),
        );

        // ShareVal: validation of provided signature share
        if (
          !verifySignatureShare(
            commitments: round.commitments,
            details: singleSigDetails.signDetails,
            id: pid,
            share: share,
            publicShare: derivedKey.publicShares.list
              .firstWhere((share) => share.$1 == pid).$2,
            groupKey: derivedKey.groupKey,
          )
        ) {
          throwMalicious(InvalidRequest.invalidShare());
        }

        // Share is OK. Add share for round
        round.shares.add((pid, share));

        // If all shares have been received, aggregate and complete this
        // signature
        if (round.shares.length == threshold) {

          final signature = SignatureAggregation(
            commitments: round.commitments,
            details: singleSigDetails.signDetails,
            shares: round.shares,
            info: derivedKey,
          ).signature;

          sigState
            = sigReq.sigs[sigI]
            = SingleSignatureFinishedState(signature);

        }

      }

      // Add next commitment if not already finished
      if (sigState is SingleSignatureInProgressState) {

        final commitments = sigState.nextCommitments;
        commitments[pid] = reply.nextCommitment;

        // If we have enough commitments, create new round
        if (commitments.length == threshold) {

          final commitmentSet = SigningCommitmentSet(commitments);
          final round = SignatureRoundState(commitmentSet);

          final roundStart = SignatureRoundStart(
            sigI: sigI,
            commitments: commitmentSet,
          );

          // Store round information for all included participants
          for (final id in commitments.keys) {
            sigState.roundForId[id] = round;
            if (newRounds.containsKey(id)) {
              newRounds[id]!.add(roundStart);
            } else {
              newRounds[id] = [roundStart];
            }
          }

          // Clear next commitments to collect for next round
          sigState.nextCommitments.clear();

        }

      }

    }

    // If all signatures have been completed, submit event and respond with them
    if (sigReq.sigs.every((sig) => sig is SingleSignatureFinishedState)) {

      final signatures = sigReq.sigs
        .cast<SingleSignatureFinishedState>()
        .map((sig) => sig.signature).toList();

      // The expiry of the completed signatures should be at least the minimum
      final completedExpiry
        = sigReq.expiry.ttl < config.minCompletedSignaturesTTL
        ? Expiry(config.minCompletedSignaturesTTL)
        : sigReq.expiry;

      // Store signatures to share with other participants when they are online
      // and wait to receive enough ACKs before deleting from server.
      state.completedSigs[reqId] = CompletedSignatures(
        details: sigReq.details,
        signatures: signatures,
        expiry: completedExpiry,
        creator: sigReq.creator,
      );

      // Remove signature request as it is completed now
      state.sigRequests.remove(reqId);

      state.sendEventToAll(
        SignaturesCompleteEvent(reqId: reqId, signatures: signatures),
        exclude: [sid],
      );

      return SignaturesCompleteResponse(signatures);

    }

    // If there are any new rounds, return them and send events to round
    // participants
    if (newRounds.isNotEmpty) {

      for (final id in newRounds.keys.where((id) => id != pid)) {
        state.participantToSession[id]?.sendEvent(
          SignatureNewRoundsEvent(reqId: reqId, rounds: newRounds[id]!),
        );
      }

      return SignatureNewRoundsResponse(newRounds[pid]!);

    }

    // Nothing to provide otherwise
    return null;

  }

  @override
  Future<void> shareSecretShare({
    required SessionID sid,
    required cl.ECCompressedPublicKey groupKey,
    required Map<Identifier, EncryptedKeyShare> encryptedSecrets,
  }) async {

    final session = getSession(sid);
    final pid = session.participantId;

    // Cannot be empty
    if (encryptedSecrets.isEmpty) throw InvalidRequest.invalidKeyShareMap();

    // Cannot send to self
    if (encryptedSecrets.containsKey(pid)) {
      throw InvalidRequest.invalidKeyShareMap();
    }

    // Must contain identifiers in group
    if (
      encryptedSecrets.keys.any(
        (id) => !config.group.participants.containsKey(id),
      )
    ) {
      throw InvalidRequest.invalidKeyShareMap();
    }

    // Store ciphertexts
    final stateMap = state.secretShares[groupKey] ??= KeySharingState();

    // Add useable shares to state and ignore those that weren't
    encryptedSecrets.removeWhere(
      (id, share) => !stateMap.maybeAddShare(pid, id, share),
    );

    // Send ciphertexts to other participants that are online
    for (final MapEntry(key:id, value:share) in encryptedSecrets.entries) {
      state.participantToSession[id]?.sendEvent(
        SecretShareEvent(sender: pid, keyShare: share, groupKey: groupKey),
      );
    }

  }

  /// Closes all client session streams
  Future<void> shutdown() => Future.wait(
    state.clientSessions.values.map(
      (session) => session.eventController.close(),
    ),
  );

}
