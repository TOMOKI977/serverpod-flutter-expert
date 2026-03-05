// ---
// title: Full CRUD Example — Serverpod 3.4.x
// description: Complete CRUD implementation with model, server endpoint,
//              Flutter client, validation, and unit tests.
// serverpod_version: ">=3.4.0"
// ---

// ═══════════════════════════════════════════════════════════════════════════════
// PART 1: MODEL DEFINITION
// File: lib/src/models/task.spy.yaml
// ═══════════════════════════════════════════════════════════════════════════════
//
// class: Task
// table: tasks
// fields:
//   userId: int
//   title: String
//   description: String?
//   isCompleted: bool, default=false
//   priority: TaskPriority
//   dueAt: DateTime?
//   tags: List<String>?
//   createdAt: DateTime
//   updatedAt: DateTime
// indexes:
//   tasks_user_idx:
//     fields: userId
//   tasks_user_completed_idx:
//     fields: userId, isCompleted
//   tasks_due_idx:
//     fields: dueAt
//
// ---
//
// enum: TaskPriority
// serialized: byName
// values:
//   - low
//   - medium
//   - high
//   - urgent
//
// After saving the YAML files, run:
//   dart run serverpod_cli generate

// ═══════════════════════════════════════════════════════════════════════════════
// PART 2: SERVER ENDPOINT
// File: lib/src/endpoints/task_endpoint.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

class TaskEndpoint extends Endpoint {
  /// All methods require authentication
  @override
  bool get requireLogin => true;

  // ── CREATE ──────────────────────────────────────────────────────────────────

  /// Create a new task for the authenticated user
  Future<Task> createTask(
    Session session,
    String title, {
    String? description,
    TaskPriority priority = TaskPriority.medium,
    DateTime? dueAt,
    List<String>? tags,
  }) async {
    _validateTitle(title);

    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final now = DateTime.now().toUtc();
    final task = Task(
      userId: userId,
      title: title.trim(),
      description: description?.trim(),
      isCompleted: false,
      priority: priority,
      dueAt: dueAt?.toUtc(),
      tags: tags,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await Task.db.insertRow(session, task);
    session.log('Task created: ${saved.id} by user $userId');
    return saved;
  }

  // ── READ ────────────────────────────────────────────────────────────────────

  /// Get a single task by ID (must belong to the authenticated user)
  Future<Task?> getTask(Session session, int taskId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final task = await Task.db.findById(session, taskId);
    if (task == null) return null;
    if (task.userId != userId) throw ForbiddenException('Not your task');
    return task;
  }

  /// List tasks for the authenticated user with optional filters
  Future<List<Task>> listTasks(
    Session session, {
    bool? isCompleted,
    TaskPriority? priority,
    int limit = 50,
    int offset = 0,
  }) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await Task.db.find(
      session,
      where: (t) {
        Expression filter = t.userId.equals(userId);
        if (isCompleted != null) {
          filter = filter & t.isCompleted.equals(isCompleted);
        }
        if (priority != null) {
          filter = filter & t.priority.equals(priority);
        }
        return filter;
      },
      orderBy: (t) => t.createdAt,
      orderDescending: true,
      limit: limit,
      offset: offset,
    );
  }

