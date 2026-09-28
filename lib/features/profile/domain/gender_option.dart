/// Mirrors rows in `public.gender_options`. Deliberately not a binary; add
/// values as rows in the database and here.
enum GenderOption {
  woman('woman', 'Woman'),
  man('man', 'Man'),
  nonBinary('non_binary', 'Non-binary'),
  transWoman('trans_woman', 'Trans woman'),
  transMan('trans_man', 'Trans man'),
  genderqueer('genderqueer', 'Genderqueer'),
  genderfluid('genderfluid', 'Genderfluid'),
  agender('agender', 'Agender'),

  /// Paired with a free-text self-description.
  selfDescribe('self_describe', 'Self-describe');

  const GenderOption(this.code, this.label);

  final String code;
  final String label;

  static GenderOption? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
