import 'package:noosphere_roast_client/noosphere_roast_client.dart';
import 'package:test/test.dart';
import 'data.dart';
import 'sig_data.dart';
import 'test_keys.dart';

final oldVersionHex =
    "035582770be7cf86a6328765af71fd359dce106204b099e9853f99d83022e3ea5104000a0000000000000000000000000000000000000000000000000000000000000000010384a901676249450c2d2fd440e85eb08fbd176aaf2e38ff97b73e4b6d5e4c241f000000000000000000000000000000000000000000000000000000000000000202fe75ca3fa68401630bf2a01a340ea57782c6fd16be347ebca7bb459cecf7ec8800000000000000000000000000000000000000000000000000000000000000030225f4458d071caece540ee096157f0979e1be9e85aa69ce83899f4d60b746363f0000000000000000000000000000000000000000000000000000000000000004037b7ab42b7e78e5a8eeec164745e6a2a74d70db4026936b24e12fcde10a05d4fc0000000000000000000000000000000000000000000000000000000000000005029d31dd521001760121c8463af7388c760a488c1b63e0b390f2ddddba64cf18070000000000000000000000000000000000000000000000000000000000000006023709ea3deaff2b05808452f5e73c3498827269fef8bb6d883dd4d45d27048ee00000000000000000000000000000000000000000000000000000000000000007029304d84bb0da8d2d0e6ceee3ff042e1a611d1e64c55efb96461c150e1068dc74000000000000000000000000000000000000000000000000000000000000000803588f4d66a21d7ac2b359847887edafe6922ebab393228a1f5fb8024abedf5b53000000000000000000000000000000000000000000000000000000000000000903803e02d574edb91593cc6f747eb3df57db0dda54e2de830f2c1a30661cc8bae4000000000000000000000000000000000000000000000000000000000000000a02fe323c7eaf26c8b4519eb77d987ffe8a0fda5b617c241353dc53ea612e51ecbd00000000000000000000000000000000000000000000000000000000000000013da4009ba798bae5f75b69eb17ed9c3166bfb6a7bcdfd98e9a69ee32d21652940854657374204b6579134465736372697074696f6e20666f72206b65790200000000000000000000000000000000000000000000000000000000000000000201318ebf69651d9a3a131ec15df35f0ae27aa45aec5c776411f854a1b57cff8f3151f9a727a3d20ae879b1efbec60f3fad47c94ff2d6db9b4f1d56431d350385cb0000000000000000000000000000000000000000000000000000000000000006006b100ec9fc7cceb0a53ee6cb7e84617cf0790ea971f2703449fc2dcfd7d95ab27221e2c782e73e06f6c939259018d08cc1c8019de3bf1304c2819b7c5182a1a4";

