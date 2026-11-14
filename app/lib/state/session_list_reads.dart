import 'package:dsh_client/dsh_client.dart';

/// Shares an in-flight session/list read on the same [DshClient] and mux
/// generation so concurrent startup consumers (drawer list, alert seeding,
/// pet run tracking) do not send identical full-list RPCs back-to-back.
final _inFlightSessionLists = Expando<_SharedSessionList>('in-flight session/list');

class _SharedSessionList {
  _SharedSessionList(this.generation, this.future);
  final MuxGeneration? generation;
  final Future<List<SessionSummary>> future;
}

Future<List<SessionSummary>> readSharedSessionList(DshClient client) {
  final generation = client.mux.generation;
  final existing = _inFlightSessionLists[client];
  if (existing != null && identical(existing.generation, generation)) {
    return existing.future;
  }
  late final _SharedSessionList entry;
  final future = client.listSessions().whenComplete(() {
    if (identical(_inFlightSessionLists[client], entry)) {
      _inFlightSessionLists[client] = null;
    }
  });
  entry = _SharedSessionList(generation, future);
  _inFlightSessionLists[client] = entry;
  return future;
}
