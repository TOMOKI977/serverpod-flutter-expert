---
title: Authentication Reference
description: Complete guide to authentication in Serverpod 3.4.x — email, social login, session management, and best practices.
tags: [serverpod, authentication, jwt, email, google, apple, session]
---

# Authentication in Serverpod 3.4.x

Serverpod uses the `serverpod_auth_server` package for server-side auth and a set of Flutter packages for each provider. All auth state is managed through `SessionManager` on the client.

---

## 1. Dependencies

```yaml
# Server pubspec.yaml
dependencies:
  serverpod: ^3.4.0
  serverpod_auth_server: ^3.4.0

# Flutter pubspec.yaml
dependencies:
  serverpod_flutter: ^3.4.0
  serverpod_auth_client: ^3.4.0
  serverpod_auth_email_flutter: ^3.4.0
  serverpod_auth_google_flutter: ^3.4.0
  serverpod_auth_apple_flutter: ^3.4.0
```

---

## 2. Server Configuration

```dart
// bin/main.dart
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_server/serverpod_auth_server.dart' as auth;

void main(List<String> args) async {
  auth.AuthConfig.set(auth.AuthConfig(
    // Called when user registers or requests email validation
    sendValidationEmail: (session, email, validationCode) async {
      // Integrate your email provider here (SendGrid, AWS SES, Resend, etc.)
      session.log('Sending validation to $email, code: $validationCode');
      await MyEmailService.send(
        to: email,
        subject: 'Verify your account',
        body: 'Your code: $validationCode',
      );
      return true; // Return false to block registration
    },

    // Called when user requests a password reset
    sendPasswordResetEmail: (session, userInfo, validationCode) async {
      await MyEmailService.send(
        to: userInfo.email!,
        subject: 'Reset your password',
        body: 'Your reset code: $validationCode',
      );
      return true;
    },

    // 3.4.x: Restrict allowed origins (important for web)
    allowedRequestOrigins: [
      'https://myapp.com',
      'http://localhost:3000',
    ],

    // Optional: Customize minimum password length (default: 8)
    minPasswordLength: 12,

    // Optional: Block disposable email domains
    extraSafetyChecks: true,
  ));

  final pod = Serverpod(args, Protocol(), Endpoints());
  await pod.start();
}
```

---

## 3. Email / Password Authentication

### Sign Up

```dart
// Flutter client
import 'package:serverpod_auth_email_flutter/serverpod_auth_email_flutter.dart';

Future<void> signUp({
  required String email,
  required String password,
  required String displayName,
}) async {
  final success = await EmailAuth.createAccount(
    email: email.trim().toLowerCase(),
    password: password,
    displayName: displayName.trim(),
  );
  if (!success) throw Exception('Registration failed — email may already be in use');
}
```

### Email Verification

After `createAccount`, the user receives a 6-digit code. Verify it:

```dart
Future<void> verifyEmail(String email, String code) async {
  final success = await EmailAuth.validateAccount(
    email: email.trim().toLowerCase(),
    verificationCode: code.trim(),
  );
  if (!success) throw Exception('Invalid or expired verification code');
}
```

### Sign In

```dart
Future<void> signIn(String email, String password) async {
  final response = await EmailAuth.signIn(
    email: email.trim().toLowerCase(),
    password: password,
  );
  if (!response.success) {
    final reason = response.failReason?.name ?? 'Unknown error';
    throw Exception('Sign in failed: $reason');
  }
  await SessionManager.instance.registerSignedInUser(
    response.userInfo!,
    response.keyId!,
    response.key!,
  );
}
```

### Password Reset

```dart
// Step 1: Request reset code
Future<void> requestReset(String email) async {
  await EmailAuth.initiatePasswordReset(
    email: email.trim().toLowerCase(),
  );
}

// Step 2: Set new password using the code
Future<void> confirmReset(String email, String code, String newPassword) async {
  final success = await EmailAuth.resetPassword(
    email: email.trim().toLowerCase(),
    verificationCode: code.trim(),
    password: newPassword,
  );
  if (!success) throw Exception('Password reset failed');
}
```

---

## 4. Google Sign-In

### Setup

1. Create a project in Google Cloud Console.
2. Add OAuth 2.0 Client IDs for Android and iOS.
3. Add the `google-services.json` / `GoogleService-Info.plist` to your Flutter app.
4. Configure in Serverpod's `config/passwords.yaml`:

