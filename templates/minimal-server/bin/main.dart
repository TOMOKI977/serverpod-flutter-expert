import 'package:serverpod/serverpod.dart';
import 'package:minimal_server/src/generated/endpoints.dart';
import 'package:minimal_server/src/generated/protocol.dart';

void main(List<String> args) async {
  final pod = Serverpod(
    args,
    Protocol(),
    Endpoints(),
  );

  await pod.start();
}
