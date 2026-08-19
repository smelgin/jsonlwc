/**
 * Tests for the metadata-backed locale reference data. These run against
 * the seeded IDP_Country__mdt / IDP_Language__mdt records, so they also
 * assert the seed itself is sane — a mistyped dial code fails here rather
 * than in production. Tests that need data the seed does not carry prime
 * the transaction cache instead.
 */
@IsTest
private class IdpLocaleDataTest {
  // ────────────────────────── dial codes ──────────────────────────

  @IsTest
  static void readsDialCodesFromMetadata() {
    Assert.areEqual('27', IdpLocaleData.dialCodeFor('ZA'));
    Assert.areEqual(
      '27',
      IdpLocaleData.dialCodeFor('  za  '),
      'case and whitespace tolerant'
    );
    Assert.areEqual(
      '254',
      IdpLocaleData.dialCodeFor('KE'),
      'a country the hardcoded Apex set never listed'
    );
    Assert.isNull(IdpLocaleData.dialCodeFor('XX'));
    Assert.isNull(IdpLocaleData.dialCodeFor(null));
    Assert.isNull(IdpLocaleData.dialCodeFor('  '));
    Assert.isTrue(IdpLocaleData.isKnownCountry('TZ'));
    Assert.isFalse(IdpLocaleData.isKnownCountry('XX'));
  }

  // ─────────────────────── decimal separators ─────────────────────

  @IsTest
  static void resolvesDecimalSeparatorCountryBeforeLanguage() {
    Assert.areEqual(
      ',',
      IdpLocaleData.decimalSeparatorFor('en-ZA'),
      'South Africa\'s comma beats English\'s dot'
    );
    Assert.areEqual('.', IdpLocaleData.decimalSeparatorFor('en-KE'));
    Assert.areEqual(
      ',',
      IdpLocaleData.decimalSeparatorFor('en_ZA'),
      'underscore and hyphen forms are the same tag'
    );
    Assert.areEqual(
      ',',
      IdpLocaleData.decimalSeparatorFor('af'),
      'no country subtag falls through to the language'
    );
    Assert.areEqual(
      '.',
      IdpLocaleData.decimalSeparatorFor('af-KE'),
      'Afrikaans prints comma decimals, but Kenya prints dots and wins'
    );
    Assert.isNull(IdpLocaleData.decimalSeparatorFor('zz-ZZ'));
    Assert.isNull(IdpLocaleData.decimalSeparatorFor(null));
  }

  @IsTest
  static void reportsWhetherALocaleIsSeeded() {
    Assert.isTrue(IdpLocaleData.isKnownLocale('pt-ZA'));
    Assert.isTrue(
      IdpLocaleData.isKnownLocale('sw'),
      'language alone is enough'
    );
    Assert.isTrue(
      IdpLocaleData.isKnownLocale('xx-ZA'),
      'an unknown language over a known country still resolves'
    );
    Assert.isFalse(IdpLocaleData.isKnownLocale('xx-ZZ'));
    Assert.isFalse(IdpLocaleData.isKnownLocale(null));
  }

  // ───────────────────────── month names ──────────────────────────