```yaml
# config/passwords.yaml
google:
  clientId: "YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"
  clientSecret: "YOUR_CLIENT_SECRET"
```

### Flutter Client

```dart
import 'package:serverpod_auth_google_flutter/serverpod_auth_google_flutter.dart';

Future<void> signInWithGoogle() async {
  final response = await GoogleSignIn.authenticate();
  if (response == null) return; // User cancelled the sign-in

  await SessionManager.instance.registerSignedInUser(
    response.userInfo,
    response.keyId,
    response.key,
  );
}
```

---

## 5. Apple Sign-In

### Requirements

- iOS 13+ / macOS 10.15+
- App must have the Sign In with Apple capability enabled.
- Server must have an Apple Services key configured.

```yaml
# config/passwords.yaml
apple:
  teamId: "YOUR_TEAM_ID"
  keyId: "YOUR_KEY_ID"
  privateKey: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

### Flutter Client

```dart
import 'package:serverpod_auth_apple_flutter/serverpod_auth_apple_flutter.dart';

Future<void> signInWithApple() async {
  final response = await AppleSignIn.authenticate();
  if (response == null) return;

  await SessionManager.instance.registerSignedInUser(
    response.userInfo,
    response.keyId,
    response.key,
  );
}
```

---

## 6. Session Management

```dart
// Initialize at app startup (before using client)
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final sessionManager = await SessionManager.instance.initialize();

  // Create the Serverpod client with session manager
  client = Client(
    'https://api.myapp.com/',
    authenticationKeyManager: FlutterAuthenticationKeyManager(),
  )..connectivityMonitor = FlutterConnectivityMonitor();

  runApp(MyApp());
}

// Check if signed in
bool get isSignedIn => SessionManager.instance.isSignedIn;

// Get current user info
UserInfo? get currentUser => SessionManager.instance.signedInUser;
int? get currentUserId => SessionManager.instance.signedInUser?.id;

// Sign out (invalidates server-side session)
Future<void> signOut() async {
  await SessionManager.instance.signOut();
  // Navigate to login screen
}

// Listen for auth state changes
SessionManager.instance.addListener(() {
  final isSignedIn = SessionManager.instance.isSignedIn;
  // Update UI accordingly
});
```

---

## 7. Protecting Endpoints

### Whole Endpoint

```dart
class AdminEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  // All methods in this endpoint require authentication
  Future<List<User>> getAllUsers(Session session) async {
    // session.auth is guaranteed non-null here
    final userId = await session.auth.authenticatedUserId;
    session.log('Admin ${userId} listed all users');
    return await UserInfo.db.find(session);
  }
}
```

### Per-Method

```dart
class MixedEndpoint extends Endpoint {
  /// Public — no login required
  Future<List<Product>> listProducts(Session session) async {
    return await Product.db.find(session);
  }

  /// Requires authentication — checked manually
  Future<Order> placeOrder(Session session, int productId) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();
    // ...
  }
}
```

---

## 8. Token Refresh

Serverpod handles token refresh automatically via the `FlutterAuthenticationKeyManager`. The client re-authenticates transparently when a token expires. No manual token management is needed.

---

## 9. Multi-Factor Authentication (3.4.x)

Serverpod 3.4.x provides hooks to implement TOTP-based MFA through `AuthConfig`:

```dart
auth.AuthConfig.set(auth.AuthConfig(
  // ... other config ...
  onUserCreated: (session, userInfo) async {
    // Called after successful account creation
    // Optionally generate and store MFA secret here
  },
  validateAuthentication: (session, userId, method) async {
    // Custom validation logic (e.g., check if MFA is enabled and prompt)
    // Return true to allow, false to block
    return true;
  },
));
```

---

## 10. Security Best Practices

- Always use HTTPS in production; set `publicScheme: https`.
- Store `passwords.yaml` in a secrets manager (AWS Secrets Manager, HashiCorp Vault), never in version control.
- Set `minPasswordLength: 12` or higher.
- Rate-limit login endpoints via reverse proxy (Nginx `limit_req`).
- Rotate `serviceSecret` periodically and update all server instances.
- Log authentication events for audit trails (Serverpod's built-in logging covers this).
- Enable `extraSafetyChecks: true` to block disposable email addresses.
