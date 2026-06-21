import 'dart:typed_data';
import 'package:noosphere_roast_client/noosphere_roast_client.dart';

Uint8List bytes(List<int> li) => Uint8List.fromList(li);
SessionID sid(List<int> li) => SessionID.fromBytes(bytes(li));
SignaturesRequestId sigReqId(List<int> li) =>
    SignaturesRequestId.fromBytes(bytes(li));
