import 'package:flutter/material.dart';

import '../../domain/age.dart';

/// Birth date form field that opens a date picker. The picker also offers
/// typed entry, which is easier for many users than scrolling back decades.
class BirthDateField extends FormField<DateTime> {
  BirthDateField({
    super.key,
    required DateTime today,
    required ValueChanged<DateTime> onChanged,
    super.initialValue,
    super.validator,
    super.enabled,
  }) : super(
         builder: (field) {
           final context = field.context;
           final value = field.value;
           final text = value == null
               ? null
               : MaterialLocalizations.of(context).formatMediumDate(value);

           Future<void> pick() async {
             final picked = await showDatePicker(
               context: context,
               helpText: 'Select your birth date',
               initialDate: value ?? AgePolicy.latestAllowedBirthDate(today),
               firstDate: AgePolicy.earliestBirthDate,
               // Allows dates up to today so under-18 users see a clear
               // message rather than an unexplained limit.
               lastDate: today,
               initialDatePickerMode: DatePickerMode.year,
             );
             if (picked == null) return;
             final date = DateTime.utc(picked.year, picked.month, picked.day);
             field.didChange(date);
             onChanged(date);
           }

           return Semantics(
             button: true,
             label: 'Birth date',
             value: text ?? 'Not set',
             excludeSemantics: true,
             child: InkWell(
               onTap: field.widget.enabled ? pick : null,
               borderRadius: BorderRadius.circular(12),
               child: InputDecorator(
                 isEmpty: value == null,
                 decoration: InputDecoration(
                   labelText: 'Birth date',
                   helperText: 'Kept private. You must be 18 or older.',
                   helperMaxLines: 2,
                   errorText: field.errorText,
                   errorMaxLines: 3,
                   enabled: field.widget.enabled,
                   prefixIcon: const Icon(Icons.cake_outlined),
                   suffixIcon: const Icon(Icons.calendar_month_outlined),
                 ),
                 child: Text(text ?? ''),
               ),
             ),
           );
         },
       );
}
