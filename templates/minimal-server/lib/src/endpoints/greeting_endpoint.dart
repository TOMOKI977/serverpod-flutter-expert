import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

/// A minimal example endpoint demonstrating CRUD with Serverpod 3.4.x.
///
/// After adding or changing endpoints, always run:
///   dart run serverpod_cli generate
class GreetingEndpoint extends Endpoint {
  /// Returns all greetings, newest first.
  Future<List<Greeting>> listGreetings(Session session) async {
    return await Greeting.db.find(
      session,
      orderBy: (t) => t.createdAt,
      orderDescending: true,
      limit: 50,
    );
  }

  /// Creates a new greeting and returns the saved record.
  Future<Greeting> createGreeting(
    Session session,
    String message,
    String author,
  ) async {
    if (message.trim().isEmpty) throw ArgumentError('Message cannot be empty');
    if (author.trim().isEmpty) throw ArgumentError('Author cannot be empty');

    return await Greeting.db.insertRow(
      session,
      Greeting(
        message: message.trim(),
        author: author.trim(),
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  /// Deletes a greeting by ID. Returns true if deleted, false if not found.
  Future<bool> deleteGreeting(Session session, int id) async {
    final greeting = await Greeting.db.findById(session, id);
    if (greeting == null) return false;

    await Greeting.db.deleteRow(session, greeting);
    return true;
  }
}
