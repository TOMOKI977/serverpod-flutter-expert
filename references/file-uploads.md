---
title: File Uploads Reference
description: Guide to handling file uploads in Serverpod 3.4.x — validation, storage options, progress tracking, async processing, and security.
tags: [serverpod, file-uploads, storage, s3, cloud, security]
---

# File Uploads in Serverpod 3.4.x

Serverpod supports file uploads via the `session.storage` API. Files are transferred as `ByteData` through the standard RPC channel. For large files, consider using a direct-to-storage approach (presigned URLs) to avoid routing through your app server.

---

## 1. Storage Configuration

```yaml
# config/development.yaml
storage:
  public:
    type: local                      # 'local', 's3', or 'gcs'
    storageDirectory: storage/public

  private:
    type: local
    storageDirectory: storage/private
```

```yaml
# config/production.yaml
storage:
  public:
    type: s3
    region: us-east-1
    bucketName: myapp-public-files
    publicUrl: https://cdn.myapp.com

  private:
    type: s3
    region: us-east-1
    bucketName: myapp-private-files
```

```yaml
# config/passwords.yaml
aws:
  accessKeyId: YOUR_ACCESS_KEY_ID
  secretAccessKey: YOUR_SECRET_ACCESS_KEY
```

---

## 2. Server Endpoint

```dart
// lib/src/endpoints/file_endpoint.dart
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:serverpod/serverpod.dart';
import '../generated/protocol.dart';

class FileEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  // ── Constraints ──────────────────────────────────────────────────────────────
  static const int _maxFileSizeBytes = 10 * 1024 * 1024; // 10 MB

  static const Map<String, String> _allowedMimeByExtension = {
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.pdf': 'application/pdf',
    '.mp4': 'video/mp4',
  };

  /// Upload a file and return its storage path
  Future<UploadedFile> uploadFile(
    Session session,
    ByteData fileData,
    String originalFilename,
  ) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // ── Validate extension ────────────────────────────────────────────────────
    final ext = p.extension(originalFilename).toLowerCase();
    if (!_allowedMimeByExtension.containsKey(ext)) {
      throw ArgumentError(
        'Unsupported file type: $ext. '
        'Allowed: ${_allowedMimeByExtension.keys.join(', ')}',
      );
    }

    // ── Validate size ─────────────────────────────────────────────────────────
    if (fileData.lengthInBytes > _maxFileSizeBytes) {
      throw ArgumentError(
        'File size ${fileData.lengthInBytes} exceeds the '
        '${_maxFileSizeBytes ~/ 1024 ~/ 1024} MB limit',
      );
    }

    // ── Validate magic bytes (basic file type verification) ───────────────────
    _verifyMagicBytes(fileData, ext);

    // ── Build a safe storage path ─────────────────────────────────────────────
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = '${timestamp}_${_sanitizeFilename(p.basename(originalFilename))}';
    final storagePath = 'users/$userId/$safeName';

    await session.storage.storeFile(
      storageId: 'public',
      path: storagePath,
      byteData: fileData,
      verified: true,
    );

    session.log(
      'File uploaded: $storagePath (${fileData.lengthInBytes} bytes)',
    );

    // Persist upload record
    final record = UploadedFile(
      userId: userId,
      storagePath: storagePath,
      originalFilename: originalFilename,
      sizeBytes: fileData.lengthInBytes,
      mimeType: _allowedMimeByExtension[ext]!,
      uploadedAt: DateTime.now().toUtc(),
    );
    return await UploadedFile.db.insertRow(session, record);
  }

  /// Get the public URL for a file
  Future<String?> getFileUrl(Session session, int uploadedFileId) async {
    final record = await UploadedFile.db.findById(session, uploadedFileId);
    if (record == null) return null;

    final uri = await session.storage.retrieveFileUrl(
      storageId: 'public',
      path: record.storagePath,
    );
    return uri?.toString();
  }

  /// List files uploaded by the current user
  Future<List<UploadedFile>> listMyFiles(Session session) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await UploadedFile.db.find(
      session,
      where: (t) => t.userId.equals(userId),
      orderBy: (t) => t.uploadedAt,
      orderDescending: true,
    );
  }

  /// Delete a file (only the owner can delete)
  Future<void> deleteFile(Session session, int uploadedFileId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final record = await UploadedFile.db.findById(session, uploadedFileId);
    if (record == null) throw NotFoundException('File not found');
    if (record.userId != userId) throw ForbiddenException('Not your file');

    await session.storage.deleteFile(
      storageId: 'public',
      path: record.storagePath,
    );
    await UploadedFile.db.deleteRow(session, record);

    session.log('File deleted: ${record.storagePath}');
  }

  // ── Private helpers ───────────────────────────────────────────────────────────

  String _sanitizeFilename(String filename) {
    // Remove path separators and dangerous characters
    return filename
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
  }

  void _verifyMagicBytes(ByteData data, String ext) {
    final bytes = data.buffer.asUint8List();
    if (bytes.length < 4) throw ArgumentError('File is too small to be valid');

    switch (ext) {
      case '.jpg':
      case '.jpeg':
        // JPEG: FF D8 FF
        if (bytes[0] != 0xFF || bytes[1] != 0xD8 || bytes[2] != 0xFF) {
          throw ArgumentError('File does not appear to be a valid JPEG');
        }
      case '.png':
        // PNG: 89 50 4E 47
        if (bytes[0] != 0x89 || bytes[1] != 0x50 ||
            bytes[2] != 0x4E || bytes[3] != 0x47) {
          throw ArgumentError('File does not appear to be a valid PNG');
        }
      case '.pdf':
        // PDF: 25 50 44 46 (%PDF)
        if (bytes[0] != 0x25 || bytes[1] != 0x50 ||
            bytes[2] != 0x44 || bytes[3] != 0x46) {
          throw ArgumentError('File does not appear to be a valid PDF');
        }
    }
  }
}
```

