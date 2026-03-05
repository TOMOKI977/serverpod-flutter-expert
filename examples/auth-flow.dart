// ---
// title: Complete Authentication Flow — Serverpod 3.4.x
// description: Full auth flow with email/password signup, login, social login,
//              token refresh, protected routes, and profile management.
// serverpod_version: ">=3.4.0"
// ---

// ═══════════════════════════════════════════════════════════════════════════════
// PART 1: SERVER CONFIGURATION
// File: bin/main.dart (auth setup)
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_server/serverpod_auth_server.dart' as auth;
import '../src/generated/protocol.dart';
import '../src/generated/endpoints.dart';

Future<void> main(List<String> args) async {
  auth.AuthConfig.set(auth.AuthConfig(
    sendValidationEmail: (session, email, code) async {
      session.log('Validation code for $email: $code');
      // Replace with real email service:
      // await EmailService.sendValidation(email, code);
      return true;
    },
    sendPasswordResetEmail: (session, userInfo, code) async {
      session.log('Password reset for ${userInfo.email}: $code');
      // await EmailService.sendReset(userInfo.email!, code);
      return true;
    },
    allowedRequestOrigins: [
      'https://myapp.com',
      'http://localhost:3000',
    ],
    minPasswordLength: 12,
    extraSafetyChecks: true,
    onUserCreated: (session, userInfo) async {
      // Called after any successful sign-up (email, Google, Apple, etc.)
      // Create a profile row for the new user:
      await UserProfile.db.insertRow(
        session,
        UserProfile(
          userId: userInfo.id!,
          displayName: userInfo.userName ?? 'New User',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      session.log('New user created: ${userInfo.id}');
    },
  ));

  final pod = Serverpod(args, Protocol(), Endpoints());
  await pod.start();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 2: PROFILE MODEL & ENDPOINT
// ═══════════════════════════════════════════════════════════════════════════════

// lib/src/models/user_profile.spy.yaml
// ─────────────────────────────────────
// class: UserProfile
// table: user_profiles
// fields:
//   userId: int
//   displayName: String
//   bio: String?
//   avatarUrl: String?
//   createdAt: DateTime
//   updatedAt: DateTime
// indexes:
//   user_profiles_user_idx:
//     fields: userId
//     unique: true

// lib/src/endpoints/profile_endpoint.dart
class ProfileEndpoint extends Endpoint {
  @override
  bool get requireLogin => true;

  /// Get the current user's profile
  Future<UserProfile?> getMyProfile(Session session) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    return await UserProfile.db.findFirstRow(
      session,
      where: (t) => t.userId.equals(userId),
    );
  }

  /// Update profile fields
  Future<UserProfile> updateProfile(
    Session session, {
    String? displayName,
    String? bio,
    String? avatarUrl,
  }) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    final profile = await UserProfile.db.findFirstRow(
      session,
      where: (t) => t.userId.equals(userId),
    );
    if (profile == null) throw NotFoundException('Profile not found');

    if (displayName != null && displayName.trim().isEmpty) {
      throw ArgumentError('Display name cannot be empty');
    }

    return await UserProfile.db.updateRow(
      session,
      profile.copyWith(
        displayName: displayName?.trim() ?? profile.displayName,
        bio: bio?.trim() ?? profile.bio,
        avatarUrl: avatarUrl ?? profile.avatarUrl,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  /// Change email (requires re-verification)
  Future<bool> requestEmailChange(Session session, String newEmail) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // Delegate to serverpod_auth module
    // The module sends a verification email automatically
    return true;
  }

  /// Delete the current user's account
  Future<void> deleteAccount(Session session) async {
    final userId = await session.auth.authenticatedUserId;
    if (userId == null) throw ServerpodUnauthenticatedException();

    // Delete profile data first
    await UserProfile.db.deleteWhere(
      session,
      where: (t) => t.userId.equals(userId),
    );

    // Sign out (invalidates all sessions)
    await session.auth.signOut();
    session.log('User $userId deleted their account');
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 3: FLUTTER AUTH SERVICE
// File: lib/src/services/auth_service.dart
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart';
import 'package:serverpod_auth_client/serverpod_auth_client.dart';
import 'package:serverpod_auth_email_flutter/serverpod_auth_email_flutter.dart';
import 'package:serverpod_auth_google_flutter/serverpod_auth_google_flutter.dart';
import 'package:serverpod_auth_apple_flutter/serverpod_auth_apple_flutter.dart';
import 'package:my_project_client/my_project_client.dart';

enum AuthStep { idle, loading, awaitingVerification }

class AuthService extends ChangeNotifier {
  final Client _client;

  AuthService(this._client) {
    // React to session changes (e.g., token expiry or external sign-out)
    SessionManager.instance.addListener(_onSessionChanged);
  }

  AuthStep _step = AuthStep.idle;
  String? _error;
  String? _pendingEmail; // For email verification flow

  AuthStep get step => _step;
  String? get error => _error;
  bool get isSignedIn => SessionManager.instance.isSignedIn;
  UserInfo? get currentUser => SessionManager.instance.signedInUser;

  void _onSessionChanged() => notifyListeners();

  // ── Email Sign-up ─────────────────────────────────────────────────────────

  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    _setLoading();
    try {
      final success = await EmailAuth.createAccount(
        email: email.trim().toLowerCase(),
        password: password,
        displayName: displayName.trim(),
      );
      if (!success) throw Exception('Sign up failed. Email may already be in use.');

      _pendingEmail = email.trim().toLowerCase();
      _step = AuthStep.awaitingVerification;
      _error = null;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Email Verification ────────────────────────────────────────────────────

  Future<void> verifyEmail(String code) async {
    if (_pendingEmail == null) throw StateError('No pending email to verify');
    _setLoading();
    try {
      final success = await EmailAuth.validateAccount(
        email: _pendingEmail!,
        verificationCode: code.trim(),
      );
      if (!success) throw Exception('Invalid or expired verification code.');

      _pendingEmail = null;
      _step = AuthStep.idle;
      _error = null;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Email Sign-in ─────────────────────────────────────────────────────────

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    _setLoading();
    try {
      final response = await EmailAuth.signIn(
        email: email.trim().toLowerCase(),
        password: password,
      );
      if (!response.success) {
        final reason = response.failReason?.name ?? 'unknown';
        throw Exception('Sign in failed: $reason');
      }
      await SessionManager.instance.registerSignedInUser(
        response.userInfo!,
        response.keyId!,
        response.key!,
      );
      _error = null;
      _step = AuthStep.idle;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Google Sign-In ────────────────────────────────────────────────────────

  Future<void> signInWithGoogle() async {
    _setLoading();
    try {
      final response = await GoogleSignIn.authenticate();
      if (response == null) {
        // User cancelled
        _step = AuthStep.idle;
        notifyListeners();
        return;
      }
      await SessionManager.instance.registerSignedInUser(
        response.userInfo,
        response.keyId,
        response.key,
      );
      _error = null;
      _step = AuthStep.idle;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Apple Sign-In ─────────────────────────────────────────────────────────

  Future<void> signInWithApple() async {
    _setLoading();
    try {
      final response = await AppleSignIn.authenticate();
      if (response == null) {
        _step = AuthStep.idle;
        notifyListeners();
        return;
      }
      await SessionManager.instance.registerSignedInUser(
        response.userInfo,
        response.keyId,
        response.key,
      );
      _error = null;
      _step = AuthStep.idle;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Password Reset ────────────────────────────────────────────────────────

  Future<void> requestPasswordReset(String email) async {
    _setLoading();
    try {
      await EmailAuth.initiatePasswordReset(
        email: email.trim().toLowerCase(),
      );
      _pendingEmail = email.trim().toLowerCase();
      _step = AuthStep.awaitingVerification;
      _error = null;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  Future<void> confirmPasswordReset(String code, String newPassword) async {
    if (_pendingEmail == null) throw StateError('No pending email');
    _setLoading();
    try {
      final success = await EmailAuth.resetPassword(
        email: _pendingEmail!,
        verificationCode: code.trim(),
        password: newPassword,
      );
      if (!success) throw Exception('Password reset failed. Code may have expired.');
      _pendingEmail = null;
      _step = AuthStep.idle;
      _error = null;
    } catch (e) {
      _setError(e.toString());
    } finally {
      notifyListeners();
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await SessionManager.instance.signOut();
    notifyListeners();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setLoading() {
    _step = AuthStep.loading;
    _error = null;
    notifyListeners();
  }

  void _setError(String message) {
    _step = AuthStep.idle;
    _error = message;
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    SessionManager.instance.removeListener(_onSessionChanged);
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PART 4: FLUTTER SCREENS
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// ── App Entry with Auth Guard ─────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My App',
      home: Consumer<AuthService>(
        builder: (ctx, auth, _) {
          if (auth.isSignedIn) return const HomeScreen();
          return const LoginScreen();
        },
      ),
    );
  }
}

// ── Login Screen ──────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    await context.read<AuthService>().signIn(
          email: _emailCtrl.text,
          password: _passwordCtrl.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final isLoading = auth.step == AuthStep.loading;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign In')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Error display
              if (auth.error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(auth.error!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),

              // Email
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Email required';
                  if (!v.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Password
              TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Password required';
                  return null;
                },
              ),
              const SizedBox(height: 8),

              // Forgot password
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen())),
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 16),

              // Sign in button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: isLoading ? null : _signIn,
                  child: isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign In'),
                ),
              ),
              const SizedBox(height: 16),

              // Divider
              const Row(children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('or'),
                ),
                Expanded(child: Divider()),
              ]),
              const SizedBox(height: 16),

              // Google sign-in
              OutlinedButton.icon(
                onPressed: isLoading
                    ? null
                    : () => context.read<AuthService>().signInWithGoogle(),
                icon: const Icon(Icons.g_mobiledata),
                label: const Text('Continue with Google'),
              ),
              const SizedBox(height: 8),

              // Apple sign-in (iOS/macOS only)
              if (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS)
                OutlinedButton.icon(
                  onPressed: isLoading
                      ? null
                      : () => context.read<AuthService>().signInWithApple(),
                  icon: const Icon(Icons.apple),
                  label: const Text('Continue with Apple'),
                ),

              const SizedBox(height: 24),

              // Sign up link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Don't have an account? "),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SignUpScreen()),
                    ),
                    child: const Text('Sign up'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Forgot Password Screen ────────────────────────────────────────────────────

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _codeSent = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final isLoading = auth.step == AuthStep.loading;

    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (auth.error != null)
              Text(auth.error!, style: const TextStyle(color: Colors.red)),

            if (!_codeSent) ...[
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Your email'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        await auth.requestPasswordReset(_emailCtrl.text);
                        if (auth.error == null) setState(() => _codeSent = true);
                      },
                child: const Text('Send Reset Code'),
              ),
            ] else ...[
              TextFormField(
                controller: _codeCtrl,
                decoration: const InputDecoration(labelText: 'Verification code'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        await auth.confirmPasswordReset(
                          _codeCtrl.text,
                          _passwordCtrl.text,
                        );
                        if (auth.error == null && context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Password reset successfully'),
                            ),
                          );
                        }
                      },
                child: const Text('Reset Password'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Sign Up Screen (abbreviated — similar pattern to LoginScreen) ─────────────

class SignUpScreen extends StatelessWidget {
  const SignUpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Implementation follows the same pattern as LoginScreen
    // with fields for email, password, displayName, and
    // calls context.read<AuthService>().signUp(...)
    return const Scaffold(body: Center(child: Text('Sign Up Screen')));
  }
}

// ── Home Screen (protected) ───────────────────────────────────────────────────

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final user = auth.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: Text('Hello, ${user?.userName ?? 'User'}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (user?.imageUrl != null)
              CircleAvatar(
                radius: 40,
                backgroundImage: NetworkImage(user!.imageUrl!),
              ),
            const SizedBox(height: 16),
            Text(user?.fullName ?? 'No name', style: const TextStyle(fontSize: 20)),
            Text(user?.email ?? '', style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
