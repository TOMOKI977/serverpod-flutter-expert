---
title: WebSockets & Streaming Reference
description: Real-time communication with Serverpod 3.4.x streaming endpoints — pub/sub, lifecycle management, error handling, and Flutter integration.
tags: [serverpod, websockets, streaming, real-time, flutter, pub-sub]
---

# WebSockets & Streaming in Serverpod 3.4.x

Serverpod uses a persistent WebSocket connection between the Flutter client and the server. Streaming endpoints are methods that return `Stream<T>` using `async*` generators. The server uses a pub/sub message channel system for broadcasting.

---

## 1. Architecture Overview

```
Flutter Client
    │  WebSocket (persistent connection)
    ▼
Serverpod Server
    │  session.messages.createStream('channel_name')
    ▼
Message Broker (Redis in production, in-memory in dev)
    ▲
    │  session.messages.postMessage('channel_name', payload, global: true)
    │
Other Server Instances (horizontal scaling)
```

- **`postMessage`** — publishes a message to a named channel.
- **`createStream`** — subscribes to a channel and returns a `Stream<T>`.
- Set `global: true` to broadcast across all server instances (requires Redis).

---

## 2. Basic Streaming Endpoint

```dart
// lib/src/endpoints/notification_endpoint.dart
import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

class NotificationEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  /// Publish a notification to a user
  Future<void> sendNotification(
    Session session,
    int targetUserId,
    String message,
  ) async {
    final notification = AppNotification(
      userId: targetUserId,
      message: message,
      createdAt: DateTime.now().toUtc(),
    );
    final saved = await AppNotification.db.insertRow(session, notification);

    session.messages.postMessage(
      'notifications_$targetUserId',
      saved,
      global: true,
    );
  }

  /// Subscribe to notifications for the current user
  Stream<AppNotification> subscribeToNotifications(Session session) async* {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    session.log('User $userId subscribed to notifications');

    final stream = session.messages.createStream<AppNotification>(
      'notifications_$userId',
    );
    await for (final notification in stream) {
      yield notification;
    }
  }
}
```

---

## 3. Real-Time Chat with Room Support

### Model

```yaml
# lib/src/models/chat_message.spy.yaml
class: ChatMessage
table: chat_messages
fields:
  roomId: String
  senderId: int
  senderName: String
  body: String
  sentAt: DateTime
indexes:
  chat_messages_room_idx:
    fields: roomId, sentAt
```

### Server Endpoint

```dart
// lib/src/endpoints/chat_endpoint.dart
import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

class ChatEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  /// Send a message to a room
  Future<ChatMessage> sendMessage(
    Session session,
    String roomId,
    String body,
  ) async {
    if (body.trim().isEmpty) throw ArgumentError('Message body cannot be empty');
    if (roomId.trim().isEmpty) throw ArgumentError('Room ID cannot be empty');

    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // Get the sender's display name
    final userInfo = await session.auth.authenticatedUserInfo;
    final senderName = userInfo?.userName ?? 'Anonymous';

    final msg = ChatMessage(
      roomId: roomId,
      senderId: userId,
      senderName: senderName,
      body: body.trim(),
      sentAt: DateTime.now().toUtc(),
    );
    final saved = await ChatMessage.db.insertRow(session, msg);

    // Broadcast to all room subscribers
    session.messages.postMessage('chat_$roomId', saved, global: true);

    return saved;
  }

  /// Get message history for a room (last N messages)
  Future<List<ChatMessage>> getHistory(
    Session session,
    String roomId, {
    int limit = 50,
    DateTime? before,
  }) async {
    return await ChatMessage.db.find(
      session,
      where: (t) {
        Expression filter = t.roomId.equals(roomId);
        if (before != null) {
          filter = filter & t.sentAt.lessThan(before);
        }
        return filter;
      },
      orderBy: (t) => t.sentAt,
      orderDescending: true,
      limit: limit,
    );
  }

  /// Subscribe to live messages in a room, with history prefetch
  Stream<ChatMessage> subscribeToRoom(
    Session session,
    String roomId, {
    int historyLimit = 30,
  }) async* {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    session.log('User $userId joined room $roomId');

    // Yield recent history first (reversed so oldest comes first)
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

    // Then stream live messages
    final stream = session.messages.createStream<ChatMessage>('chat_$roomId');
    try {
      await for (final msg in stream) {
        yield msg;
      }
    } finally {
      session.log('User $userId left room $roomId');
    }
  }
}
```

---

## 4. Online Presence Indicators