---

## 3. Model for Upload Records

```yaml
# lib/src/models/uploaded_file.spy.yaml
class: UploadedFile
table: uploaded_files
fields:
  userId: int
  storagePath: String
  originalFilename: String
  sizeBytes: int
  mimeType: String
  processingStatus: String?    # 'pending', 'processing', 'done', 'failed'
  processedPath: String?       # Path to processed version (e.g., thumbnail)
  uploadedAt: DateTime
indexes:
  uploaded_files_user_idx:
    fields: userId
  uploaded_files_status_idx:
    fields: processingStatus
```

---

## 4. Flutter Client — Upload with Progress

```dart
// file_upload_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:my_project_client/my_project_client.dart';

class FileUploadService {
  final Client _client;
  FileUploadService(this._client);

  /// Upload a file picked by the user, with progress callback
  Future<UploadedFile> uploadFile(
    File file, {
    ValueChanged<double>? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    final totalBytes = bytes.length;

    // Report initial progress
    onProgress?.call(0.0);

    // For large files, chunk and report progress
    // (Serverpod 3.4.x transfers as a single ByteData for simplicity)
    final byteData = ByteData.view(bytes.buffer);

    // Simulate progress during network transfer
    onProgress?.call(0.1);

    final result = await _client.file.uploadFile(
      byteData,
      file.path.split(Platform.pathSeparator).last,
    );

    onProgress?.call(1.0);
    return result;
  }

  Future<String?> getFileUrl(int uploadedFileId) async {
    return await _client.file.getFileUrl(uploadedFileId);
  }

  Future<List<UploadedFile>> listMyFiles() async {
    return await _client.file.listMyFiles();
  }

  Future<void> deleteFile(int uploadedFileId) async {
    await _client.file.deleteFile(uploadedFileId);
  }
}
```

### Flutter Widget Example

```dart
class UploadWidget extends StatefulWidget {
  const UploadWidget({super.key});

  @override
  State<UploadWidget> createState() => _UploadWidgetState();
}

class _UploadWidgetState extends State<UploadWidget> {
  double _progress = 0;
  bool _uploading = false;
  String? _uploadedUrl;

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;

    setState(() {
      _uploading = true;
      _progress = 0;
    });

    try {
      final file = File(result.files.single.path!);
      final service = context.read<FileUploadService>();
      final uploaded = await service.uploadFile(
        file,
        onProgress: (p) => setState(() => _progress = p),
      );
      final url = await service.getFileUrl(uploaded.id!);
      setState(() => _uploadedUrl = url);
    } on ServerpodClientException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: ${e.message}')),
      );
    } finally {
      setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_uploading) LinearProgressIndicator(value: _progress),
        if (_uploadedUrl != null) Image.network(_uploadedUrl!),
        ElevatedButton(
          onPressed: _uploading ? null : _pickAndUpload,
          child: const Text('Upload Image'),
        ),
      ],
    );
  }
}
```

---

## 5. Async Processing of Uploaded Files

For heavy work (image resizing, video transcoding, PDF parsing), process asynchronously:

```dart
// In the upload endpoint, after saving the file record:
Future<UploadedFile> uploadFile(...) async {
  // ... validation and storage ...

  final record = await UploadedFile.db.insertRow(session, UploadedFile(
    // ...
    processingStatus: 'pending',
  ));

  // Queue background job (fire and forget)
  unawaited(_processFile(session, record.id!));

  return record;
}

Future<void> _processFile(Session session, int fileId) async {
  try {
    await UploadedFile.db.updateRow(session, (await UploadedFile.db.findById(session, fileId))!
        .copyWith(processingStatus: 'processing'));

    // ... do expensive work (resize, etc.) ...

    await UploadedFile.db.updateRow(session, (await UploadedFile.db.findById(session, fileId))!
        .copyWith(processingStatus: 'done', processedPath: 'thumbnails/$fileId.jpg'));
  } catch (e, st) {
    session.log('Processing failed for file $fileId: $e', level: LogLevel.error, exception: e, stackTrace: st);
    await UploadedFile.db.updateRow(session, (await UploadedFile.db.findById(session, fileId))!
        .copyWith(processingStatus: 'failed'));
  }
}
```

---

## 6. Security Considerations

- **Validate by magic bytes**, not just extension — clients can rename files.
- **Set strict file size limits** server-side; never trust client-reported size.
- **Isolate user files** by path: `uploads/<userId>/filename` prevents cross-user access.
- **Never serve uploaded files** directly from your server root — use a CDN or signed URLs.
- For private files, use signed expiring URLs via `session.storage.retrieveFileUrl`.
- Log all upload and delete events for audit trails.
- Rotate AWS credentials periodically; use IAM roles with least-privilege.
- Consider virus scanning (ClamAV or cloud AV) for untrusted uploads.
