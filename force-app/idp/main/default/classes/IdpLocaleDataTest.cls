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
    Assert.areEqual('27', IdpLocaleData.dialCodeFor('  za  '), 'case and whitespace tolerant');
    Assert.areEqual(
      '46',
      IdpLocaleData.dialCodeFor('SE'),
      'a country the hardcoded Apex set never listed'
    );
    Assert.isNull(IdpLocaleData.dialCodeFor('XX'));
    Assert.isNull(IdpLocaleData.dialCodeFor(null));
    Assert.isNull(IdpLocaleData.dialCodeFor('  '));
    Assert.isTrue(IdpLocaleData.isKnownCountry('BR'));
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
    Assert.areEqual('.', IdpLocaleData.decimalSeparatorFor('en-US'));
    Assert.areEqual(
      ',',
      IdpLocaleData.decimalSeparatorFor('en_ZA'),
      'underscore and hyphen forms are the same tag'
    );
    Assert.areEqual(
      ',',
      IdpLocaleData.decimalSeparatorFor('de'),
      'no country subtag falls through to the language'
    );
    Assert.areEqual(
      '.',
      IdpLocaleData.decimalSeparatorFor('de-CH'),
      'Swiss German prints dot decimals; the country decides'
    );
    Assert.isNull(IdpLocaleData.decimalSeparatorFor('zz-ZZ'));
    Assert.isNull(IdpLocaleData.decimalSeparatorFor(null));
  }

  @IsTest
  static void reportsWhetherALocaleIsSeeded() {
    Assert.isTrue(IdpLocaleData.isKnownLocale('pt-BR'));
    Assert.isTrue(IdpLocaleData.isKnownLocale('de'), 'language alone is enough');
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
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('März', 'de'));
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('Marz', 'de-DE'),
      'accents are folded away, so an OCR that lost the umlaut still reads'
    );
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('Mrz', 'de'),
      'an abbreviation that is not a prefix has to be listed, and is'
    );
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('Mrz.', 'de'),
      'a trailing abbreviation dot is dropped'
    );
    Assert.areEqual(1, IdpLocaleData.monthNumberFor('januari', 'nl'));
    Assert.areEqual(9, IdpLocaleData.monthNumberFor('września', 'pl'));
    Assert.areEqual(1, IdpLocaleData.monthNumberFor('Ιανουαρίου', 'el'));
    Assert.areEqual(5, IdpLocaleData.monthNumberFor('мая', 'ru'));
  }

  @IsTest
  static void resolvesPortugueseThreeLetterPrefixesAndRefusesTwo() {
    // The collision the impact assessment flagged: março and maio share
    // two letters, not three.
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('março', 'pt'));
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('mar', 'pt'));
    Assert.areEqual(5, IdpLocaleData.monthNumberFor('maio', 'pt-BR'));
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
    Assert.areEqual(
      6,
      IdpLocaleData.monthNumberFor('červen', 'cs'),
      'červen is a whole name and a prefix of červenec; the whole name wins'
    );
    Assert.areEqual(7, IdpLocaleData.monthNumberFor('července', 'cs'));
  }

  @IsTest
  static void fallsBackToEnglishForUnknownOrMonthlessLanguages() {
    Assert.areEqual(
      3,
      IdpLocaleData.monthNumberFor('March', 'xx'),
      'an unseeded language still reads English'
    );
    Assert.areEqual(3, IdpLocaleData.monthNumberFor('March', null));
    Assert.isTrue(
      IdpLocaleData.isKnownLocale('vi'),
      'Vietnamese is seeded for its decimal separator'
    );
    Assert.isFalse(
      IdpLocaleData.readsMonthNames('vi'),
      'but it names its months numerically, so it declares none'
    );
    Assert.isTrue(IdpLocaleData.readsMonthNames('de'));
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
        code + ' has Month Names that did not compile — it needs exactly 12 entries'
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
        record.Decimal_Separator__c == ',' || record.Decimal_Separator__c == '.',
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
      IdpLocaleData.monthNumberFor('March', 'de'),
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
