import 'package:dsh_client/dsh_client.dart';

enum SessionListConsumer { drawer, alerts, pets, uiConfig }

/// Shares an in-flight `session/list` read across distinct concurrent
/// consumers (drawer initial build, alert seeding, pet run tracking, UI
/// config) on the same [DshClient] and mux generation, without ever folding a
/// consumer's own subsequent refresh into an older request that started
/// before a newer state edge.
final _inFlightSessionLists = Expando<_SharedSessionList>('in-flight session/list');

class _SharedSessionList {
  _SharedSessionList(this.generation, this.future, this.joined);
  final MuxGeneration? generation;
  final Future<List<SessionSummary>> future;
  final Set<SessionListConsumer> joined;
}

Future<List<SessionSummary>> readSharedSessionList(
  DshClient client, {
  required SessionListConsumer consumer,
  bool fresh = false,
}) {
  final generation = client.mux.generation;
  final existing = _inFlightSessionLists[client];
  if (!fresh &&
      existing != null &&
      identical(existing.generation, generation) &&
      !existing.joined.contains(consumer)) {
    existing.joined.add(consumer);
    return existing.future;
  }
  late final _SharedSessionList entry;
  final future = client.listSessions().whenComplete(() {
    if (identical(_inFlightSessionLists[client], entry)) {
      _inFlightSessionLists[client] = null;
    }
  });
  entry = _SharedSessionList(generation, future, {consumer});
  _inFlightSessionLists[client] = entry;
  return future;
}
