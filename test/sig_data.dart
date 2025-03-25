import 'dart:typed_data';
import 'package:noosphere_roast_server/noosphere_roast_server.dart';
import 'data.dart';
import 'test_keys.dart';

ParticipantKeyInfo getParticipantKeyInfo({ int i = 0, int? tweak }) {
  final key = ParticipantKeyInfo.fromHex(keyInfoHex[i]);
  return tweak == null ? key : key.tweak(Uint8List(32)..last = tweak)!;
}

AggregateKeyInfo getAggregateKeyInfo({ int? tweak })
  => getParticipantKeyInfo(i: 0, tweak: tweak).aggregate;

List<ParticipantKeyInfo> generateNewKey(int threshold) {

  final part1s = List.generate(
    10, (i) => DkgPart1(identifier: ids[i], threshold: threshold, n: 10),
  );

  final commitmentSet = DkgCommitmentSet(
    List.generate(10, (i) => (ids[i], part1s[i].public)),
  );

  final part2s = List.generate(
    10,
    (i) => DkgPart2(
      identifier: ids[i],
      round1Secret: part1s[i].secret,
      commitments: commitmentSet,
    ),
  );

  final shares = List.generate(
    10, (i) => {
      for (int j = 0; j < 10; j++)
        if (j != i) ids[j] : part2s[j].sharesToGive[ids[i]]!,
    },
  );

  return List.generate(
    10,
    (i) => DkgPart3(
      identifier: ids[i],
      round2Secret: part2s[i].secret,
      commitments: commitmentSet,
      receivedShares: shares[i],
    ).participantInfo,
  );

}

SignDetails getSignDetails([ int? tweak ]) => SignDetails.keySpend(
  message: Uint8List(32)..last = tweak ?? 0,
);

SingleSignatureDetails getSingleSigDetails({ int? tweak })
  => SingleSignatureDetails(
    signDetails: getSignDetails(tweak),
    groupKey: getAggregateKeyInfo(tweak: tweak).groupKey,
    hdDerivation: [],
  );

SignaturesRequestDetails getSignaturesDetails({
  List<int> singleSigTweaks = const [0],
  SignatureMetadata? metadata,
  Expiry? expiry,
}) => SignaturesRequestDetails(
  requiredSigs: [
    for (final tweak in singleSigTweaks) getSingleSigDetails(tweak: tweak),
  ],
  expiry: expiry ?? futureExpiry,
);

SignPart1 getSignPart1({ int i = 0, int? tweak }) => SignPart1(
  privateShare: getParticipantKeyInfo(i: i, tweak: tweak).private.share,
);

SignPart2 dummyPart2() {

  final part1s = List.generate(2, (i) => getSignPart1(i: i));

  return SignPart2(
    identifier: ids.first,
    details: getSignDetails(),
    ourNonces: part1s.first.nonces,
    commitments: SigningCommitmentSet(
      { for (int i = 0; i < 2; i++) ids[i]: part1s[i].commitment },
    ),
    info: getParticipantKeyInfo().signing,
  );

}
