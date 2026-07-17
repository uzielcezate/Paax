// lib/core/auth/demographics.dart
//
// Static option data for registration/profile: inclusive gender identities and
// a curated ISO-3166 alpha-2 country list. gender_identity is free text (<=60)
// in the schema, so the stored value is the selected label (or a self-described
// string). Keeps a "Prefer not to say" option.

class GenderOptions {
  static const preferNotToSay = 'Prefer not to say';
  static const selfDescribe = 'Self-describe';

  /// Selectable labels shown in the dropdown.
  static const List<String> labels = [
    'Woman',
    'Man',
    'Non-binary',
    preferNotToSay,
    selfDescribe,
  ];
}

class Country {
  final String code; // ISO alpha-2, uppercase
  final String name;
  const Country(this.code, this.name);
}

class Countries {
  /// Curated list (major markets + broad coverage). country_code stores `code`.
  static const List<Country> all = [
    Country('MX', 'Mexico'),
    Country('US', 'United States'),
    Country('CA', 'Canada'),
    Country('AR', 'Argentina'),
    Country('BO', 'Bolivia'),
    Country('BR', 'Brazil'),
    Country('CL', 'Chile'),
    Country('CO', 'Colombia'),
    Country('CR', 'Costa Rica'),
    Country('CU', 'Cuba'),
    Country('DO', 'Dominican Republic'),
    Country('EC', 'Ecuador'),
    Country('SV', 'El Salvador'),
    Country('GT', 'Guatemala'),
    Country('HN', 'Honduras'),
    Country('NI', 'Nicaragua'),
    Country('PA', 'Panama'),
    Country('PY', 'Paraguay'),
    Country('PE', 'Peru'),
    Country('PR', 'Puerto Rico'),
    Country('UY', 'Uruguay'),
    Country('VE', 'Venezuela'),
    Country('ES', 'Spain'),
    Country('PT', 'Portugal'),
    Country('FR', 'France'),
    Country('DE', 'Germany'),
    Country('IT', 'Italy'),
    Country('GB', 'United Kingdom'),
    Country('IE', 'Ireland'),
    Country('NL', 'Netherlands'),
    Country('BE', 'Belgium'),
    Country('CH', 'Switzerland'),
    Country('SE', 'Sweden'),
    Country('NO', 'Norway'),
    Country('DK', 'Denmark'),
    Country('FI', 'Finland'),
    Country('PL', 'Poland'),
    Country('AT', 'Austria'),
    Country('GR', 'Greece'),
    Country('RO', 'Romania'),
    Country('AU', 'Australia'),
    Country('NZ', 'New Zealand'),
    Country('JP', 'Japan'),
    Country('KR', 'South Korea'),
    Country('CN', 'China'),
    Country('IN', 'India'),
    Country('ID', 'Indonesia'),
    Country('PH', 'Philippines'),
    Country('ZA', 'South Africa'),
    Country('NG', 'Nigeria'),
    Country('EG', 'Egypt'),
    Country('MA', 'Morocco'),
    Country('TR', 'Turkey'),
    Country('AE', 'United Arab Emirates'),
    Country('SA', 'Saudi Arabia'),
    Country('IL', 'Israel'),
  ];

  static String? nameFor(String? code) {
    if (code == null) return null;
    for (final c in all) {
      if (c.code == code) return c.name;
    }
    return null;
  }
}
