import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';

/// A labelled single-choice form field rendered as radio list tiles, which
/// wrap cleanly with large accessibility text.
class ChoiceGroupField<T extends Object> extends FormField<T> {
  ChoiceGroupField({
    super.key,
    required String label,
    required List<T> options,
    required String Function(T option) optionLabel,
    required ValueChanged<T> onChanged,
    super.initialValue,
    super.validator,
    super.enabled,
    super.autovalidateMode,
  }) : super(
         builder: (field) {
           final context = field.context;
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
               Text(label, style: context.textTheme.titleSmall),
               const SizedBox(height: AppSpacing.xs),
               RadioGroup<T>(
                 groupValue: field.value,
                 onChanged: (value) {
                   if (value == null || !field.widget.enabled) return;
                   field.didChange(value);
                   onChanged(value);
                 },
                 child: Column(
                   children: [
                     for (final option in options)
                       RadioListTile<T>(
                         value: option,
                         enabled: field.widget.enabled,
                         title: Text(optionLabel(option)),
                         contentPadding: EdgeInsets.zero,
                       ),
                   ],
                 ),
               ),
               if (field.hasError)
                 Semantics(
                   liveRegion: true,
                   child: Text(
                     field.errorText!,
                     style: context.textTheme.bodySmall?.copyWith(
                       color: context.colors.error,
                     ),
                   ),
                 ),
             ],
           );
         },
       );
}
