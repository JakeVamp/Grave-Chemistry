/// Liveness challenges the backend can issue. The server picks one per
/// session; the app only displays it and can never mark it as passed.
enum VerificationChallenge {
  lookStraight('look_straight', 'Look straight at the camera'),
  turnHeadLeft('turn_head_left', 'Turn your head slightly to the left'),
  turnHeadRight('turn_head_right', 'Turn your head slightly to the right'),
  blink('blink', 'Blink while taking the photo'),
  smile('smile', 'Smile');

  const VerificationChallenge(this.code, this.instruction);

  final String code;
  final String instruction;

  static VerificationChallenge? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
