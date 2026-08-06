/**
 * Unit tests for the built-in value types — no DML, and no queries beyond
 * the limit-free custom metadata IdpLocaleData reads for dial codes,
 * decimal separators and month names. The Number matrix includes the
 * exact inputs v1's regex stripper silently corrupted ("ZAR 100,00" →
 * 10000).
 */
@IsTest
private class IdpValueTypesTest {
  private static IdpValueTypes.Config cfg(String kind) {
    IdpValueTypes.Config config = new IdpValueTypes.Config();
    config.kind = kind;
    config.name = 'test:' + kind;
    return config;
  }

  private static IdpValueTypes.ParseResult parse(
    String kind,
    Object raw,
    IdpValueTypes.Config config
  ) {
    return IdpTypeRegistry.builtIn(kind).parse(raw, config);
  }

  // ─────────────────────────── Number ─────────────────────────────

  @IsTest
  static void parsesBothSeparatorConventionsDeterministically() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_NUMBER);
    // The v1 corruption case: ZAR 100,00 must be 100, not 10000.
    IdpValueTypes.ParseResult za = parse(
      IdpValueTypes.KIND_NUMBER,
      'ZAR 100,00',
      config
    );
    Assert.areEqual(100.00, za.value);
    Assert.areEqual(IdpResult.Grade.EXACT, za.grade);

    IdpValueTypes.ParseResult mixed = parse(
      IdpValueTypes.KIND_NUMBER,
      'R 1,234.56',
      config
    );
    Assert.areEqual(1234.56, mixed.value);
    Assert.areEqual(IdpResult.Grade.EXACT, mixed.grade);

    IdpValueTypes.ParseResult european = parse(
      IdpValueTypes.KIND_NUMBER,
      '1.234,56',
      config
    );
    Assert.areEqual(1234.56, european.value, 'last separator is decimal');
    Assert.areEqual(IdpResult.Grade.EXACT, european.grade);

    IdpValueTypes.ParseResult spaced = parse(
      IdpValueTypes.KIND_NUMBER,
      'R 1 234,56',
      config
    );
    Assert.areEqual(1234.56, spaced.value);
  }

  @IsTest
  static void gradesNegativesAndSuffixes() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_NUMBER);
    Assert.areEqual(
      -1234.56,
      parse(IdpValueTypes.KIND_NUMBER, '(1,234.56)', config).value,
      'parenthesised negative'
    );
    Assert.areEqual(
      -1234.56,
      parse(IdpValueTypes.KIND_NUMBER, '1,234.56-', config).value,
      'trailing minus'
    );
    IdpValueTypes.ParseResult debit = parse(
      IdpValueTypes.KIND_NUMBER,
      '1 234,56 DR',
      config
    );
    Assert.areEqual(-1234.56, debit.value);
    Assert.areEqual(
      IdpResult.Grade.INFERRED,
      debit.grade,
      'DR sign reading is a heuristic'
    );
    IdpValueTypes.ParseResult credit = parse(
      IdpValueTypes.KIND_NUMBER,
      '1 234,56 CR',
      config
    );
    Assert.areEqual(1234.56, credit.value);
    Assert.areEqual(IdpResult.Grade.INFERRED, credit.grade);
  }

  @IsTest
  static void gradesSingleSeparatorByLocale() {
    IdpValueTypes.Config noLocale = cfg(IdpValueTypes.KIND_NUMBER);
    IdpValueTypes.ParseResult heuristic = parse(
      IdpValueTypes.KIND_NUMBER,
      '1,234',
      noLocale
    );
    Assert.areEqual(1234, heuristic.value, 'three digits read as thousands');
    Assert.areEqual(
      IdpResult.Grade.INFERRED,
      heuristic.grade,
      '1,234 is ambiguous without a locale'
    );

    IdpValueTypes.Config us = cfg(IdpValueTypes.KIND_NUMBER);
    us.locale = 'en-US';
    IdpValueTypes.ParseResult grouped = parse(
      IdpValueTypes.KIND_NUMBER,
      '1,234',
      us
    );
    Assert.areEqual(1234, grouped.value);
    Assert.areEqual(IdpResult.Grade.EXACT, grouped.grade);

    IdpValueTypes.Config za = cfg(IdpValueTypes.KIND_NUMBER);
    za.locale = 'en-ZA';
    IdpValueTypes.ParseResult decimalComma = parse(
      IdpValueTypes.KIND_NUMBER,
      '100,00',
      za
    );
    Assert.areEqual(100.00, decimalComma.value);
    Assert.areEqual(IdpResult.Grade.EXACT, decimalComma.grade);
  }

  @IsTest
  static void numberEdges() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_NUMBER);
    Assert.areEqual(
      12.34,
      parse(IdpValueTypes.KIND_NUMBER, '12,34', config).value,
      'two trailing digits cannot be a thousands group'
    );
    Assert.areEqual(
      1234567,
      parse(IdpValueTypes.KIND_NUMBER, '1,234,567', config).value
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_NUMBER, 'about right', config).grade
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_NUMBER, '1,2,3.4.5', config).grade,
      'several decimal separators cannot be read'
    );
    // Typed JSON numbers pass through untouched.
    Assert.areEqual(
      IdpResult.Grade.EXACT,
      parse(IdpValueTypes.KIND_NUMBER, 42.5, config).grade
    );

    IdpValueTypes.Config thousands = cfg(IdpValueTypes.KIND_NUMBER);
    thousands.scaleFactor = 1000;
    Assert.areEqual(
      12500,
      parse(IdpValueTypes.KIND_NUMBER, '12.5', thousands).value,
      'scale factor for statements printed in thousands'
    );
  }

  @IsTest
  static void comparesNumbersWithTolerance() {
    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_NUMBER);
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_NUMBER);
    config.compareTolerance = 0.01;
    Assert.areEqual(
      IdpResult.CompareOutcome.MATCH,
      type.compare('R 1,234.50', 1234.5, config),
      'formatting differences are not mismatches'
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.NEAR,
      type.compare('1234.56', 1234.55, config),
      'inside tolerance is Near, for a human to glance at'
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.MISMATCH,
      type.compare('1234.56', 1240, config)
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.MISMATCH,
      type.compare('1234.56', null, config),
      'a blank stored value cannot confirm the document'
    );
  }

  @IsTest
  static void detectsStatedCurrenciesAndRefusesConflicts() {
    IdpValueTypes.Config open = cfg(IdpValueTypes.KIND_NUMBER);
    Assert.areEqual(
      'ZAR',
      parse(IdpValueTypes.KIND_NUMBER, 'ZAR 100,00', open).currencyCode,
      'an ISO code next to the amount is captured, not discarded'
    );
    Assert.areEqual(
      'ZAR',
      parse(IdpValueTypes.KIND_NUMBER, 'R 8 420 000.00', open).currencyCode
    );
    Assert.areEqual(
      'EUR',
      parse(IdpValueTypes.KIND_NUMBER, '€1.234,56', open).currencyCode
    );
    Assert.areEqual(
      'BRL',
      parse(IdpValueTypes.KIND_NUMBER, 'R$ 100.00', open).currencyCode,
      'longest symbol wins: R$ is the real, not the rand'
    );
    Assert.isNull(
      parse(IdpValueTypes.KIND_NUMBER, '$ 100.00', open).currencyCode,
      '$ is ambiguous across currencies — never guessed'
    );
    Assert.isNull(
      parse(IdpValueTypes.KIND_NUMBER, '1234.56', open).currencyCode,
      'a plain quantity has no currency'
    );

    IdpValueTypes.Config zar = cfg(IdpValueTypes.KIND_NUMBER);
    zar.currencyCode = 'ZAR';
    Assert.areEqual(
      'ZAR',
      parse(IdpValueTypes.KIND_NUMBER, '$ 100.00', zar).currencyCode,
      'the value type resolves an ambiguous symbol'
    );
    Assert.areEqual(
      'ZAR',
      parse(IdpValueTypes.KIND_NUMBER, '100.00', zar).currencyCode,
      'an unstated currency is assumed from the value type'
    );
    Assert.areEqual(
      'ZAR',
      parse(IdpValueTypes.KIND_NUMBER, 42.5, zar).currencyCode,
      'typed JSON numbers carry the implied currency too'
    );

    IdpValueTypes.ParseResult clash = parse(
      IdpValueTypes.KIND_NUMBER,
      'EUR 100.00',
      zar
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      clash.grade,
      'a stated currency that disagrees fails loudly — 100 EUR is not 100 ZAR'
    );
    Assert.isTrue(clash.note.contains('EUR') && clash.note.contains('ZAR'));

    Assert.isTrue(IdpValueTypes.isKnownCurrency('zar'));
    Assert.isFalse(IdpValueTypes.isKnownCurrency('XYZ'));
    Assert.isNull(
      IdpValueTypes.detectCurrency('GBR 100'),
      'a random 3-letter word next to a number is not a currency, and GBR must not read as rand'
    );
  }

  // ──────────────────────────── Date ──────────────────────────────

  @IsTest
  static void parsesDatesThroughOrderedPatterns() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATE);
    config.formats = new List<String>{
      'dd MMMM yyyy',
      'dd MMM yyyy',
      'dd/MM/yyyy',
      'yyyy-MM-dd'
    };
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15 March 2024', config).value
    );
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15 Mar 2024', config).value
    );
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15/03/2024', config).value
    );
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '2024-03-15', config).value,
      'one rule survives a scanner changing its output format'
    );
    // Default with no Formats is strict ISO.
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '2024-03-15', cfg(IdpValueTypes.KIND_DATE))
        .value
    );
  }

  @IsTest
  static void reportsAmbiguousAndImpossibleDates() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATE);
    config.formats = new List<String>{ 'dd/MM/yyyy', 'MM/dd/yyyy' };
    IdpValueTypes.ParseResult ambiguous = parse(
      IdpValueTypes.KIND_DATE,
      '03/04/2024',
      config
    );
    Assert.areEqual(
      IdpResult.Grade.AMBIGUOUS,
      ambiguous.grade,
      '03/04/2024 is genuinely undecidable — reported, never guessed'
    );
    Assert.isTrue(ambiguous.note.contains('2024-04-03'));
    Assert.isTrue(ambiguous.note.contains('2024-03-04'));

    // Same input, but only one pattern parses it: 13 cannot be a month.
    Assert.areEqual(
      Date.newInstance(2024, 4, 13),
      parse(IdpValueTypes.KIND_DATE, '13/04/2024', config).value
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_DATE, '31/02/2024', config).grade,
      'component range checks reject impossible dates'
    );
  }

  @IsTest
  static void handlesTwoDigitYearsAndRendering() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATE);
    config.formats = new List<String>{ 'dd/MM/yy' };
    Assert.areEqual(
      Date.newInstance(2024, 6, 5),
      parse(IdpValueTypes.KIND_DATE, '05/06/24', config).value,
      'default pivot 1950 puts 24 in 2024'
    );
    Assert.areEqual(
      Date.newInstance(1951, 6, 5),
      parse(IdpValueTypes.KIND_DATE, '05/06/51', config).value
    );

    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_DATE);
    config.outputFormat = 'dd MMM yyyy';
    Assert.areEqual(
      '15 Mar 2024',
      type.render(Date.newInstance(2024, 3, 15), config)
    );
  }

  @IsTest
  static void readsMonthNamesInTheDocumentsLanguage() {
    IdpValueTypes.Config de = cfg(IdpValueTypes.KIND_DATE);
    de.formats = new List<String>{ 'd. MMMM yyyy', 'dd MMM yyyy' };
    de.locale = 'de-DE';
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15. März 2024', de).value,
      'the language comes from the value type, never from the running user'
    );
    Assert.areEqual(
      Date.newInstance(2024, 12, 1),
      parse(IdpValueTypes.KIND_DATE, '01 Dez 2024', de).value
    );

    IdpValueTypes.Config pt = cfg(IdpValueTypes.KIND_DATE);
    pt.formats = new List<String>{ 'dd MMMM yyyy' };
    pt.locale = 'pt-BR';
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15 março 2024', pt).value
    );
    Assert.areEqual(
      Date.newInstance(2024, 5, 15),
      parse(IdpValueTypes.KIND_DATE, '15 maio 2024', pt).value,
      'março and maio are the pair a two-letter prefix would have confused'
    );

    IdpValueTypes.Config es = cfg(IdpValueTypes.KIND_DATE);
    es.formats = new List<String>{ 'd \'de\' MMMM \'de\' yyyy' };
    es.locale = 'es-ES';
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15 de marzo de 2024', es).value,
      'quoted literals keep the "de" of a Romance long date out of the tokens'
    );

    IdpValueTypes.Config af = cfg(IdpValueTypes.KIND_DATE);
    af.formats = new List<String>{ 'dd MMMM yyyy' };
    af.locale = 'af-ZA';
    Assert.areEqual(
      Date.newInstance(2024, 3, 15),
      parse(IdpValueTypes.KIND_DATE, '15 Maart 2024', af).value
    );
  }

  @IsTest
  static void failsRatherThanGuessAMonthTheLanguageCannotDecide() {
    IdpValueTypes.Config fr = cfg(IdpValueTypes.KIND_DATE);
    fr.formats = new List<String>{ 'dd MMM yyyy' };
    fr.locale = 'fr-FR';
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_DATE, '15 jui 2024', fr).grade,
      'juin and juillet both start jui — a wrong month is worse than no month'
    );
    Assert.areEqual(
      Date.newInstance(2024, 6, 15),
      parse(IdpValueTypes.KIND_DATE, '15 juin 2024', fr).value
    );

    IdpValueTypes.Config de = cfg(IdpValueTypes.KIND_DATE);
    de.formats = new List<String>{ 'dd MMMM yyyy' };
    de.locale = 'de';
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_DATE, '15 March 2024', de).grade,
      'a German value type does not quietly accept English months'
    );
  }

  @IsTest
  static void rendersMonthNamesInEnglishWhateverTheLocale() {
    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_DATE);
    IdpValueTypes.Config de = cfg(IdpValueTypes.KIND_DATE);
    de.locale = 'de-DE';
    de.outputFormat = 'dd MMMM yyyy';
    Assert.areEqual(
      '15 March 2024',
      type.render(Date.newInstance(2024, 3, 15), de),
      'reading is localised, writing is not — Output Format is org-side text'
    );
    de.outputFormat = 'd \'de\' MMMM \'de\' yyyy';
    Assert.areEqual(
      '15 de March de 2024',
      type.render(Date.newInstance(2024, 3, 15), de),
      'quoted literals render literally too'
    );
  }

  @IsTest
  static void rejectsAnUnterminatedQuoteInsteadOfMisreadingIt() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATE);
    config.formats = new List<String>{ 'd \'de MMMM yyyy' };
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_DATE, '15 de March 2024', config).grade
    );
  }

  @IsTest
  static void comparesDatesWithDayTolerance() {
    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_DATE);
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATE);
    config.formats = new List<String>{ 'dd/MM/yyyy' };
    config.compareTolerance = 2;
    Assert.areEqual(
      IdpResult.CompareOutcome.MATCH,
      type.compare('15/03/2024', Date.newInstance(2024, 3, 15), config)
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.NEAR,
      type.compare('15/03/2024', Date.newInstance(2024, 3, 17), config)
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.MISMATCH,
      type.compare('15/03/2024', Date.newInstance(2024, 3, 20), config)
    );
  }

  // ────────────────────────── Datetime ────────────────────────────

  @IsTest
  static void readsNaiveTimestampsInConfiguredTimezone() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_DATETIME);
    IdpValueTypes.ParseResult withOffset = parse(
      IdpValueTypes.KIND_DATETIME,
      '2024-03-15T09:00:00+02:00',
      config
    );
    Assert.areEqual(IdpResult.Grade.EXACT, withOffset.grade);
    Assert.areEqual(
      Datetime.newInstanceGmt(2024, 3, 15, 7, 0, 0),
      withOffset.value
    );

    IdpValueTypes.ParseResult naiveGmt = parse(
      IdpValueTypes.KIND_DATETIME,
      '2024-03-15 09:00',
      config
    );
    Assert.areEqual(
      IdpResult.Grade.INFERRED,
      naiveGmt.grade,
      'naive timestamp without timezone reads as GMT, flagged'
    );

    config.timezone = 'Africa/Johannesburg';
    IdpValueTypes.ParseResult naiveZa = parse(
      IdpValueTypes.KIND_DATETIME,
      '2024-03-15 09:00',
      config
    );
    Assert.areEqual(IdpResult.Grade.EXACT, naiveZa.grade);
    Assert.areEqual(
      Datetime.newInstanceGmt(2024, 3, 15, 7, 0, 0),
      naiveZa.value,
      'Johannesburg is GMT+2'
    );
  }

  // ─────────────────────────── Phone ──────────────────────────────

  @IsTest
  static void canonicalizesPhonesToE164() {
    IdpValueTypes.Config za = cfg(IdpValueTypes.KIND_PHONE);
    za.region = 'ZA';
    Assert.areEqual(
      '+27821234567',
      parse(IdpValueTypes.KIND_PHONE, '+27 82 123 4567', za).value
    );
    Assert.areEqual(
      '+27821234567',
      parse(IdpValueTypes.KIND_PHONE, '0027821234567', za).value
    );
    IdpValueTypes.ParseResult national = parse(
      IdpValueTypes.KIND_PHONE,
      '(082) 123-4567',
      za
    );
    Assert.areEqual('+27821234567', national.value);
    Assert.areEqual(IdpResult.Grade.EXACT, national.grade);

    IdpValueTypes.ParseResult noRegion = parse(
      IdpValueTypes.KIND_PHONE,
      '082 123 4567',
      cfg(IdpValueTypes.KIND_PHONE)
    );
    Assert.areEqual('0821234567', noRegion.value);
    Assert.areEqual(IdpResult.Grade.INFERRED, noRegion.grade);
  }

  @IsTest
  static void canonicalizesPhonesForAnyRegionInMetadata() {
    IdpValueTypes.Config se = cfg(IdpValueTypes.KIND_PHONE);
    se.region = 'SE';
    Assert.areEqual(
      '+46701234567',
      parse(IdpValueTypes.KIND_PHONE, '070 123 45 67', se).value,
      'Sweden was never in the hardcoded dial-code set; the record is enough'
    );

    IdpValueTypes.Config unseeded = cfg(IdpValueTypes.KIND_PHONE);
    unseeded.region = 'XX';
    IdpValueTypes.ParseResult unknown = parse(
      IdpValueTypes.KIND_PHONE,
      '070 123 45 67',
      unseeded
    );
    Assert.areEqual('0701234567', unknown.value);
    Assert.areEqual(
      IdpResult.Grade.INFERRED,
      unknown.grade,
      'an unseeded region degrades to digits, exactly like no region at all'
    );
  }

  @IsTest
  static void readsDecimalSeparatorsForAnyLocaleInMetadata() {
    IdpValueTypes.Config de = cfg(IdpValueTypes.KIND_NUMBER);
    de.locale = 'de-DE';
    IdpValueTypes.ParseResult german = parse(
      IdpValueTypes.KIND_NUMBER,
      '1.234',
      de
    );
    Assert.areEqual(1234, german.value, 'German dot groups thousands');
    Assert.areEqual(IdpResult.Grade.EXACT, german.grade);

    IdpValueTypes.Config ch = cfg(IdpValueTypes.KIND_NUMBER);
    ch.locale = 'de-CH';
    IdpValueTypes.ParseResult swiss = parse(
      IdpValueTypes.KIND_NUMBER,
      '1.234',
      ch
    );
    Assert.areEqual(
      1.234,
      swiss.value,
      'same language, other country: Switzerland reads the dot as decimal'
    );
    Assert.areEqual(IdpResult.Grade.EXACT, swiss.grade);
  }

  @IsTest
  static void comparesPhonesAcrossFormats() {
    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_PHONE);
    IdpValueTypes.Config za = cfg(IdpValueTypes.KIND_PHONE);
    za.region = 'ZA';
    Assert.areEqual(
      IdpResult.CompareOutcome.MATCH,
      type.compare('+27 82 123 4567', '082 123 4567', za),
      'the v1 false mismatch: both sides canonicalize before comparing'
    );

    IdpValueTypes.Config noRegion = cfg(IdpValueTypes.KIND_PHONE);
    Assert.areEqual(
      IdpResult.CompareOutcome.NEAR,
      type.compare('+27821234567', '0821234567', noRegion),
      'same subscriber, unprovable country code — Near, not Mismatch'
    );
    Assert.areEqual(
      IdpResult.CompareOutcome.MISMATCH,
      type.compare('+27821234567', '0839999999', noRegion)
    );
  }

  @IsTest
  static void rendersPhoneFormats() {
    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_PHONE);
    IdpValueTypes.Config za = cfg(IdpValueTypes.KIND_PHONE);
    za.region = 'ZA';
    Assert.areEqual('+27821234567', type.render('+27821234567', za));
    za.outputFormat = 'national';
    Assert.areEqual('0821234567', type.render('+27821234567', za));
    za.outputFormat = 'digits';
    Assert.areEqual('27821234567', type.render('+27821234567', za));
  }

  // ────────────────────────── ValueMap ────────────────────────────

  @IsTest
  static void mapsDocumentTextToStoredValues() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_VALUE_MAP);
    config.mapEntries = new List<IdpValueTypes.MapEntry>{
      entry('Pty Ltd', 'Private Company', 'Normalized'),
      entry('(PTY) LTD', 'Private Company', 'Normalized'),
      entry('Proprietary\\s+Limited', 'Private Company', 'Regex'),
      entry('CC', 'Close Corporation', 'Exact')
    };
    Assert.areEqual(
      'Private Company',
      parse(IdpValueTypes.KIND_VALUE_MAP, '  pty ltd ', config).value,
      'normalized matching survives OCR casing and spacing'
    );
    Assert.areEqual(
      'Private Company',
      parse(IdpValueTypes.KIND_VALUE_MAP, 'Proprietary  Limited', config).value
    );
    Assert.areEqual(
      'Close Corporation',
      parse(IdpValueTypes.KIND_VALUE_MAP, 'CC', config).value
    );
    IdpValueTypes.ParseResult unmapped = parse(
      IdpValueTypes.KIND_VALUE_MAP,
      'Sole Prop',
      config
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      unmapped.grade,
      'unmapped text fails loudly instead of polluting a controlled field'
    );

    IValueType type = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_VALUE_MAP);
    Assert.areEqual(
      IdpResult.CompareOutcome.MATCH,
      type.compare('Pty Ltd', 'Private Company', config),
      'compliance maps the document side before comparing'
    );
  }

  private static IdpValueTypes.MapEntry entry(
    String fromText,
    String toValue,
    String style
  ) {
    IdpValueTypes.MapEntry mapEntry = new IdpValueTypes.MapEntry();
    mapEntry.fromText = fromText;
    mapEntry.toValue = toValue;
    mapEntry.matchStyle = style;
    return mapEntry;
  }

  // ─────────────────────────── Regex ──────────────────────────────

  @IsTest
  static void extractsWithRegex() {
    IdpValueTypes.Config config = cfg(IdpValueTypes.KIND_REGEX);
    config.formatsRaw = 'Estate No\\.?\\s*([0-9/]+)';
    Assert.areEqual(
      '1234/2024',
      parse(IdpValueTypes.KIND_REGEX, 'Estate No. 1234/2024', config).value
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(IdpValueTypes.KIND_REGEX, 'no reference here', config).grade
    );
  }

  // ──────────────────── Boolean, Text, coercion ───────────────────

  @IsTest
  static void parsesBooleansAndText() {
    Assert.areEqual(
      true,
      parse(IdpValueTypes.KIND_BOOLEAN, 'Yes', cfg(IdpValueTypes.KIND_BOOLEAN))
        .value
    );
    Assert.areEqual(
      false,
      parse(IdpValueTypes.KIND_BOOLEAN, 'N', cfg(IdpValueTypes.KIND_BOOLEAN))
        .value
    );
    Assert.areEqual(
      IdpResult.Grade.FAILED,
      parse(
          IdpValueTypes.KIND_BOOLEAN,
          'maybe',
          cfg(IdpValueTypes.KIND_BOOLEAN)
        )
        .grade
    );

    IValueType text = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_TEXT);
    Assert.areEqual(
      IdpResult.CompareOutcome.MATCH,
      text.compare('  JANE   DOE ', 'Jane Doe', cfg(IdpValueTypes.KIND_TEXT)),
      'text comparison forgives whitespace and case, not content'
    );
  }

  @IsTest
  static void coercesCanonicalValuesIntoFields() {
    IValueType numberType = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_NUMBER);
    IdpValueTypes.Config numberCfg = cfg(IdpValueTypes.KIND_NUMBER);
    Schema.DescribeFieldResult employees = Account.NumberOfEmployees.getDescribe();
    Assert.areEqual(
      42,
      IdpValueTypes.coerceForField(employees, 42.0, numberType, numberCfg)
    );
    Schema.DescribeFieldResult revenue = Account.AnnualRevenue.getDescribe();
    Assert.areEqual(
      1234.56,
      IdpValueTypes.coerceForField(revenue, 1234.56, numberType, numberCfg)
    );

    IValueType dateType = IdpTypeRegistry.builtIn(IdpValueTypes.KIND_DATE);
    IdpValueTypes.Config dateCfg = cfg(IdpValueTypes.KIND_DATE);
    dateCfg.outputFormat = 'dd/MM/yyyy';
    Schema.DescribeFieldResult description = Case.Description.getDescribe();
    Assert.areEqual(
      '15/03/2024',
      IdpValueTypes.coerceForField(
        description,
        Date.newInstance(2024, 3, 15),
        dateType,
        dateCfg
      ),
      'text targets receive the rendered form, per Output Format'
    );

    try {
      IdpValueTypes.coerceForField(revenue, 'not a number', numberType, numberCfg);
      Assert.fail('expected a TypeException');
    } catch (IdpValueTypes.TypeException e) {
      Assert.isTrue(e.getMessage().contains('AnnualRevenue'));
    }
  }

  @IsTest
  static void autoConfigMatchesFieldTypes() {
    Assert.areEqual(
      IdpValueTypes.KIND_NUMBER,
      IdpTypeRegistry.autoConfig(Account.AnnualRevenue.getDescribe()).kind
    );
    Assert.areEqual(
      IdpValueTypes.KIND_DATE,
      IdpTypeRegistry.autoConfig(Contact.Birthdate.getDescribe()).kind
    );
    Assert.areEqual(
      IdpValueTypes.KIND_PHONE,
      IdpTypeRegistry.autoConfig(Account.Phone.getDescribe()).kind
    );
    Assert.areEqual(
      IdpValueTypes.KIND_TEXT,
      IdpTypeRegistry.autoConfig(Case.Description.getDescribe()).kind
    );
  }

  @IsTest
  static void resolvesCustomHandlersWithClearErrors() {
    IdpValueTypes.Config custom = cfg(IdpValueTypes.KIND_CUSTOM);
    custom.handlerClass = 'NoSuchClassAnywhere';
    try {
      IdpTypeRegistry.resolve(custom);
      Assert.fail('expected a TypeException');
    } catch (IdpValueTypes.TypeException e) {
      Assert.isTrue(e.getMessage().contains('NoSuchClassAnywhere'));
    }
    // A built-in registered class that is not an IValueType.
    custom.handlerClass = 'IdpResult';
    try {
      IdpTypeRegistry.resolve(custom);
      Assert.fail('expected a TypeException');
    } catch (IdpValueTypes.TypeException e) {
      Assert.isTrue(e.getMessage().contains('does not implement'));
    }
  }
}