void main() {
  group("FrostKeyWithDetails", () {
    setUpAll(loadFrosty);

    test("can be read and written and mutated", () {
      final name = "Test Key";
      final description = "Description for key";

      final keyInfos = generateNewKey(4);
      final secrets = keyInfos
          .map(
            (keyInfos) => keyInfos.private.share,
          )
          .toList();

      var details = FrostKeyWithDetails(
        keyInfo: keyInfos.first,
        name: name,
        description: description,
      );
      final groupKey = details.keyInfo.groupKey;

      void addAck(int i, bool accepted) {
        details = details.addOrReplaceAck(
          SignedDkgAck(
            signer: ids[i],
            signed: Signed.sign(
              obj: DkgAck(groupKey: groupKey, accepted: accepted),
              key: getPrivkey(i),
            ),
          ),
        );
      }

      addAck(1, true);
      addAck(5, false);

      void expectDetails(
        Map<Identifier, DateTime> secretShareTimes,
        Set<Identifier> claimedToHave,
        int nOtherSecrets,
      ) {
        // Convert to hex and then back again
        final hex = details.toHex();
        details = FrostKeyWithDetails.fromHex(hex);
        expect(details.toHex(), hex);

        expect(details.keyInfo.toHex(), keyInfos.first.toHex());
        expect(details.name, "Test Key");
        expect(details.description, "Description for key");

        expect(details.secretShareTimes, secretShareTimes);
        expect(details.claimedToHave, claimedToHave);
        expect(
          details.keyConstruction,
          nOtherSecrets < 3
              ? isA<KeyConstructionProgress>()
                  .having(
                    (progress) => progress.secrets.keys,
                    "secrets.keys",
                    ids.skip(1).take(nOtherSecrets),
                  )
                  .having(
                    (progress) =>
                        progress.secrets.values.map((key) => key.data),
                    "secrets.values",
                    secrets.skip(1).take(nOtherSecrets).map((key) => key.data),
                  )
              : isA<KeyConstructionComplete>(),
        );

        expect(
          List.generate(
            10,
            (i) => details.keyConstruction.haveForParticipant(ids[i]),
          ),
          nOtherSecrets < 3
              ? [
                  false,
                  ...List.filled(nOtherSecrets, true),
                  ...List.filled(9 - nOtherSecrets, false),
                ]
              : List.filled(10, true),
        );

        void expectAck(int i, bool accepted) {
          final ack = details.acks.firstWhere(
            (ack) => ack.signer == ids[i],
          );
          expect(ack.signed.obj.accepted, accepted);
          expect(ack.signed.obj.groupKey, groupKey);
          expect(ack.signed.verify(getPrivkey(i).pubkey), true);
        }

        expectAck(1, true);
        expectAck(5, false);
      }

      expectDetails({}, {}, 0);

      // Add secret share time, claimed to have and add one to keyConstruction

      final now = DateTime.fromMillisecondsSinceEpoch(123456789);
      details = details.addOrReplaceSecretShareTimes(
        ids.skip(1).take(3).toSet(),
        now,
      );
      details = details.addClaimedToHave(ids.last);

      void expectWithTimesAndClaimed(int nOtherSecrets) => expectDetails(
            {
              for (final id in ids.skip(1).take(3)) id: now,
            },
            {ids.last},
            nOtherSecrets,
          );

      // Add 1 secret. Adding secret multiple times is a nop
      for (int i = 0; i < 3; i++) {
        details = details.addSecretShare(ids[1], secrets[1])!;
      }

      expectWithTimesAndClaimed(1);

      // Complete construction
      for (int i = 2; i < 4; i++) {
        details = details.addSecretShare(ids[i], secrets[i])!;
        expectWithTimesAndClaimed(i);
      }

      // Adding others is no-op
      for (int i = 4; i < 10; i++) {
        details = details.addSecretShare(ids[i], secrets[i])!;
        expectWithTimesAndClaimed(3);
      }
    });

    test(".addSecretShare fails on incorrect secret", () {
      final infos = generateNewKey(2);
      final details = FrostKeyWithDetails(
        keyInfo: infos.first,
        name: "Some key",
        description: "",
      );
      expect(
        details.addSecretShare(ids[1], infos.first.private.share),
        isNull,
      );
    });

    test("can update existing acks and secret share times", () {
      var details = FrostKeyWithDetails(
        keyInfo: generateNewKey(3).first,
        name: "Some key",
        description: "",
      );

      for (final accepted in [true, false]) {
        details = details.addOrReplaceAck(getDkgAck(1, accepted));
        expect(details.acks, hasLength(1));
        expect(details.acks.first.signer, ids[1]);
        expect(details.acks.first.signed.obj.accepted, accepted);
      }

      for (final time in [
        DateTime.fromMillisecondsSinceEpoch(2000),
        DateTime.fromMillisecondsSinceEpoch(3000),
      ]) {
        details = details.addOrReplaceSecretShareTimes(
          {ids[1]},
          time,
        );
        expect(details.secretShareTimes[ids[1]], time);
      }
    });

    test("can read data from before v3.0.0", () {
      final details = FrostKeyWithDetails.fromHex(oldVersionHex);
      expect(details.acks, hasLength(2));
      expect(details.name, "Test Key");
      expect(details.secretShareTimes, isEmpty);
      expect(details.claimedToHave, isEmpty);
      expect(
        details.keyConstruction,
        isA<KeyConstructionProgress>().having(
          (construction) => construction.secrets,
          ".secrets",
          isEmpty,
        ),
      );
    });
  });
}
