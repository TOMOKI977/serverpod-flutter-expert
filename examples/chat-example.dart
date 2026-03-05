// ---
// title: Real-Time Chat Example — Serverpod 3.4.x
// description: WebSocket-based chat with room management, message history,
//              online presence, and Flutter UI integration.
// serverpod_version: ">=3.4.0"
// ---

// ═══════════════════════════════════════════════════════════════════════════════
// PART 1: MODELS
// ═══════════════════════════════════════════════════════════════════════════════
//
// lib/src/models/chat_room.spy.yaml
// ─────────────────────────────────
// class: ChatRoom
// table: chat_rooms
// fields:
//   name: String
//   description: String?
//   createdBy: int
//   isPrivate: bool, default=false
//   createdAt: DateTime
// indexes:
//   chat_rooms_name_idx:
//     fields: name
//     unique: true
//
// lib/src/models/chat_message.spy.yaml
// ─────────────────────────────────────
// class: ChatMessage
// table: chat_messages
// fields:
//   roomId: int
//   senderId: int
//   senderName: String
//   body: String
//   editedAt: DateTime?
//   sentAt: DateTime
// indexes:
//   chat_messages_room_sent_idx:
//     fields: roomId, sentAt
//
// lib/src/models/room_member.spy.yaml
// ─────────────────────────────────────
// class: RoomMember
// table: room_members
// fields:
//   roomId: int
//   userId: int
//   joinedAt: DateTime
// indexes:
//   room_members_unique_idx:
//     fields: roomId, userId
//     unique: true
//   room_members_user_idx:
//     fields: userId
//
// lib/src/models/presence_event.spy.yaml
// ───────────────────────────────────────
// class: PresenceEvent
// fields:
//   userId: int
//   username: String
//   online: bool
//
// Run: dart run serverpod_cli generate

// ═══════════════════════════════════════════════════════════════════════════════
// PART 2: SERVER ENDPOINTS
// File: lib/src/endpoints/chat_endpoint.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

class ChatEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  // ── Room Management ─────────────────────────────────────────────────────────

  /// Create a new chat room
  Future<ChatRoom> createRoom(
    Session session,
    String name, {
    String? description,
    bool isPrivate = false,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Room name cannot be empty');
    if (name.length > 50) throw ArgumentError('Room name exceeds 50 characters');

    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final existing = await ChatRoom.db.findFirstRow(
      session,
      where: (t) => t.name.equals(name.trim()),
    );
    if (existing != null) throw Exception('Room name already taken');

    final room = await ChatRoom.db.insertRow(
      session,
      ChatRoom(
        name: name.trim(),
        description: description?.trim(),
        createdBy: userId,
        isPrivate: isPrivate,
        createdAt: DateTime.now().toUtc(),
      ),
    );

    // Automatically join the room creator
    await _joinRoom(session, userId, room.id!);
    return room;
  }

  /// List all public rooms (or rooms the user is a member of)
  Future<List<ChatRoom>> listRooms(Session session) async {
    return await ChatRoom.db.find(
      session,
      where: (t) => t.isPrivate.equals(false),
      orderBy: (t) => t.name,
    );
  }

  /// Join a room
  Future<void> joinRoom(Session session, int roomId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final room = await ChatRoom.db.findById(session, roomId);
    if (room == null) throw NotFoundException('Room $roomId not found');

    await _joinRoom(session, userId, roomId);
  }

  /// Leave a room
  Future<void> leaveRoom(Session session, int roomId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    await RoomMember.db.deleteWhere(
      session,
      where: (t) => t.roomId.equals(roomId) & t.userId.equals(userId),
    );

    // Broadcast offline presence
    final userInfo = await session.auth.authenticatedUserInfo;
    session.messages.postMessage(
      'presence_$roomId',
      PresenceEvent(
        userId: userId,
        username: userInfo?.userName ?? 'Unknown',
        online: false,
      ),
      global: true,
    );
  }

  // ── Messaging ───────────────────────────────────────────────────────────────

  /// Send a message to a room
  Future<ChatMessage> sendMessage(
    Session session,
    int roomId,
    String body,
  ) async {
    if (body.trim().isEmpty) throw ArgumentError('Message cannot be empty');
    if (body.length > 2000) throw ArgumentError('Message exceeds 2000 characters');

    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // Verify membership
    final member = await RoomMember.db.findFirstRow(
      session,
      where: (t) => t.roomId.equals(roomId) & t.userId.equals(userId),
    );
    if (member == null) {
      throw ForbiddenException('You must join the room before sending messages');
    }

    final userInfo = await session.auth.authenticatedUserInfo;
    final msg = await ChatMessage.db.insertRow(
      session,
      ChatMessage(
        roomId: roomId,
        senderId: userId,
        senderName: userInfo?.userName ?? 'Anonymous',
        body: body.trim(),
        sentAt: DateTime.now().toUtc(),
      ),
    );

    // Broadcast to all subscribers of this room
    session.messages.postMessage('chat_$roomId', msg, global: true);
    return msg;
  }

  /// Load message history for a room (paginated, newest first)
  Future<List<ChatMessage>> getHistory(
    Session session,
    int roomId, {
    int limit = 50,
    DateTime? before,
  }) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await ChatMessage.db.find(
      session,
      where: (t) {
        Expression filter = t.roomId.equals(roomId);
        if (before != null) filter = filter & t.sentAt.lessThan(before);
        return filter;
      },
      orderBy: (t) => t.sentAt,
      orderDescending: true,
      limit: limit,
    );
  }

  // ── Streaming ───────────────────────────────────────────────────────────────

  /// Subscribe to live messages in a room
  /// Yields history first, then live messages
  Stream<ChatMessage> subscribeToRoom(
    Session session,
    int roomId, {
    int historyLimit = 30,
  }) async* {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    session.log('User $userId subscribed to room $roomId');

    // Yield recent history (oldest first)
    final history = await ChatMessage.db.find(
      session,
      where: (t) => t.roomId.equals(roomId),
      orderBy: (t) => t.sentAt,
      orderDescending: true,
      limit: historyLimit,
    );
    for (final msg in history.reversed) {
      yield msg;
    }

    // Subscribe to live messages
    final stream = session.messages.createStream<ChatMessage>('chat_$roomId');
    try {
      await for (final msg in stream) {
        yield msg;
      }
    } finally {
      session.log('User $userId unsubscribed from room $roomId');
    }
  }

  /// Subscribe to presence events (who joined/left)
  Stream<PresenceEvent> subscribeToPresence(
    Session session,
    int roomId,
  ) async* {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // Announce this user as online
    final userInfo = await session.auth.authenticatedUserInfo;
    session.messages.postMessage(
      'presence_$roomId',
      PresenceEvent(
        userId: userId,
        username: userInfo?.userName ?? 'Anonymous',
        online: true,
      ),
      global: true,
    );

    final stream = session.messages.createStream<PresenceEvent>('presence_$roomId');
    await for (final event in stream) {
      yield event;
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  Future<void> _joinRoom(Session session, int userId, int roomId) async {
    final existing = await RoomMember.db.findFirstRow(
      session,
      where: (t) => t.roomId.equals(roomId) & t.userId.equals(userId),
    );
    if (existing != null) return; // Already a member

    await RoomMember.db.insertRow(
      session,
      RoomMember(
        roomId: roomId,
        userId: userId,
        joinedAt: DateTime.now().toUtc(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 3: FLUTTER CLIENT
// File: lib/src/services/chat_service.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:my_project_client/my_project_client.dart';

class ChatService extends ChangeNotifier {
  final Client _client;

  ChatService(this._client);

  // State
  List<ChatRoom> _rooms = [];
  final Map<int, List<ChatMessage>> _roomMessages = {};
  final Map<int, bool> _onlineUsers = {};
  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<PresenceEvent>? _presenceSub;
  int? _currentRoomId;
  bool _loading = false;
  String? _error;

  // Getters
  List<ChatRoom> get rooms => List.unmodifiable(_rooms);
  List<ChatMessage> messagesFor(int roomId) =>
      List.unmodifiable(_roomMessages[roomId] ?? []);
  Map<int, bool> get onlineUsers => Map.unmodifiable(_onlineUsers);
  bool get loading => _loading;
  String? get error => _error;

  // ── Load rooms ─────────────────────────────────────────────────────────────

  Future<void> loadRooms() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _rooms = await _client.chat.listRooms();
    } on ServerpodClientException catch (e) {
      _error = 'Failed to load rooms: ${e.message}';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Join / leave room ──────────────────────────────────────────────────────

  Future<void> joinRoom(int roomId) async {
    if (_currentRoomId == roomId) return;

    // Leave current room first
    if (_currentRoomId != null) await leaveRoom();

    await _client.chat.joinRoom(roomId);
    _currentRoomId = roomId;
    _roomMessages[roomId] = [];

    // Subscribe to messages
    _messageSub = _client.chat
        .subscribeToRoom(roomId)
        .listen(
          (msg) {
            _roomMessages[roomId] = [...(_roomMessages[roomId] ?? []), msg];
            notifyListeners();
          },
          onError: (Object e) {
            _error = 'Lost connection to room';
            notifyListeners();
            // Reconnect after delay
            Future.delayed(
              const Duration(seconds: 3),
              () => joinRoom(roomId),
            );
          },
        );

    // Subscribe to presence
    _presenceSub = _client.chat
        .subscribeToPresence(roomId)
        .listen(
          (event) {
            _onlineUsers[event.userId] = event.online;
            notifyListeners();
          },
        );

    notifyListeners();
  }

  Future<void> leaveRoom() async {
    final roomId = _currentRoomId;
    if (roomId == null) return;

    _messageSub?.cancel();
    _presenceSub?.cancel();
    _messageSub = null;
    _presenceSub = null;

    await _client.chat.leaveRoom(roomId);
    _currentRoomId = null;
    _onlineUsers.clear();
    notifyListeners();
  }

  // ── Send message ───────────────────────────────────────────────────────────

  Future<void> sendMessage(int roomId, String body) async {
    try {
      await _client.chat.sendMessage(roomId, body);
    } on ServerpodClientException catch (e) {
      _error = 'Failed to send: ${e.message}';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _presenceSub?.cancel();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 4: FLUTTER CHAT SCREEN
// File: lib/src/screens/chat_screen.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ChatScreen extends StatefulWidget {
  final int roomId;
  final String roomName;

  const ChatScreen({
    required this.roomId,
    required this.roomName,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatService>().joinRoom(widget.roomId);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    context.read<ChatService>().leaveRoom();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty) return;
    _controller.clear();
    await context.read<ChatService>().sendMessage(widget.roomId, body);
    // Scroll to bottom after sending
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatService>();
    final messages = chat.messagesFor(widget.roomId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.roomName),
            Text(
              '${chat.onlineUsers.values.where((v) => v).length} online',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Error banner
          if (chat.error != null)
            Container(
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(8),
              child: Text(chat.error!, style: const TextStyle(color: Colors.red)),
            ),

          // Message list
          Expanded(
            child: chat.loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: messages.length,
                    itemBuilder: (ctx, i) {
                      final msg = messages[i];
                      final isMe = msg.senderId ==
                          SessionManager.instance.signedInUser?.id;
                      return _MessageBubble(msg: msg, isMe: isMe);
                    },
                  ),
          ),

          // Input bar
          Padding(
            padding: EdgeInsets.only(
              left: 8,
              right: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 8,
              top: 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final bool isMe;

  const _MessageBubble({required this.msg, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                msg.senderName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Text(
              msg.body,
              style: TextStyle(
                color: isMe
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '${msg.sentAt.hour}:${msg.sentAt.minute.toString().padLeft(2, '0')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: isMe
                    ? theme.colorScheme.onPrimary.withOpacity(0.7)
                    : theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
