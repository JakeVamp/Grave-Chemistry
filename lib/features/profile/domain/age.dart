/// Age rules shared by validation and display. The database applies the
/// same rules in the `profiles_before_write` trigger.
abstract final class AgePolicy {
  static const int minimumAge = 18;

  /// Earliest birth date the database accepts.
  static final DateTime earliestBirthDate = DateTime.utc(1900);

  /// Today's calendar date in UTC, matching the database's notion of "today".
  static DateTime todayUtc([DateTime? now]) {
    final utc = (now ?? DateTime.now()).toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  /// Whole years between [birthDate] and [today]. Someone born on 29 February
  /// turns a year older on 1 March in non-leap years, as in Postgres `age()`.
  static int ageOn(DateTime birthDate, DateTime today) {
    var age = today.year - birthDate.year;
    final hadBirthdayThisYear =
        today.month > birthDate.month ||
        (today.month == birthDate.month && today.day >= birthDate.day);
    if (!hadBirthdayThisYear) age--;
    return age;
  }

  /// Latest birth date that is old enough on [today].
  static DateTime latestAllowedBirthDate(DateTime today) {
    var candidate = DateTime.utc(
      today.year - minimumAge,
      today.month,
      today.day,
    );
    // DateTime normalises 29 Feb in a non-leap year to 1 March; step back so
    // the result is still old enough.
    while (ageOn(candidate, today) < minimumAge) {
      candidate = candidate.subtract(const Duration(days: 1));
    }
    return candidate;
  }
}
