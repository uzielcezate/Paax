// lib/core/config/supabase_config.dart
//
// Supabase client configuration for Paax (Phase 3.1).
//
// The Flutter app uses ONLY the public anon / publishable key. The
// service-role key must NEVER live in the app — all privileged operations
// happen in paax-api (backend). RLS protects every table.
//
// Values are compile-time overridable so CI / release builds can inject them:
//
//   flutter build apk \
//     --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
//     --dart-define=SUPABASE_ANON_KEY=<public-anon-key>
//
// The defaults below are the PUBLIC project URL + anon key (safe to ship —
// they are designed to be embedded in clients and are gated by RLS). See
// docs/environment.md and docs/features/authentication.md.

class SupabaseConfig {
  SupabaseConfig._();

  /// Public project URL. Override with --dart-define=SUPABASE_URL=...
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://jecgmiuypuathhvjuhea.supabase.co',
  );

  /// PUBLIC anon key (RLS-protected). NOT the service-role key.
  /// Override with --dart-define=SUPABASE_ANON_KEY=...
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImplY2dtaXV5cHVhdGhodmp1aGVhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxNjM2NDIsImV4cCI6MjA5OTczOTY0Mn0.DXC37LMDUTEjk6GD195iEk2d723uGhOxORel63pkwwo',
  );

  /// Deep-link scheme + hosts used for auth callbacks (must match the native
  /// intent-filter / URL scheme and the Supabase Dashboard redirect URLs).
  static const String scheme = 'paax';
  static const String emailConfirmRedirect = 'paax://auth/confirm';
  static const String passwordResetRedirect = 'paax://auth/reset-password';

  /// True only when both values are present (defaults make this always true,
  /// but a build could pass empty overrides).
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
