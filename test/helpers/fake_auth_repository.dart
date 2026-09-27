import 'dart:async';

import 'package:grave_chemistry/features/auth/domain/auth_event.dart';
import 'package:grave_chemistry/features/auth/domain/auth_failure.dart';
import 'package:grave_chemistry/features/auth/domain/auth_repository.dart';
import 'package:grave_chemistry/features/auth/domain/auth_user.dart';
import 'package:grave_chemistry/features/auth/domain/sign_up_result.dart';

const testUser = AuthUser(id: 'user-1', email: 'raven@example.com');

/// In-memory [AuthRepository] that mimics Supabase's event behaviour.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this._currentUser});

  AuthUser? _currentUser;
  final _events = StreamController<AuthEvent>.broadcast();

  /// Thrown (once) by the next request.
  AuthFailure? nextFailure;

  /// When set, requests wait for it to complete, to observe loading states.
  Completer<void>? gate;

  SignUpResult signUpResult = SignUpResult.confirmationRequired;
  final List<String> calls = [];

  @override
  AuthUser? get currentUser => _currentUser;

  @override
  Stream<AuthEvent> get events => _events.stream;

  void emit(AuthEventType type, [AuthUser? user]) {
    _currentUser = type == AuthEventType.signedOut ? null : user;
    _events.add(AuthEvent(type, _currentUser));
  }

  void emitError(AuthFailure failure) => _events.addError(failure);

  Future<void> _request(String call) async {
    calls.add(call);
    if (gate != null) await gate!.future;
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw failure;
    }
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _request('signIn:$email');
    emit(AuthEventType.signedIn, AuthUser(id: 'user-1', email: email));
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
  }) async {
    await _request('signUp:$email');
    if (signUpResult == SignUpResult.signedIn) {
      emit(AuthEventType.signedIn, AuthUser(id: 'user-1', email: email));
    }
    return signUpResult;
  }

  @override
  Future<void> resendConfirmationEmail(String email) =>
      _request('resend:$email');

  @override
  Future<void> sendPasswordResetEmail(String email) => _request('reset:$email');

  @override
  Future<void> updatePassword(String newPassword) async {
    await _request('updatePassword');
    emit(AuthEventType.userUpdated, _currentUser);
  }

  @override
  Future<void> signOut() async {
    await _request('signOut');
    emit(AuthEventType.signedOut);
  }
}