  @IsTest
  static void readsMonthNamesPerLanguage() {
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('March', 'en'));
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('MARCH', 'en'));
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('Mar', 'en'));
    Assert.areEqual(2, IdpLocaleData.monthNumberFor('février', 'fr'));
    Assert.areEqual(
      2,
      IdpLocaleData.monthNumberFor('fevrier', 'fr-ZA'),
      'accents are folded away, so an OCR that lost them still reads'
    );
    Assert.areEqual(
      2,
      IdpLocaleData.monthNumberFor('Fev.', 'fr'),
      'a trailing abbreviation dot is dropped'
    );
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('Maart', 'af'));
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('Machi', 'sw'));
    Assert.areEqual(
      12,
      IdpLocaleData.monthNumberFor('Des', 'sw'),
      'Swahili Desemba, seeded for the East African markets'
    );
  }

  @IsTest
  static void resolvesPortugueseThreeLetterPrefixesAndRefusesTwo() {
    // The collision the impact assessment flagged: março and maio share
    // two letters, not three.
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('março', 'pt'));
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('mar', 'pt'));
    Assert.areEqual(5, IdpLocaleData.monthNumberFor('maio', 'pt-ZA'));
    Assert.areEqual(5, IdpLocaleData.monthNumberFor('mai', 'pt'));
    Assert.isNull(
      IdpLocaleData.monthNumberFor('ma', 'pt'),
      'two letters cannot identify a month and are not guessed at'
    );
  }

  @IsTest
  static void refusesAPrefixTwoMonthsShare() {
    Assert.isNull(
      IdpLocaleData.monthNumberFor('jui', 'fr'),
      'juin and juillet both start jui — undecidable, so no reading'
    );
    Assert.areEqual(6, IdpLocaleData.monthNumberFor('juin', 'fr'));
    Assert.areEqual(7, IdpLocaleData.monthNumberFor('juil', 'fr'));
    // A whole name that is also a prefix of a longer one: no seeded
    // language has that shape, so inject a language that does.
    IdpLocaleData.Language cz = new IdpLocaleData.Language();
    cz.months = IdpLocaleData.compileMonths(
      'leden|únor|březen|duben|květen|červen|červenec|srpen|září|říjen|listopad|prosinec'
    );
    IdpLocaleData.languageCache = new Map<String, IdpLocaleData.Language>{
      'cs' => cz
    };
    Assert.areEqual(
      6,
      IdpLocaleData.monthNumberFor('červen', 'cs'),
      'červen is a whole name and a prefix of červenec; the whole name wins'
    );
    Assert.areEqual(7, IdpLocaleData.monthNumberFor('červenec', 'cs'));
  }

  @IsTest
  static void fallsBackToEnglishForUnknownOrMonthlessLanguages() {
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('March', 'xx'),
      'an unseeded language still reads English'
    );
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('March', null));
    // Every seeded language currently declares months, so the
    // seeded-but-monthless case is injected rather than assumed.
    IdpLocaleData.Language numeric = new IdpLocaleData.Language();
    numeric.decimalSeparator = ',';
    IdpLocaleData.languageCache = new Map<String, IdpLocaleData.Language>{
      'vi' => numeric
    };
    Assert.isTrue(
      IdpLocaleData.isKnownLocale('vi'),
      'a language seeded only for its decimal separator is still known'
    );
    Assert.isFalse(
      IdpLocaleData.readsMonthNames('vi'),
      'but naming its months numerically, it declares none'
    );
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('March', 'vi'),
      'and it still falls back to English'
    );
    Assert.isNull(IdpLocaleData.monthNumberFor('', 'en'));
    Assert.isNull(IdpLocaleData.monthNumberFor('Nonsuch', 'en'));
  }

  // ─────────────────────── seeded data integrity ──────────────────

  @IsTest
  static void everySeededLanguageDeclaresTwelveUnambiguousMonths() {
    // Month_Names__c is a long text area, so it cannot be filtered in the
    // query — the blank ones are skipped here instead.
    for (IDP_Language__mdt record : [
      SELECT DeveloperName, Month_Names__c
      FROM IDP_Language__mdt
    ]) {
      if (String.isBlank(record.Month_Names__c)) {
        continue;
      }
      String code = record.DeveloperName;
      Assert.isTrue(
        IdpLocaleData.readsMonthNames(code),
        code +
        ' has Month Names that did not compile — it needs exactly 12 entries'
      );
      Set<Integer> seen = new Set<Integer>();
      for (String entry : record.Month_Names__c.split('\\|')) {
        String canonical = entry.split(',')[0];
        Integer month = IdpLocaleData.monthNumberFor(canonical, code);
        Assert.isNotNull(
          month,
          code + ': "' + canonical + '" does not resolve to a month'
        );
        seen.add(month);
      }
      Assert.areEqual(
        12,
        seen.size(),
        code + ': two months answer to the same name'
      );
    }
  }

  @IsTest
  static void everySeededCountryCarriesAPlausibleDialCode() {
    for (IDP_Country__mdt record : [
      SELECT DeveloperName, Dial_Code__c, Decimal_Separator__c
      FROM IDP_Country__mdt
    ]) {
      String code = record.DeveloperName;
      Assert.isTrue(
        Pattern.matches('[A-Z]{2}', code),
        code + ' is not an ISO 3166-1 alpha-2 code'
      );
      Assert.isTrue(
        Pattern.matches('[1-9][0-9]{0,3}', record.Dial_Code__c),
        code + ' has implausible dial code "' + record.Dial_Code__c + '"'
      );
      Assert.isTrue(
        record.Decimal_Separator__c == ',' ||
          record.Decimal_Separator__c == '.',
        code + ' has decimal separator "' + record.Decimal_Separator__c + '"'
      );
    }
  }

  // ──────────────────────── compilation rules ─────────────────────

  @IsTest
  static void ignoresAMonthListThatIsNotTwelveEntries() {
    Assert.isTrue(
      IdpLocaleData.compileMonths('Jan|Feb|Mar').isEmpty(),
      'a short list is unusable, not partially usable'
    );
    Assert.isTrue(IdpLocaleData.compileMonths(null).isEmpty());
    Assert.isTrue(
      IdpLocaleData.compileMonths(
          'Jan|Feb||Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec'
        )
        .isEmpty(),
      'a blank slot would silently shift every later month'
    );
  }

  @IsTest
  static void anOrgWithNoSeedDegradesToEnglishNotToNothing() {
    IdpLocaleData.countryCache = new Map<String, IdpLocaleData.Country>();
    IdpLocaleData.languageCache = new Map<String, IdpLocaleData.Language>();
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('March', 'fr'),
      'the compiled-in English fallback keeps ISO dates working'
    );
    Assert.isNull(IdpLocaleData.dialCodeFor('ZA'));
    Assert.isNull(IdpLocaleData.decimalSeparatorFor('en-ZA'));
  }

  @IsTest
  static void readsAnInjectedCountryAndLanguage() {
    IdpLocaleData.Country utopia = new IdpLocaleData.Country();
    utopia.dialCode = '999';
    utopia.decimalSeparator = '.';
    IdpLocaleData.countryCache = new Map<String, IdpLocaleData.Country>{
      'UT' => utopia
    };
    IdpLocaleData.Language utopian = new IdpLocaleData.Language();
    utopian.decimalSeparator = ',';
    utopian.months = IdpLocaleData.compileMonths(
      'Unus|Duo|Tres|Quattuor|Quinque|Sex|Septem|Octo|Novem|Decem|Undecim|Duodecim'
    );
    IdpLocaleData.languageCache = new Map<String, IdpLocaleData.Language>{
      'ut' => utopian
    };

    Assert.areEqual('999', IdpLocaleData.dialCodeFor('ut'));
    Assert.areEqual(',', IdpLocaleData.decimalSeparatorFor('ut'));
    Assert.areEqual(
      '.',
      IdpLocaleData.decimalSeparatorFor('ut-UT'),
      'the country still overrides its own language'
    );
    Assert.areEqual(9, IdpLocaleData.monthNumberFor('Novem', 'ut'));
  }
}