```dart
// lib/src/endpoints/presence_endpoint.dart
class PresenceEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  Future<void> setOnline(Session session, String roomId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    session.messages.postMessage(
      'presence_$roomId',
      PresenceEvent(userId: userId, online: true),
      global: true,
    );
  }

  Future<void> setOffline(Session session, String roomId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    session.messages.postMessage(
      'presence_$roomId',
      PresenceEvent(userId: userId, online: false),
      global: true,
    );
  }

  Stream<PresenceEvent> subscribeToPresence(
    Session session,
    String roomId,
  ) async* {
    final stream = session.messages.createStream<PresenceEvent>('presence_$roomId');
    await for (final event in stream) {
      yield event;
    }
  }
}
```

---

## 5. Flutter Client Integration

### Basic Subscription

```dart
// chat_service.dart
import 'package:flutter/foundation.dart';
import 'package:my_project_client/my_project_client.dart';

class ChatService extends ChangeNotifier {
  final Client _client;
  final List<ChatMessage> _messages = [];
  StreamSubscription<ChatMessage>? _subscription;
  bool _isConnected = false;

  ChatService(this._client);

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isConnected => _isConnected;

  void joinRoom(String roomId) {
    _subscription?.cancel();

    _subscription = _client.chat
        .subscribeToRoom(roomId)
        .listen(
          (msg) {
            _messages.add(msg);
            notifyListeners();
          },
          onError: (Object error) {
            debugPrint('Chat stream error: $error');
            _isConnected = false;
            notifyListeners();
            // Reconnect with exponential backoff
            _scheduleReconnect(roomId);
          },
          onDone: () {
            debugPrint('Chat stream closed');
            _isConnected = false;
            notifyListeners();
          },
        );

    _isConnected = true;
    notifyListeners();
  }

  Future<void> sendMessage(String roomId, String body) async {
    try {
      await _client.chat.sendMessage(roomId, body);
    } on ServerpodClientException catch (e) {
      debugPrint('Failed to send message: ${e.message}');
      rethrow;
    }
  }

  int _reconnectAttempts = 0;

  void _scheduleReconnect(String roomId) {
    final delay = Duration(seconds: (2 << _reconnectAttempts).clamp(1, 30));
    _reconnectAttempts++;
    Future.delayed(delay, () {
      if (!_isConnected) {
        joinRoom(roomId);
        _reconnectAttempts = 0;
      }
    });
  }

  void leaveRoom() {
    _subscription?.cancel();
    _subscription = null;
    _isConnected = false;
    _messages.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
```

### Flutter Widget

```dart
class ChatScreen extends StatelessWidget {
  final String roomId;
  const ChatScreen({required this.roomId, super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatService(context.read<Client>())..joinRoom(roomId),
      child: _ChatBody(roomId: roomId),
    );
  }
}

class _ChatBody extends StatefulWidget {
  final String roomId;
  const _ChatBody({required this.roomId});

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatService>();
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            itemCount: chat.messages.length,
            itemBuilder: (ctx, i) {
              final msg = chat.messages[chat.messages.length - 1 - i];
              return ListTile(
                title: Text(msg.senderName),
                subtitle: Text(msg.body),
                trailing: Text(
                  '${msg.sentAt.hour}:${msg.sentAt.minute.toString().padLeft(2, '0')}',
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(hintText: 'Message...'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () async {
                  final body = _controller.text.trim();
                  if (body.isEmpty) return;
                  _controller.clear();
                  await context
                      .read<ChatService>()
                      .sendMessage(widget.roomId, body);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
```

---

## 6. Connection Lifecycle Management

| Event | Server | Flutter Client |
|-------|--------|---------------|
| Client connects | Session created | Client initialized |
| Client subscribes | `createStream` called | Stream subscription starts |
| Server broadcasts | `postMessage` called | `listen` callback fires |
| Client disconnects | `createStream` stream closes | `onDone` callback fires |
| Network error | Session closed | `onError` callback fires |
| Server restart | All sessions closed | All streams close → reconnect |

---

## 7. Scaling WebSockets in Production

- Enable Redis in `config/production.yaml` (`redis.enabled: true`).
- Use Redis for `global: true` message broadcasting across multiple server instances.
- Place a load balancer that supports sticky sessions (or use the same Redis pub/sub so any instance can receive and forward messages).
- Monitor active connections via Serverpod Insights dashboard.

```yaml
# config/production.yaml
redis:
  enabled: true
  host: redis
  port: 6379
  requireSsl: true
```

---

## 8. Error Handling and Reconnection Strategy

```dart
// Exponential backoff reconnect
int _attempts = 0;

void connectWithRetry(String channel) {
  client.myEndpoint
      .subscribeToChannel(channel)
      .listen(
        _handleMessage,
        onError: (Object e) {
          final delay = Duration(
            milliseconds: (500 * (1 << _attempts)).clamp(500, 30000),
          );
          _attempts++;
          Future.delayed(delay, () => connectWithRetry(channel));
        },
        onDone: () {
          _attempts = 0;
          connectWithRetry(channel); // Reconnect on clean close
        },
      );
}
```