  /// Count tasks for the authenticated user
  Future<int> countTasks(Session session, {bool? isCompleted}) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await Task.db.count(
      session,
      where: (t) {
        Expression filter = t.userId.equals(userId);
        if (isCompleted != null) {
          filter = filter & t.isCompleted.equals(isCompleted);
        }
        return filter;
      },
    );
  }

  // ── UPDATE ──────────────────────────────────────────────────────────────────

  /// Update task fields (only provided fields are changed)
  Future<Task> updateTask(
    Session session,
    int taskId, {
    String? title,
    String? description,
    TaskPriority? priority,
    DateTime? dueAt,
    List<String>? tags,
  }) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final task = await Task.db.findById(session, taskId);
    if (task == null) throw NotFoundException('Task $taskId not found');
    if (task.userId != userId) throw ForbiddenException('Not your task');

    if (title != null) _validateTitle(title);

    final updated = await Task.db.updateRow(
      session,
      task.copyWith(
        title: title?.trim() ?? task.title,
        description: description?.trim() ?? task.description,
        priority: priority ?? task.priority,
        dueAt: dueAt?.toUtc() ?? task.dueAt,
        tags: tags ?? task.tags,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    session.log('Task updated: $taskId');
    return updated;
  }

  /// Toggle completion status
  Future<Task> toggleComplete(Session session, int taskId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final task = await Task.db.findById(session, taskId);
    if (task == null) throw NotFoundException('Task $taskId not found');
    if (task.userId != userId) throw ForbiddenException('Not your task');

    return await Task.db.updateRow(
      session,
      task.copyWith(
        isCompleted: !task.isCompleted,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  // ── DELETE ──────────────────────────────────────────────────────────────────

  /// Delete a single task
  Future<void> deleteTask(Session session, int taskId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final task = await Task.db.findById(session, taskId);
    if (task == null) throw NotFoundException('Task $taskId not found');
    if (task.userId != userId) throw ForbiddenException('Not your task');

    await Task.db.deleteRow(session, task);
    session.log('Task deleted: $taskId');
  }

  /// Delete all completed tasks for the authenticated user
  Future<int> deleteCompletedTasks(Session session) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await Task.db.deleteWhere(
      session,
      where: (t) => t.userId.equals(userId) & t.isCompleted.equals(true),
    );
  }

  // ── Validation ───────────────────────────────────────────────────────────────

  void _validateTitle(String title) {
    if (title.trim().isEmpty) throw ArgumentError('Title cannot be empty');
    if (title.length > 200) throw ArgumentError('Title exceeds 200 characters');
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 3: FLUTTER CLIENT SERVICE
// File: lib/src/services/task_service.dart
// ═══════════════════════════════════════════════════════════════════════════════

// ignore_for_file: avoid_print

import 'package:flutter/foundation.dart';
import 'package:my_project_client/my_project_client.dart';

class TaskService extends ChangeNotifier {
  final Client _client;

  TaskService(this._client);

  List<Task> _tasks = [];
  bool _loading = false;
  String? _error;

  List<Task> get tasks => List.unmodifiable(_tasks);
  bool get loading => _loading;
  String? get error => _error;

  // ── Load ──────────────────────────────────────────────────────────────────

  Future<void> loadTasks({bool? isCompleted}) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _tasks = await _client.task.listTasks(isCompleted: isCompleted);
    } on ServerpodClientException catch (e) {
      _error = e.message;
      debugPrint('Load tasks failed: ${e.message}');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Create ────────────────────────────────────────────────────────────────

  Future<Task?> createTask(
    String title, {
    String? description,
    TaskPriority priority = TaskPriority.medium,
    DateTime? dueAt,
  }) async {
    try {
      final task = await _client.task.createTask(
        title,
        description: description,
        priority: priority,
        dueAt: dueAt,
      );
      _tasks.insert(0, task);
      notifyListeners();
      return task;
    } on ServerpodClientException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  // ── Toggle ────────────────────────────────────────────────────────────────

  Future<void> toggleComplete(int taskId) async {
    try {
      final updated = await _client.task.toggleComplete(taskId);
      final index = _tasks.indexWhere((t) => t.id == taskId);
      if (index != -1) {
        _tasks[index] = updated;
        notifyListeners();
      }
    } on ServerpodClientException catch (e) {
      _error = e.message;
      notifyListeners();
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> deleteTask(int taskId) async {
    try {
      await _client.task.deleteTask(taskId);
      _tasks.removeWhere((t) => t.id == taskId);
      notifyListeners();
    } on ServerpodClientException catch (e) {
      _error = e.message;
      notifyListeners();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 4: FLUTTER WIDGET
// File: lib/src/screens/task_screen.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key});

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  final _titleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TaskService>().loadTasks();
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _addTask() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;

    final created = await context.read<TaskService>().createTask(title);
    if (created != null) {
      _titleController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<TaskService>();
    return Scaffold(
      appBar: AppBar(title: const Text('My Tasks')),
      body: Column(
        children: [
          // ── Error banner ───────────────────────────────────────────────────
          if (service.error != null)
            MaterialBanner(
              content: Text(service.error!),
              actions: [
                TextButton(
                  onPressed: service.loadTasks,
                  child: const Text('Retry'),
                ),
              ],
            ),
          // ── New task input ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'New task',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addTask(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _addTask, child: const Text('Add')),
              ],
            ),
          ),
          // ── Task list ──────────────────────────────────────────────────────
          Expanded(
            child: service.loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: service.tasks.length,
                    itemBuilder: (ctx, i) {
                      final task = service.tasks[i];
                      return ListTile(
                        leading: Checkbox(
                          value: task.isCompleted,
                          onChanged: (_) =>
                              service.toggleComplete(task.id!),
                        ),
                        title: Text(
                          task.title,
                          style: task.isCompleted
                              ? const TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null,
                        ),
                        subtitle: task.description != null
                            ? Text(task.description!)
                            : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => service.deleteTask(task.id!),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 5: UNIT TESTS
// File: test/task_endpoint_test.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:test/test.dart';
import 'package:serverpod_test/serverpod_test.dart';

void main() {
  withServerpod('TaskEndpoint', (sessionBuilder, endpoints) {
    // Authenticated session for user with id=42
    final authSession = sessionBuilder.build(
      authentication: AuthenticationOverride.authenticationInfo(42, {}),
    );
    // Unauthenticated session
    final anonSession = sessionBuilder.build();
    late TaskEndpoint ep;

    setUp(() {
      ep = TaskEndpoint();
    });

    group('createTask', () {
      test('creates a task with required fields', () async {
        final task = await ep.createTask(authSession, 'Buy groceries');
        expect(task.id, isNotNull);
        expect(task.title, equals('Buy groceries'));
        expect(task.userId, equals(42));
        expect(task.isCompleted, isFalse);
        expect(task.priority, equals(TaskPriority.medium));
      });

      test('trims whitespace from title', () async {
        final task = await ep.createTask(authSession, '  Trimmed  ');
        expect(task.title, equals('Trimmed'));
      });

      test('throws ArgumentError for empty title', () {
        expect(
          () => ep.createTask(authSession, ''),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('throws when unauthenticated', () {
        expect(
          () => ep.createTask(anonSession, 'Task'),
          throwsA(isA<ServerpodUnauthenticatedException>()),
        );
      });
    });

    group('toggleComplete', () {
      test('flips isCompleted', () async {
        final task = await ep.createTask(authSession, 'Toggle me');
        expect(task.isCompleted, isFalse);

        final toggled = await ep.toggleComplete(authSession, task.id!);
        expect(toggled.isCompleted, isTrue);

        final toggledBack = await ep.toggleComplete(authSession, task.id!);
        expect(toggledBack.isCompleted, isFalse);
      });
    });

    group('deleteTask', () {
      test('deletes owned task', () async {
        final task = await ep.createTask(authSession, 'Delete me');
        await ep.deleteTask(authSession, task.id!);

        final found = await ep.getTask(authSession, task.id!);
        expect(found, isNull);
      });

      test('throws NotFoundException for non-existent task', () {
        expect(
          () => ep.deleteTask(authSession, 999999),
          throwsA(isA<NotFoundException>()),
        );
      });
    });
  });
}
