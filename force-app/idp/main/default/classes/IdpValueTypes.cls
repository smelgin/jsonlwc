/**
 * The built-in value types and the shared shapes every IValueType speaks:
 * Config (one IDP_Value_Type__mdt record, parsed), ParseResult (value +
 * Grade + note) and the field-coercion helper that fits a canonical value
 * into a target field.
 *
 * Grading philosophy: a deterministic parse is EXACT, a heuristic one is
 * INFERRED with a note saying which heuristic, an undecidable one is
 * AMBIGUOUS, and nothing is ever guessed silently — the v1 behaviour of
 * regex-stripping "ZAR 100,00" into 10000 has no successor here.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpValueTypes {
  /** Raised when a value cannot be fitted to its target field, or when a
   *  value type's own configuration is unusable. */
  public class TypeException extends Exception {
  }

  // Kinds (IDP_Value_Type__mdt.Kind__c)
  public static final String KIND_TEXT = 'Text';
  public static final String KIND_NUMBER = 'Number';
  public static final String KIND_DATE = 'Date';
  public static final String KIND_DATETIME = 'Datetime';
  public static final String KIND_BOOLEAN = 'Boolean';
  public static final String KIND_PHONE = 'Phone';
  public static final String KIND_VALUE_MAP = 'ValueMap';
  public static final String KIND_REGEX = 'Regex';
  public static final String KIND_CUSTOM = 'Custom';

  // Compiled once per transaction rather than per parsed value: a batch over
  // thousands of rows would otherwise pay Pattern.compile thousands of times.

  /** Currency code written after the amount, as in "100,00 ZAR". */
  private static final Pattern TRAILING_LETTERS = Pattern.compile(
    '([A-Za-z]+)\\s*$'
  );

  /** A standalone three-letter token anywhere in the amount. */
  private static final Pattern ISO_CODE_TOKEN = Pattern.compile(
    '(?<![A-Za-z])([A-Za-z]{3})(?![A-Za-z])'
  );

  /** Timestamp that already carries a UTC offset or Z. */
  private static final Pattern OFFSET_SUFFIX = Pattern.compile(
    '.*([+-]\\d{2}:?\\d{2}|Z)$'
  );

  /** Timestamp with no zone at all, read in the configured timezone. */
  private static final Pattern NAIVE_TIMESTAMP = Pattern.compile(
    '^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?$'
  );

  /** One IDP_Value_Type__mdt record in plain Apex. */
  public class Config {
    /** DeveloperName of the record, quoted in messages. */
    public String name;
    /** Which built-in kind, or Custom, implements this type. */
    public String kind = KIND_TEXT;
    /** Apex class implementing a Custom kind. */
    public String handlerClass;
    /** Locale whose conventions the documents are written in. */
    public String locale;
    /** Number kind: ISO 4217 code the documents are denominated in. A
     *  stated currency that disagrees fails the parse; an unstated one is
     *  assumed to be this. Blank accepts whatever the document states. */
    public String currencyCode;
    /** Accepted input formats, Formats__c split on "|". */
    public List<String> formats = new List<String>();
    /** Formats__c unsplit, which the Regex kind uses as its pattern. */
    public String formatsRaw;
    /** Format canonical values are rendered back out in. */
    public String outputFormat;
    /** ISO country whose conventions apply, such as a phone dial code. */
    public String region;
    /** Multiplier applied to a parsed number, for documents in thousands. */
    public Decimal scaleFactor;
    /** Difference still counted as a NEAR match rather than a mismatch. */
    public Decimal compareTolerance;
    /** Century boundary for two-digit years. */
    public Integer pivotYear;
    /** Timezone a timestamp without an offset is read in. */
    public String timezone;
    /** Free-form options passed through to a Custom implementation. */
    public String customOptions;
    /** Value translations, for the ValueMap kind. */
    public List<MapEntry> mapEntries = new List<MapEntry>();
  }

  /** One translation from document text to a stored value. */
  public class MapEntry {
    /** Text as the document writes it. */
    public String fromText;
    /** Value written to the record instead. */
    public String toValue;
    /** How fromText is matched: Exact or Normalized. */
    public String matchStyle = 'Normalized';
  }

  /** What a value type made of one document value. */
  public class ParseResult {
    /** Canonical typed value; null when the parse produced nothing. */
    public Object value;
    /** How sure the type is of the reading. */
    public IdpResult.Grade grade;
    /** Which heuristic was applied, or why the parse failed. */
    public String note;
    /** Number kind: ISO 4217 code the document stated (or the value type
     *  implied). Null when neither says — a plain quantity. */
    public String currencyCode;
  }

  /**
   * Reports a deterministic parse.
   *
   * @param value Canonical value read from the document.
   * @return Parse result graded EXACT.
   */
  public static ParseResult exact(Object value) {
    return result(value, IdpResult.Grade.EXACT, null);
  }

  /**
   * Reports a heuristic parse, naming the heuristic.
   *
   * @param value Canonical value read from the document.
   * @param note Which heuristic settled the reading.
   * @return Parse result graded INFERRED.
   */
  public static ParseResult inferred(Object value, String note) {
    return result(value, IdpResult.Grade.INFERRED, note);
  }

  /**
   * Reports a reading with several equally defensible answers.
   *
   * @param note What made the value undecidable.
   * @return Parse result graded AMBIGUOUS, carrying no value.
   */
  public static ParseResult ambiguous(String note) {
    return result(null, IdpResult.Grade.AMBIGUOUS, note);
  }

  /**
   * Reports that the text yielded no reading at all.
   *
   * @param note Why the parse failed.
   * @return Parse result graded FAILED, carrying no value.
   */
  public static ParseResult failed(String note) {
    return result(null, IdpResult.Grade.FAILED, note);
  }

  /**
   * Assembles a parse result.
   *
   * @param value Canonical value, or null.
   * @param grade Grade earned by the parse.
   * @param note Explanation carried alongside the grade.
   * @return The assembled result.
   */
  private static ParseResult result(
    Object value,
    IdpResult.Grade grade,
    String note
  ) {
    ParseResult parsed = new ParseResult();
    parsed.value = value;
    parsed.grade = grade;
    parsed.note = note;
    return parsed;
  }

  /**
   * Reduces text to its comparison form: trimmed, collapsed, lowercased.
   *
   * @param value Text to normalize.
   * @return Comparison form, empty string when nothing was supplied.
   */
  public static String normalize(String value) {
    return value == null
      ? ''
      : value.trim().replaceAll('\\s+', ' ').toLowerCase();
  }

  /**
   * Compares both sides through the type's own canonical form.
   *
   * The two-state compare shared by the types that have no tolerance: a
   * blank stored field cannot confirm the document. Number, Date, Datetime
   * and Phone keep their own tolerance-aware compares.
   *
   * @param type Value type supplying the canonical form.
   * @param extracted Value read from the document.
   * @param stored Value read from the target field.
   * @param cfg Value type configuration.
   * @return MATCH or MISMATCH; this compare never reports NEAR.
   */
  private static IdpResult.CompareOutcome compareCanonical(
    IValueType type,
    Object extracted,
    Object stored,
    Config cfg
  ) {
    if (stored == null) {
      return IdpResult.CompareOutcome.MISMATCH;
    }
    return type.canonical(extracted, cfg) == type.canonical(stored, cfg)
      ? IdpResult.CompareOutcome.MATCH
      : IdpResult.CompareOutcome.MISMATCH;
  }

  /**
   * Fits a canonical value into the Apex type the target field expects.
   *
   * Types already return proper Apex values (Decimal, Date, ...), so this
   * is a narrow adapter rather than a parser. Text-family fields take the
   * type's rendered output instead.
   *
   * @param field Describe of the field being written.
   * @param value Canonical value produced by the type.
   * @param type Value type that produced it.
   * @param cfg Value type configuration, supplying the output format.
   * @return Value in the Apex type the field accepts, or null.
   * @throws TypeException When the value cannot be the kind of value that
   *         field holds, such as non-numeric text on a Currency field.
   */
  public static Object coerceForField(
    Schema.DescribeFieldResult field,
    Object value,
    IValueType type,
    Config cfg
  ) {
    if (value == null) {
      return null;
    }
    switch on field.getType() {
      when INTEGER, LONG {
        return strictDecimal(value, field).intValue();
      }
      when DOUBLE, CURRENCY, PERCENT {
        return strictDecimal(value, field);
      }
      when BOOLEAN {
        if (value instanceof Boolean) {
          return value;
        }
        throw new TypeException(
          typeMismatch(value, field, 'a true/false value')
        );
      }
      when DATE {
        if (value instanceof Date) {
          return value;
        }
        if (value instanceof Datetime) {
          return ((Datetime) value).dateGmt();
        }
        throw new TypeException(typeMismatch(value, field, 'a date'));
      }
      when DATETIME {
        if (value instanceof Datetime) {
          return value;
        }
        throw new TypeException(typeMismatch(value, field, 'a date/time'));
      }
      when else {
        // Text family (STRING, TEXTAREA, EMAIL, PHONE, URL, PICKLIST, ...):
        // the type renders its canonical value per Output Format.
        return type.render(value, cfg);
      }
    }
  }

  /**
   * Converts a value to Decimal or refuses the write.
   *
   * @param value Canonical value produced by the type.
   * @param field Describe of the numeric field being written.
   * @return The numeric value.
   * @throws TypeException When the value is not numeric.
   */
  private static Decimal strictDecimal(
    Object value,
    Schema.DescribeFieldResult field
  ) {
    Decimal converted = looseDecimal(value);
    if (converted != null) {
      return converted;
    }
    throw new TypeException(typeMismatch(value, field, 'a number'));
  }

  /**
   * Converts any typed value to Decimal where that is possible.
   *
   * @param value Value of any Apex type.
   * @return Decimal form, or null when the value is not numeric.
   */
  private static Decimal looseDecimal(Object value) {
    if (value instanceof Decimal) {
      return (Decimal) value;
    }
    if (value instanceof Integer) {
      return Decimal.valueOf((Integer) value);
    }
    if (value instanceof Long) {
      return Decimal.valueOf((Long) value);
    }
    if (value instanceof Double) {
      return Decimal.valueOf((Double) value);
    }
    if (value instanceof String) {
      try {
        return Decimal.valueOf(((String) value).trim());
      } catch (Exception e) {
        return null;
      }
    }
    return null;
  }

  /**
   * Phrases why a value cannot be written to a field.
   *
   * @param value Value that was refused.
   * @param field Describe of the field being written.
   * @param expected What that field does accept, in plain words.
   * @return Message for the TypeException.
   */
  private static String typeMismatch(
    Object value,
    Schema.DescribeFieldResult field,
    String expected
  ) {
    return '"' +
      String.valueOf(value) +
      '" is not ' +
      expected +
      ', which field ' +
      field.getName() +
      ' expects.';
  }

  /**
   * Free text, compared case- and whitespace-insensitively.
   */
  public class TextType implements IValueType {
    /**
     * Takes the document text as written, trimmed.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration.
     * @return Trimmed text, always graded EXACT.
     */
    public ParseResult parse(Object raw, Config cfg) {
      return exact(String.valueOf(raw).trim());
    }

    /**
     * Reduces text to its comparison form.
     *
     * @param value Extracted or stored text.
     * @param cfg Value type configuration.
     * @return Normalized text, or null.
     */
    public Object canonical(Object value, Config cfg) {
      return value == null ? null : normalize(String.valueOf(value));
    }

    /**
     * Compares both sides once normalized.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration.
     * @return MATCH or MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      return compareCanonical(this, extracted, stored, cfg);
    }

    /**
     * Writes the text back out unchanged.
     *
     * @param canonicalValue Normalized text.
     * @param cfg Value type configuration.
     * @return The text, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }

  /**
   * True and false as documents spell them: yes/no, y/n, 1/0.
   */
  public class BooleanType implements IValueType {
    /**
     * Reads one of the accepted spellings of true or false.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration.
     * @return EXACT true or false, or FAILED for anything else.
     */
    public ParseResult parse(Object raw, Config cfg) {
      if (raw instanceof Boolean) {
        return exact(raw);
      }
      String text = String.valueOf(raw).trim().toLowerCase();
      if (text == 'true' || text == 'yes' || text == 'y' || text == '1') {
        return exact(true);
      }
      if (text == 'false' || text == 'no' || text == 'n' || text == '0') {
        return exact(false);
      }
      return failed('"' + raw + '" is not a boolean value.');
    }

    /**
     * Reduces either side to a true Boolean.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration.
     * @return Boolean form, or null when the value reads as neither.
     */
    public Object canonical(Object value, Config cfg) {
      if (value instanceof Boolean) {
        return value;
      }
      ParseResult parsed = parse(value, cfg);
      return parsed.value;
    }

    /**
     * Compares both sides as Booleans.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration.
     * @return MATCH or MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      return compareCanonical(this, extracted, stored, cfg);
    }

    /**
     * Writes the Boolean as "true" or "false".
     *
     * @param canonicalValue Boolean value.
     * @param cfg Value type configuration.
     * @return Text form, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }

  /**
   * Money and plain numbers. Handles currency symbols and ISO codes,
   * NBSP/space thousands, both separator conventions, parenthesised and
   * trailing-minus negatives, CR/DR suffixes and a Scale Factor for
   * documents printed "in thousands".
   *
   * Separator rules: with both "," and "." present the last one is the
   * decimal separator (deterministic). A single separator is deterministic
   * when a Locale is configured; without one, 1-2 trailing digits read as
   * decimals (EXACT — a thousands group needs 3) and exactly 3 trailing
   * digits read as thousands (INFERRED, because "1,234" is genuinely
   * ambiguous across conventions).
   */
  public class NumberType implements IValueType {
    /**
     * Reads an amount, resolving its sign, separators and currency.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying locale, currency and
     *        scale factor.
     * @return The amount and its currency, graded by how much had to be
     *         inferred; AMBIGUOUS when the separators do not settle.
     */
    public ParseResult parse(Object raw, Config cfg) {
      Decimal direct = looseDecimalOf(raw);
      if (direct != null && !(raw instanceof String)) {
        ParseResult typed = exact(scaled(direct, cfg));
        typed.currencyCode = String.isBlank(cfg.currencyCode)
          ? null
          : cfg.currencyCode.trim().toUpperCase();
        return typed;
      }
      String text = String.valueOf(raw).trim();
      if (String.isBlank(text)) {
        return failed('The value is blank.');
      }

      Boolean negative = false;
      Boolean signInferred = false;
      String signNote;
      if (text.startsWith('(') && text.endsWith(')')) {
        negative = true;
        text = text.substring(1, text.length() - 1).trim();
      }
      if (text.endsWith('-')) {
        negative = true;
        text = text.removeEnd('-').trim();
      }
      if (text.startsWith('-')) {
        negative = true;
        text = text.removeStart('-').trim();
      }
      // A trailing 2-letter run is a debit/credit marker; 3 letters would
      // be an ISO currency code, stripped below.
      Matcher letters = TRAILING_LETTERS.matcher(text);
      if (letters.find()) {
        String run = letters.group(1).toUpperCase();
        if (run == 'DR') {
          negative = true;
          signInferred = true;
          signNote = 'The DR suffix was read as a negative sign.';
          text = text.substring(0, letters.start()).trim();
        } else if (run == 'CR') {
          signInferred = true;
          signNote = 'The CR suffix was read as a positive sign.';
          text = text.substring(0, letters.start()).trim();
        }
      }

      // Currency is data, not noise: capture what the document states
      // before the symbols are stripped away, and refuse a value denominated
      // in a currency the value type does not expect.
      String statedCurrency = detectCurrency(text);
      String expected = String.isBlank(cfg.currencyCode)
        ? null
        : cfg.currencyCode.trim().toUpperCase();
      if (
        statedCurrency != null &&
        expected != null &&
        statedCurrency != expected
      ) {
        return failed(
          '"' +
            raw +
            '" is denominated in ' +
            statedCurrency +
            ' but value type ' +
            cfg.name +
            ' expects ' +
            expected +
            '.'
        );
      }
      String currencyCode = statedCurrency != null ? statedCurrency : expected;

      String digits = text.replaceAll('[^0-9.,]', '');
      if (String.isBlank(digits) || !digits.containsAny('0123456789')) {
        return failed('"' + raw + '" contains no number.');
      }

      SeparatorReading reading = readSeparators(digits, cfg);
      if (reading.error != null) {
        return failed('"' + raw + '": ' + reading.error);
      }

      Decimal parsed;
      try {
        parsed = Decimal.valueOf(reading.normalized);
      } catch (Exception e) {
        return failed('"' + raw + '" is not a number.');
      }
      parsed = scaled(parsed, cfg);
      if (negative) {
        parsed = -parsed;
      }

      ParseResult outcome;
      if (reading.inferred || signInferred) {
        List<String> notes = new List<String>();
        if (reading.note != null) {
          notes.add(reading.note);
        }
        if (signNote != null) {
          notes.add(signNote);
        }
        outcome = inferred(parsed, String.join(notes, ' '));
      } else {
        outcome = exact(parsed);
      }
      outcome.currencyCode = currencyCode;
      return outcome;
    }

    /**
     * Reduces either side to a Decimal amount.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration.
     * @return Decimal amount, or null when the value does not read as one.
     */
    public Object canonical(Object value, Config cfg) {
      Decimal direct = looseDecimalOf(value);
      if (direct != null) {
        return direct;
      }
      if (value instanceof String) {
        ParseResult parsed = parse(value, cfg);
        return parsed.value;
      }
      return null;
    }

    /**
     * Compares two amounts, allowing the configured tolerance.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration supplying the tolerance.
     * @return MATCH when equal, NEAR when within tolerance, else MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      Decimal mine = (Decimal) canonical(extracted, cfg);
      Decimal theirs = (Decimal) canonical(stored, cfg);
      if (mine == null || theirs == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      if (mine == theirs) {
        return IdpResult.CompareOutcome.MATCH;
      }
      if (
        cfg.compareTolerance != null &&
        (mine - theirs).abs() <= cfg.compareTolerance
      ) {
        return IdpResult.CompareOutcome.NEAR;
      }
      return IdpResult.CompareOutcome.MISMATCH;
    }

    /**
     * Writes the amount in plain digits, with no grouping.
     *
     * @param canonicalValue Decimal amount.
     * @param cfg Value type configuration.
     * @return Text form, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }

    /**
     * Applies the Scale Factor, for documents printed in thousands.
     *
     * @param value Amount as the document stated it.
     * @param cfg Value type configuration supplying the factor.
     * @return Scaled amount, unchanged when no factor is configured.
     */
    private Decimal scaled(Decimal value, Config cfg) {
      return cfg.scaleFactor == null ? value : value * cfg.scaleFactor;
    }

    /**
     * Converts an already-typed number, leaving text to the full parse.
     *
     * @param value Value read from the document or the record.
     * @return Decimal form, or null for text and non-numeric values.
     */
    private Decimal looseDecimalOf(Object value) {
      return value instanceof String ? null : looseDecimal(value);
    }
  }

  /** How one amount's separators were read, and at what confidence. */
  private class SeparatorReading {
    /** Digits with a single "." decimal separator and no grouping. */
    public String normalized;
    /** True when a convention had to be assumed rather than derived. */
    public Boolean inferred = false;
    /** Which assumption was made. */
    public String note;
    /** Why the separators could not be read at all. */
    public String error;
  }

  /**
   * Decides which separator in an amount is the decimal point.
   *
   * With both "," and "." present the last one decides, deterministically.
   * A single separator is deterministic when a locale is configured;
   * without one, one or two trailing digits read as decimals — a thousands
   * group needs three — and exactly three trailing digits read as
   * thousands, inferred, because "1,234" is genuinely ambiguous.
   *
   * @param digits Amount with sign and currency already stripped.
   * @param cfg Value type configuration supplying the locale.
   * @return The normalized digits, or the reason they were undecidable.
   */
  private static SeparatorReading readSeparators(String digits, Config cfg) {
    SeparatorReading reading = new SeparatorReading();
    Boolean hasComma = digits.contains(',');
    Boolean hasDot = digits.contains('.');

    if (hasComma && hasDot) {
      String decimalSep = digits.lastIndexOf(',') > digits.lastIndexOf('.')
        ? ','
        : '.';
      String thousandsSep = decimalSep == ',' ? '.' : ',';
      if (digits.countMatches(decimalSep) > 1) {
        reading.error = 'several possible decimal separators.';
        return reading;
      }
      reading.normalized = digits.remove(thousandsSep).replace(decimalSep, '.');
      return reading; // both separators present — deterministic
    }

    if (!hasComma && !hasDot) {
      reading.normalized = digits;
      return reading;
    }

    String sep = hasComma ? ',' : '.';
    Integer occurrences = digits.countMatches(sep);
    Integer trailing = digits.length() - digits.lastIndexOf(sep) - 1;

    if (occurrences > 1) {
      // 1,234,567 — separators repeat, so they group thousands.
      reading.normalized = digits.remove(sep);
      return reading;
    }

    // "." or "," per IDP_Country__mdt / IDP_Language__mdt, null when the
    // locale is blank or unseeded — a new market is a record, not a release.
    String localeSep = IdpLocaleData.decimalSeparatorFor(cfg.locale);
    if (localeSep != null) {
      if (sep == localeSep) {
        reading.normalized = digits.replace(sep, '.');
      } else if (trailing == 3) {
        reading.normalized = digits.remove(sep);
      } else {
        // The locale says thousands, but the grouping is not 3 digits —
        // read as a decimal and flag it.
        reading.normalized = digits.replace(sep, '.');
        reading.inferred = true;
        reading.note =
          'The separator disagrees with locale ' +
          cfg.locale +
          '; it was read as a decimal separator.';
      }
      return reading;
    }

    if (trailing == 3) {
      reading.normalized = digits.remove(sep);
      reading.inferred = true;
      reading.note = 'A single separator followed by 3 digits was read as a thousands separator; configure a Locale on the value type to make this deterministic.';
    } else if (trailing > 3) {
      reading.normalized = digits.replace(sep, '.');
      reading.inferred = true;
      reading.note = 'A single separator followed by more than 3 digits was read as a decimal separator.';
    } else {
      // 1-2 trailing digits cannot be a thousands group.
      reading.normalized = digits.replace(sep, '.');
    }
    return reading;
  }

  /**
   * Reads the currency stated next to an amount.
   *
   * Ambiguous symbols ($, ¥, kr) are deliberately left undecided — declare
   * the currency on the value type rather than letting the engine guess
   * between dollars.
   *
   * @param text Amount as the document wrote it.
   * @return ISO 4217 code, or null when nothing decidable was stated.
   */
  @TestVisible
  private static String detectCurrency(String text) {
    Matcher iso = ISO_CODE_TOKEN.matcher(text);
    while (iso.find()) {
      String candidate = iso.group(1).toUpperCase();
      if (ISO_CURRENCIES.contains(candidate)) {
        return candidate;
      }
    }
    for (String symbol : SYMBOL_ORDER) {
      Pattern bounded = symbolPatterns().get(symbol);
      if (bounded != null) {
        if (bounded.matcher(text).find()) {
          return SYMBOL_CURRENCIES.get(symbol);
        }
      } else if (text.contains(symbol)) {
        return SYMBOL_CURRENCIES.get(symbol);
      }
    }
    return null;
  }

  /** Boundary patterns for the alphabetic symbols, so "GBR" never reads as
   *  rand. Built once; a symbol absent from the map is matched literally. */
  private static Map<String, Pattern> symbolPatternCache;

  /**
   * Compiles the boundary patterns for alphabetic currency symbols, once.
   *
   * @return Pattern per symbol that needs one; others match literally.
   */
  private static Map<String, Pattern> symbolPatterns() {
    if (symbolPatternCache == null) {
      symbolPatternCache = new Map<String, Pattern>();
      for (String symbol : SYMBOL_ORDER) {
        if (symbol.isAlpha() || symbol == 'R$') {
          symbolPatternCache.put(
            symbol,
            Pattern.compile(
              '(^|[^A-Za-z])' + escapeRegex(symbol) + '([^A-Za-z]|$)'
            )
          );
        }
      }
    }
    return symbolPatternCache;
  }

  /**
   * Escapes a currency symbol for use inside a pattern.
   *
   * @param literal Symbol to quote.
   * @return The symbol with regex metacharacters escaped.
   */
  private static String escapeRegex(String literal) {
    List<String> escaped = new List<String>();
    for (Integer i = 0; i < literal.length(); i++) {
      String c = literal.substring(i, i + 1);
      escaped.add(('\\^$.|?*+()[]{}'.contains(c) ? '\\' : '') + c);
    }
    return String.join(escaped, '');
  }

  /** ISO 4217 codes recognised when a document states one. */
  private static final Set<String> ISO_CURRENCIES = new Set<String>{
    'USD',
    'EUR',
    'GBP',
    'ZAR',
    'JPY',
    'CNY',
    'CHF',
    'CAD',
    'AUD',
    'NZD',
    'INR',
    'BRL',
    'MXN',
    'SGD',
    'HKD',
    'SEK',
    'NOK',
    'DKK',
    'PLN',
    'CZK',
    'HUF',
    'RON',
    'TRY',
    'UAH',
    'ILS',
    'AED',
    'SAR',
    'QAR',
    'KWD',
    'BHD',
    'OMR',
    'EGP',
    'MAD',
    'NGN',
    'GHS',
    'KES',
    'TZS',
    'UGX',
    'ZMW',
    'BWP',
    'NAD',
    'MZN',
    'MWK',
    'LSL',
    'SZL',
    'ETB',
    'XOF',
    'XAF',
    'KRW',
    'THB',
    'VND',
    'IDR',
    'MYR',
    'PHP',
    'TWD',
    'PKR',
    'BDT',
    'LKR',
    'ARS',
    'CLP',
    'COP',
    'PEN'
  };

  /** Longest symbols first, so R$ (real) is tried before R (rand). $, ¥
   *  and kr are ambiguous across currencies and intentionally absent. */
  private static final List<String> SYMBOL_ORDER = new List<String>{
    'R$',
    '€',
    '£',
    '₹',
    '₩',
    '₦',
    '₪',
    '฿',
    '₫',
    '₴',
    '₺',
    'R'
  };

  /** The currency each unambiguous symbol stands for. */
  private static final Map<String, String> SYMBOL_CURRENCIES = new Map<String, String>{
    'R$' => 'BRL',
    '€' => 'EUR',
    '£' => 'GBP',
    '₹' => 'INR',
    '₩' => 'KRW',
    '₦' => 'NGN',
    '₪' => 'ILS',
    '฿' => 'THB',
    '₫' => 'VND',
    '₴' => 'UAH',
    '₺' => 'TRY',
    'R' => 'ZAR'
  };

  /**
   * Reports whether a code names a currency the engine recognises.
   *
   * Load-time configuration validation uses this to surface typos.
   *
   * @param code Candidate ISO 4217 code.
   * @return True when the code is one of the known currencies.
   */
  public static Boolean isKnownCurrency(String code) {
    return code != null && ISO_CURRENCIES.contains(code.trim().toUpperCase());
  }

  /**
   * Ordered pattern list from Formats__c (default strict ISO). Every
   * pattern is tried; one distinct reading is EXACT, several distinct
   * readings are AMBIGUOUS — 03/04/2024 under "dd/MM/yyyy|MM/dd/yyyy" is
   * reported, never guessed. Components are range-checked, so 31/02/2024
   * fails cleanly. Month names (MMM/MMMM) are read in the language of the
   * value type's Locale — see IdpLocaleData — case- and accent-blind,
   * whole-name or by a prefix only one month answers to. Rendering stays
   * English regardless. Text between single quotes is literal, so
   * "d 'de' MMMM 'de' yyyy" reads a Spanish or Portuguese long date.
   */
  public class DateType implements IValueType {
    /**
     * Reads a date against every configured pattern.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying the patterns, locale
     *        and pivot year.
     * @return EXACT for one distinct reading, AMBIGUOUS when patterns
     *         disagree, FAILED when none matches.
     */
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      if (String.isBlank(text)) {
        return failed('The value is blank.');
      }
      List<String> patterns = cfg.formats.isEmpty()
        ? new List<String>{ 'yyyy-MM-dd' }
        : cfg.formats;

      Map<Date, String> readings = new Map<Date, String>();
      for (String pattern : patterns) {
        Date parsed = tryPattern(text, pattern, cfg);
        if (parsed != null && !readings.containsKey(parsed)) {
          readings.put(parsed, pattern);
        }
      }
      if (readings.isEmpty()) {
        return failed(
          '"' +
            text +
            '" matches none of the date formats ' +
            String.join(patterns, ', ') +
            '.'
        );
      }
      if (readings.size() > 1) {
        List<String> interpretations = new List<String>();
        for (Date reading : readings.keySet()) {
          interpretations.add(
            formatDate(reading, 'yyyy-MM-dd') +
              ' (' +
              readings.get(reading) +
              ')'
          );
        }
        return ambiguous(
          '"' +
            text +
            '" reads as ' +
            String.join(interpretations, ' or ') +
            '.'
        );
      }
      return exact(new List<Date>(readings.keySet())[0]);
    }

    /**
     * Reduces either side to a Date, falling back to ISO text.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration.
     * @return Date, or null when the value does not read as one.
     */
    public Object canonical(Object value, Config cfg) {
      if (value instanceof Date) {
        return value;
      }
      if (value instanceof Datetime) {
        return ((Datetime) value).dateGmt();
      }
      if (value instanceof String) {
        ParseResult parsed = parse(value, cfg);
        if (parsed.value != null) {
          return parsed.value;
        }
        try {
          return Date.valueOf(((String) value).trim());
        } catch (Exception e) {
          return null;
        }
      }
      return null;
    }

    /**
     * Compares two dates, allowing a tolerance measured in days.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration supplying the tolerance.
     * @return MATCH when equal, NEAR when within tolerance, else MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      Date mine = (Date) canonical(extracted, cfg);
      Date theirs = (Date) canonical(stored, cfg);
      if (mine == null || theirs == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      if (mine == theirs) {
        return IdpResult.CompareOutcome.MATCH;
      }
      if (
        cfg.compareTolerance != null &&
        Math.abs(theirs.daysBetween(mine)) <= cfg.compareTolerance
      ) {
        return IdpResult.CompareOutcome.NEAR;
      }
      return IdpResult.CompareOutcome.MISMATCH;
    }

    /**
     * Writes the date in the configured output format, ISO by default.
     *
     * @param canonicalValue Date to render.
     * @param cfg Value type configuration supplying the output format.
     * @return Formatted date, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      if (!(canonicalValue instanceof Date)) {
        return canonicalValue == null ? null : String.valueOf(canonicalValue);
      }
      String pattern = String.isBlank(cfg.outputFormat)
        ? 'yyyy-MM-dd'
        : cfg.outputFormat;
      return formatDate((Date) canonicalValue, pattern);
    }
  }

  /** Rendering stays English: MMM/MMMM output is the same in every
   *  locale, only reading is localised. */
  private static final List<String> MONTH_SHORT = new List<String>{
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  };
  private static final List<String> MONTH_FULL = new List<String>{
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December'
  };

  /** Pattern tokens in reading order plus the regex they compile to. */
  private class DatePattern {
    /** Tokens such as dd or MMMM, aligned with the regex groups. */
    public List<String> tokens = new List<String>();
    /** Regex the whole pattern compiled to. */
    public Pattern regex;
  }

  /** Compiled date patterns, reused for the rest of the transaction. */
  private static Map<String, DatePattern> compiledDatePatterns = new Map<String, DatePattern>();

  /**
   * Reads a date against one pattern, range-checking the components.
   *
   * A day that does not exist in that month fails cleanly rather than
   * rolling over, so 31/02/2024 is never read as 2 March.
   *
   * @param text Date as the document wrote it.
   * @param pattern Format to try, such as dd/MM/yyyy.
   * @param cfg Value type configuration supplying locale and pivot year.
   * @return The date, or null when the text does not fit the pattern.
   */
  private static Date tryPattern(String text, String pattern, Config cfg) {
    DatePattern compiled = compileDatePattern(pattern);
    if (compiled == null) {
      return null;
    }
    Matcher matcher = compiled.regex.matcher(text);
    if (!matcher.matches()) {
      return null;
    }
    Integer day, month, year;
    for (Integer i = 0; i < compiled.tokens.size(); i++) {
      String token = compiled.tokens[i];
      String value = matcher.group(i + 1);
      if (token == 'd' || token == 'dd') {
        day = Integer.valueOf(value);
      } else if (token == 'M' || token == 'MM') {
        month = Integer.valueOf(value);
      } else if (token == 'MMM' || token == 'MMMM') {
        month = IdpLocaleData.monthNumberFor(value, cfg.locale);
        if (month == null) {
          return null;
        }
      } else if (token == 'yyyy') {
        year = Integer.valueOf(value);
      } else if (token == 'yy') {
        year = pivotYear(Integer.valueOf(value), cfg);
      }
    }
    if (
      day == null ||
      month == null ||
      year == null ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > Date.daysInMonth(year, month)
    ) {
      return null;
    }
    return Date.newInstance(year, month, day);
  }

  /**
   * Expands a two-digit year into a full one.
   *
   * The century is chosen so the year lands inside [pivot, pivot+99].
   *
   * @param twoDigits Year as the document wrote it.
   * @param cfg Value type configuration supplying the pivot year.
   * @return Four-digit year.
   */
  private static Integer pivotYear(Integer twoDigits, Config cfg) {
    Integer pivot = cfg.pivotYear == null ? 1950 : cfg.pivotYear;
    Integer candidate = (pivot / 100) * 100 + twoDigits;
    return candidate < pivot ? candidate + 100 : candidate;
  }

  /**
   * Compiles a date format into a regex and its token order, once.
   *
   * Text between single quotes is literal, so "d 'de' MMMM 'de' yyyy"
   * reads a Spanish or Portuguese long date.
   *
   * No local here may be named "pattern": Apex identifier resolution would
   * shadow the System.Pattern class.
   *
   * @param patternText Format as configured on the value type.
   * @return Compiled pattern, or null when the format is unusable.
   */
  private static DatePattern compileDatePattern(String patternText) {
    if (compiledDatePatterns.containsKey(patternText)) {
      return compiledDatePatterns.get(patternText);
    }
    DatePattern compiled = new DatePattern();
    List<String> regex = new List<String>();
    Integer i = 0;
    while (i < patternText.length()) {
      String c = patternText.substring(i, i + 1);
      if (c == 'd' || c == 'M' || c == 'y') {
        Integer runEnd = i;
        while (
          runEnd < patternText.length() &&
          patternText.substring(runEnd, runEnd + 1) == c
        ) {
          runEnd++;
        }
        String token = patternText.substring(i, runEnd);
        compiled.tokens.add(token);
        if (token == 'd' || token == 'M') {
          regex.add('(\\d{1,2})');
        } else if (token == 'dd' || token == 'MM' || token == 'yy') {
          regex.add('(\\d{2})');
        } else if (token == 'yyyy') {
          regex.add('(\\d{4})');
        } else if (token == 'MMM' || token == 'MMMM') {
          // \p{L}, not [A-Za-z]: "Mär" and "Ιαν" are month names too.
          // The optional dot lets "Mrz." through; folding drops it.
          // MMM and MMMM both take three letters or more — abbreviations
          // are not three letters in every language (French "juil",
          // Finnish "tammikuuta"), so the language table decides what
          // counts as a month, not the token's length.
          regex.add('(\\p{L}{3,}\\.?)');
        } else {
          compiledDatePatterns.put(patternText, null); // unsupported token run
          return null;
        }
        i = runEnd;
      } else if (c == '\'') {
        // Quoted literal, so Romance long dates — d 'de' MMMM 'de' yyyy —
        // can say "de" without its d being read as a day. '' is a literal
        // apostrophe.
        Integer close = patternText.indexOf('\'', i + 1);
        if (close < 0) {
          compiledDatePatterns.put(patternText, null); // unterminated quote
          return null;
        }
        String literal = patternText.substring(i + 1, close);
        regex.add(literal == '' ? '\'' : escapeRegex(literal));
        i = close + 1;
      } else if (c == ' ') {
        regex.add('\\s+');
        i++;
      } else if ('\\^$.|?*+()[]{}'.contains(c)) {
        regex.add('\\' + c);
        i++;
      } else {
        regex.add(c);
        i++;
      }
    }
    try {
      compiled.regex = Pattern.compile(String.join(regex, ''));
    } catch (Exception e) {
      compiled = null;
    }
    compiledDatePatterns.put(patternText, compiled);
    return compiled;
  }

  /**
   * Renders a Date through the same token set the parser reads.
   *
   * Month names are written in English whatever the reading locale was.
   *
   * @param value Date to render.
   * @param pattern Output format, using the parser's tokens.
   * @return Formatted date.
   */
  public static String formatDate(Date value, String pattern) {
    List<String> output = new List<String>();
    Integer i = 0;
    while (i < pattern.length()) {
      String c = pattern.substring(i, i + 1);
      if (c == 'd' || c == 'M' || c == 'y') {
        Integer runEnd = i;
        while (
          runEnd < pattern.length() &&
          pattern.substring(runEnd, runEnd + 1) == c
        ) {
          runEnd++;
        }
        String token = pattern.substring(i, runEnd);
        if (token == 'd') {
          output.add(String.valueOf(value.day()));
        } else if (token == 'dd') {
          output.add(pad2(value.day()));
        } else if (token == 'M') {
          output.add(String.valueOf(value.month()));
        } else if (token == 'MM') {
          output.add(pad2(value.month()));
        } else if (token == 'MMM') {
          output.add(MONTH_SHORT[value.month() - 1]);
        } else if (token == 'MMMM') {
          output.add(MONTH_FULL[value.month() - 1]);
        } else if (token == 'yy') {
          output.add(pad2(Math.mod(value.year(), 100)));
        } else {
          output.add(String.valueOf(value.year()).leftPad(4, '0'));
        }
        i = runEnd;
      } else if (c == '\'') {
        Integer close = pattern.indexOf('\'', i + 1);
        if (close < 0) {
          output.add(c);
          i++;
        } else {
          String literal = pattern.substring(i + 1, close);
          output.add(literal == '' ? '\'' : literal);
          i = close + 1;
        }
      } else {
        output.add(c);
        i++;
      }
    }
    return String.join(output, '');
  }

  /**
   * Left-pads a day or month to two digits.
   *
   * @param value Number to pad.
   * @return Two-character text.
   */
  private static String pad2(Integer value) {
    return String.valueOf(value).leftPad(2, '0');
  }

  /**
   * ISO 8601. A timestamp with an explicit offset is EXACT. A naive one
   * ("2024-03-15 09:00") is read in the configured Timezone (EXACT) or as
   * GMT when none is configured (INFERRED, with a note — a silent
   * two-hour drift is exactly the kind of bug this engine exists to
   * avoid).
   */
  public class DatetimeType implements IValueType {
    /**
     * Reads an ISO 8601 timestamp, resolving its zone.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying the timezone.
     * @return EXACT when the zone is known, INFERRED when GMT had to be
     *         assumed, FAILED when the text is not a timestamp.
     */
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      if (String.isBlank(text)) {
        return failed('The value is blank.');
      }
      if (OFFSET_SUFFIX.matcher(text).matches()) {
        Datetime parsed = deserializeIso(text);
        return parsed == null
          ? failed('"' + text + '" is not a valid ISO 8601 date/time.')
          : exact(parsed);
      }
      Matcher naive = NAIVE_TIMESTAMP.matcher(text);
      if (!naive.matches()) {
        return failed('"' + text + '" is not a recognized date/time.');
      }
      Datetime wallAsGmt = Datetime.newInstanceGmt(
        Integer.valueOf(naive.group(1)),
        Integer.valueOf(naive.group(2)),
        Integer.valueOf(naive.group(3)),
        Integer.valueOf(naive.group(4)),
        Integer.valueOf(naive.group(5)),
        naive.group(6) == null ? 0 : Integer.valueOf(naive.group(6))
      );
      if (String.isNotBlank(cfg.timezone)) {
        TimeZone zone = TimeZone.getTimeZone(cfg.timezone);
        return exact(wallAsGmt.addSeconds(-zone.getOffset(wallAsGmt) / 1000));
      }
      return inferred(
        wallAsGmt,
        'The timestamp has no offset and no Timezone is configured; it was read as GMT.'
      );
    }

    /**
     * Reduces either side to a Datetime.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration.
     * @return Datetime, or null when the value does not read as one.
     */
    public Object canonical(Object value, Config cfg) {
      if (value instanceof Datetime) {
        return value;
      }
      if (value instanceof String) {
        ParseResult parsed = parse(value, cfg);
        return parsed.value;
      }
      return null;
    }

    /**
     * Compares two timestamps, allowing a tolerance measured in minutes.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration supplying the tolerance.
     * @return MATCH when equal, NEAR when within tolerance, else MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      Datetime mine = (Datetime) canonical(extracted, cfg);
      Datetime theirs = (Datetime) canonical(stored, cfg);
      if (mine == null || theirs == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      if (mine.getTime() == theirs.getTime()) {
        return IdpResult.CompareOutcome.MATCH;
      }
      if (
        cfg.compareTolerance != null &&
        Math.abs(mine.getTime() - theirs.getTime()) <=
        cfg.compareTolerance * 60000
      ) {
        return IdpResult.CompareOutcome.NEAR;
      }
      return IdpResult.CompareOutcome.MISMATCH;
    }

    /**
     * Writes the timestamp as ISO 8601 in GMT.
     *
     * @param canonicalValue Datetime to render.
     * @param cfg Value type configuration.
     * @return Formatted timestamp, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      if (!(canonicalValue instanceof Datetime)) {
        return canonicalValue == null ? null : String.valueOf(canonicalValue);
      }
      return ((Datetime) canonicalValue)
        .formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
  }

  /**
   * Reads an offset-bearing ISO 8601 timestamp.
   *
   * @param text Timestamp as the document wrote it.
   * @return The instant, or null when the text is not valid ISO 8601.
   */
  private static Datetime deserializeIso(String text) {
    try {
      return (Datetime) JSON.deserialize('"' + text + '"', Datetime.class);
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * Canonical form is E.164. "+27 82 123 4567", "0027821234567" and — with
   * Region = ZA — "082 123 4567" all canonicalize to +27821234567, so
   * Compliance stops reporting formatting as a mismatch. Without a region
   * (or with one no IDP_Country__mdt record covers), national numbers stay
   * digit strings and parse as INFERRED.
   */
  public class PhoneType implements IValueType {
    /**
     * Reads a phone number towards E.164.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying the region.
     * @return EXACT when the country code is explicit or derivable from a
     *         national prefix, INFERRED when one had to be assumed,
     *         FAILED when the digits are not a plausible number.
     */
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      if (String.isBlank(text)) {
        return failed('The value is blank.');
      }
      Boolean hasPlus = text.startsWith('+');
      String digits = text.replaceAll('[^0-9]', '');
      if (digits.length() < 4) {
        return failed('"' + text + '" is too short to be a phone number.');
      }
      if (hasPlus) {
        return digits.length() >= 8 &&
          digits.length() <= 15
          ? exact('+' + digits)
          : failed('"' + text + '" is not a plausible international number.');
      }
      if (digits.startsWith('00') && digits.length() >= 11) {
        return exact('+' + digits.substring(2));
      }
      String dial = dialCodeFor(cfg.region);
      if (dial != null) {
        if (digits.startsWith('0')) {
          return exact('+' + dial + digits.substring(1));
        }
        if (digits.startsWith(dial) && digits.length() >= 10) {
          return inferred(
            '+' + digits,
            'The leading digits were assumed to be the country code.'
          );
        }
        return inferred(
          '+' + dial + digits,
          'The number was assumed to be national for region ' + cfg.region + '.'
        );
      }
      return inferred(
        digits,
        'No Region is configured, so only the digits were kept.'
      );
    }

    /**
     * Reduces either side to its E.164 form.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration supplying the region.
     * @return E.164 number, or null when the value does not read as one.
     */
    public Object canonical(Object value, Config cfg) {
      if (value == null) {
        return null;
      }
      ParseResult parsed = parse(String.valueOf(value), cfg);
      return parsed.value;
    }

    /**
     * Compares two numbers once both are in E.164.
     *
     * Numbers agreeing on their last nine digits are NEAR rather than a
     * mismatch, which is how a differing country code surfaces for review.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration supplying the region.
     * @return MATCH, NEAR or MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      String mine = (String) canonical(extracted, cfg);
      String theirs = (String) canonical(stored, cfg);
      if (mine == null || theirs == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      if (mine == theirs) {
        return IdpResult.CompareOutcome.MATCH;
      }
      String mineDigits = mine.removeStart('+');
      String theirsDigits = theirs.removeStart('+');
      if (
        mineDigits.length() >= 9 &&
        theirsDigits.length() >= 9 &&
        mineDigits.right(9) == theirsDigits.right(9)
      ) {
        return IdpResult.CompareOutcome.NEAR;
      }
      return IdpResult.CompareOutcome.MISMATCH;
    }

    /**
     * Writes the number as E.164, bare digits, or national form.
     *
     * @param canonicalValue E.164 number to render.
     * @param cfg Value type configuration supplying the output format and
     *        the region a national form is relative to.
     * @return Formatted number, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      if (canonicalValue == null) {
        return null;
      }
      String value = String.valueOf(canonicalValue);
      String style = String.isBlank(cfg.outputFormat)
        ? 'e164'
        : cfg.outputFormat.toLowerCase();
      if (style == 'digits') {
        return value.removeStart('+');
      }
      if (style == 'national') {
        String dial = dialCodeFor(cfg.region);
        if (dial != null && value.startsWith('+' + dial)) {
          return '0' + value.substring(dial.length() + 1);
        }
        return value.removeStart('+');
      }
      return value; // e164
    }
  }

  /**
   * Resolves a region's dial code from the org's reference data.
   *
   * @param region ISO country code.
   * @return E.164 dial code, or null when the country is not seeded.
   */
  public static String dialCodeFor(String region) {
    return IdpLocaleData.dialCodeFor(region);
  }

  /**
   * Admin-editable dictionary: the value type's Value_Map_Entries__c JSON translates
   * what the document says into what the org stores ("Pty Ltd" → "Private
   * Company"). Unmapped input FAILs with a clear message rather than
   * writing free text into a controlled field.
   */
  public class ValueMapType implements IValueType {
    /**
     * Translates document text through the configured dictionary.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying the map entries.
     * @return EXACT with the mapped value, or FAILED when the text is not
     *         mapped — free text never reaches a controlled field.
     */
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      String mapped = applyMap(text, cfg);
      if (mapped != null) {
        return exact(mapped);
      }
      return failed(
        '"' +
          text +
          '" is not mapped by value map ' +
          cfg.name +
          ' (' +
          cfg.mapEntries.size() +
          ' entries).'
      );
    }

    /**
     * Translates either side, so a stored value compares on equal terms.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration supplying the map entries.
     * @return Normalized mapped value, or the normalized original when the
     *         dictionary does not cover it.
     */
    public Object canonical(Object value, Config cfg) {
      if (value == null) {
        return null;
      }
      String text = String.valueOf(value).trim();
      String mapped = applyMap(text, cfg);
      return normalize(mapped == null ? text : mapped);
    }

    /**
     * Compares both sides once translated.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration.
     * @return MATCH or MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      return compareCanonical(this, extracted, stored, cfg);
    }

    /**
     * Writes the mapped value as stored.
     *
     * @param canonicalValue Mapped value.
     * @param cfg Value type configuration.
     * @return The value as text, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }

    /**
     * Finds the first dictionary entry the text answers to.
     *
     * Entries match exactly, by regex, or normalized, per their own style.
     *
     * @param text Document text to translate.
     * @param cfg Value type configuration supplying the map entries.
     * @return Mapped value, or null when no entry covers the text.
     */
    private String applyMap(String text, Config cfg) {
      for (MapEntry entry : cfg.mapEntries) {
        if (entry.matchStyle == 'Exact') {
          if (entry.fromText == text) {
            return entry.toValue;
          }
        } else if (entry.matchStyle == 'Regex') {
          try {
            if (Pattern.matches(entry.fromText, text)) {
              return entry.toValue;
            }
          } catch (Exception e) {
            continue; // invalid pattern is reported at load time
          }
        } else if (normalize(entry.fromText) == normalize(text)) {
          return entry.toValue;
        }
      }
      return null;
    }
  }

  /**
   * Extracts the first capturing group (or the whole match) of the pattern
   * in Formats__c — for reference numbers buried in surrounding text, e.g.
   * "Estate No\\.?\\s*([0-9/]+)". The Formats value is used unsplit, so
   * alternations with | work.
   */
  public class RegexType implements IValueType {
    /**
     * Pulls the wanted substring out of the surrounding text.
     *
     * @param raw Value read from the document.
     * @param cfg Value type configuration supplying the unsplit pattern.
     * @return EXACT with the captured text, or FAILED when the pattern is
     *         missing, invalid, or does not match.
     */
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      if (String.isBlank(cfg.formatsRaw)) {
        return failed('Value type ' + cfg.name + ' has no pattern in Formats.');
      }
      Matcher matcher;
      try {
        matcher = Pattern.compile(cfg.formatsRaw).matcher(text);
      } catch (Exception e) {
        return failed(
          'Value type ' +
            cfg.name +
            ' has an invalid pattern: ' +
            e.getMessage()
        );
      }
      if (!matcher.find()) {
        return failed(
          '"' + text + '" does not match the pattern of ' + cfg.name + '.'
        );
      }
      String extracted = matcher.groupCount() >= 1 &&
        matcher.group(1) != null
        ? matcher.group(1)
        : matcher.group(0);
      return exact(extracted.trim());
    }

    /**
     * Reduces the captured text to its comparison form.
     *
     * @param value Extracted or stored value.
     * @param cfg Value type configuration.
     * @return Normalized text, or null.
     */
    public Object canonical(Object value, Config cfg) {
      return value == null ? null : normalize(String.valueOf(value));
    }

    /**
     * Compares both sides once normalized.
     *
     * @param extracted Value read from the document.
     * @param stored Value read from the target field.
     * @param cfg Value type configuration.
     * @return MATCH or MISMATCH.
     */
    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      return compareCanonical(this, extracted, stored, cfg);
    }

    /**
     * Writes the captured text back out unchanged.
     *
     * @param canonicalValue Normalized text.
     * @param cfg Value type configuration.
     * @return The text, or null.
     */
    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }
}
