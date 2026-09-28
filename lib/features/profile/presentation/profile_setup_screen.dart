import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../../shared/widgets/loading_button.dart';
import '../../../shared/widgets/message_banner.dart';
import '../../auth/application/auth_providers.dart';
import '../application/profile_providers.dart';
import '../domain/age.dart';
import '../domain/community_identity.dart';
import '../domain/dating_preference.dart';
import '../domain/gender_option.dart';
import '../domain/profile_draft.dart';
import '../domain/profile_failure.dart';
import '../domain/profile_validators.dart';
import 'widgets/birth_date_field.dart';
import 'widgets/choice_group_field.dart';

/// First-time onboarding. The router keeps signed-in users here until the
/// database reports their profile as complete.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _preferenceKey = GlobalKey<FormFieldState<DatingPreference>>();
  final _scrollController = ScrollController();
  final _displayName = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _bio = TextEditingController();
  final _genderDescription = TextEditingController();

  final DateTime _today = AgePolicy.todayUtc();
  DateTime? _birthDate;
  GenderOption? _gender;
  CommunityIdentity? _identity;
  DatingPreference? _preference;

  bool _submitted = false;
  bool _saving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Resume a partially saved profile, if one exists.
    final existing = ref.read(profileControllerProvider).value;
    if (existing != null) {
      _displayName.text = existing.displayName ?? '';
      _city.text = existing.city ?? '';
      _region.text = existing.region ?? '';
      _bio.text = existing.bio ?? '';
      _genderDescription.text = existing.genderSelfDescription ?? '';
      _birthDate = existing.birthDate;
      _gender = existing.gender;
      _identity = existing.communityIdentity;
      _preference = existing.datingPreference;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _displayName.dispose();
    _city.dispose();
    _region.dispose();
    _bio.dispose();
    _genderDescription.dispose();
    super.dispose();
  }

  AutovalidateMode get _autovalidate => _submitted
      ? AutovalidateMode.onUserInteraction
      : AutovalidateMode.disabled;

  ProfileDraft get _draft => ProfileDraft(
    displayName: _displayName.text,
    birthDate: _birthDate,
    city: _city.text,
    region: _region.text,
    bio: _bio.text,
    gender: _gender,
    genderSelfDescription: _genderDescription.text,
    communityIdentity: _identity,
    datingPreference: _preference,
  );

  Future<void> _save() async {
    setState(() {
      _submitted = true;
      _errorMessage = null;
    });

    final invalid = _formKey.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      // Bring the first problem into view; important on small screens.
      await Scrollable.ensureVisible(
        invalid.first.context,
        duration: const Duration(milliseconds: 250),
        alignment: 0.1,
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(profileControllerProvider.notifier)
          .save(_draft);
      // On success the router moves the user into the app.
      if (!saved.isCompleted && mounted) {
        setState(() {
          _errorMessage =
              "Your profile was saved but isn't complete yet. Please review "
              'your answers.';
        });
      }
    } on ProfileFailure catch (failure) {
      if (mounted) setState(() => _errorMessage = failure.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (_errorMessage != null && _scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _onIdentityChanged(CommunityIdentity identity) {
    setState(() => _identity = identity);
    // Re-check the preference against the new identity, but never change it.
    if (_submitted) _preferenceKey.currentState?.validate();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_saving;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create your profile'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () => ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: _autovalidate,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Tell us a little about yourself. You can change these '
                      'details later.',
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      MessageBanner(message: _errorMessage!),
                    ],
                    const _SectionHeading('About you'),
                    TextFormField(
                      controller: _displayName,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      maxLength: ProfileValidators.displayNameMaxLength,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.nickname],
                      validator: ProfileValidators.displayName,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    BirthDateField(
                      initialValue: _birthDate,
                      today: _today,
                      enabled: enabled,
                      onChanged: (date) => setState(() => _birthDate = date),
                      validator: (date) =>
                          ProfileValidators.birthDate(date, today: _today),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    DropdownButtonFormField<GenderOption>(
                      initialValue: _gender,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Gender',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      items: [
                        for (final option in GenderOption.values)
                          DropdownMenuItem(
                            value: option,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: enabled
                          ? (value) => setState(() => _gender = value)
                          : null,
                      validator: ProfileValidators.gender,
                    ),
                    if (_gender == GenderOption.selfDescribe) ...[
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        controller: _genderDescription,
                        enabled: enabled,
                        decoration: const InputDecoration(
                          labelText: 'Describe your gender',
                        ),
                        maxLength:
                            ProfileValidators.genderSelfDescriptionMaxLength,
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            ProfileValidators.genderSelfDescription(
                              value,
                              _gender,
                            ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _bio,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: 'Bio (optional)',
                        alignLabelWithHint: true,
                      ),
                      minLines: 3,
                      maxLines: 6,
                      maxLength: ProfileValidators.bioMaxLength,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      validator: ProfileValidators.bio,
                    ),
                    const _SectionHeading('Location'),
                    Text(
                      'Entered as text only. We never use your GPS location.',
                      style: context.textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _city,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: 'City',
                        prefixIcon: Icon(Icons.location_city_outlined),
                      ),
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.addressCity],
                      validator: ProfileValidators.city,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _region,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: 'State / region',
                        prefixIcon: Icon(Icons.map_outlined),
                      ),
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.addressState],
                      validator: ProfileValidators.region,
                    ),
                    const _SectionHeading('Your scene'),
                    ChoiceGroupField<CommunityIdentity>(
                      label: 'I am',
                      options: CommunityIdentity.values,
                      optionLabel: (option) => option.label,
                      initialValue: _identity,
                      enabled: enabled,
                      onChanged: _onIdentityChanged,
                      validator: ProfileValidators.communityIdentity,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    ChoiceGroupField<DatingPreference>(
                      key: _preferenceKey,
                      label: 'Dating preference',
                      options: DatingPreference.values,
                      optionLabel: (option) => option.label,
                      initialValue: _preference,
                      enabled: enabled,
                      onChanged: (value) => setState(() => _preference = value),
                      validator: (value) =>
                          ProfileValidators.datingPreference(value, _identity),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    LoadingButton(
                      label: 'Save profile',
                      isLoading: _saving,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.md),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Container(width: 3, height: 20, color: context.colors.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(text, style: context.textTheme.titleMedium)),
          ],
        ),
      ),
    );
  }
}
