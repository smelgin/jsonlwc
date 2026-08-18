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
 */
public inherited sharing class IdpValueTypes {
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

  /** One IDP_Value_Type__mdt record in plain Apex. */
  public class Config {
    public String name; // DeveloperName, for messages
    public String kind = KIND_TEXT;
    public String handlerClass;
    public String locale;
    /** Number kind: ISO 4217 code the documents are denominated in. A
     *  stated currency that disagrees fails the parse; an unstated one is
     *  assumed to be this. Blank accepts whatever the document states. */
    public String currencyCode;
    public List<String> formats = new List<String>(); // Formats__c split on |
    public String formatsRaw; // unsplit, for Regex kind
    public String outputFormat;
    public String region;
    public Decimal scaleFactor;
    public Decimal compareTolerance;
    public Integer pivotYear;
    public String timezone;
    public String customOptions;
    public List<MapEntry> mapEntries = new List<MapEntry>();
  }

  public class MapEntry {
    public String fromText;
    public String toValue;
    public String matchStyle = 'Normalized';
  }

  public class ParseResult {
    public Object value;
    public IdpResult.Grade grade;
    public String note;
    /** Number kind: ISO 4217 code the document stated (or the value type
     *  implied). Null when neither says — a plain quantity. */
    public String currencyCode;
  }

  public static ParseResult exact(Object value) {
    return result(value, IdpResult.Grade.EXACT, null);
  }

  public static ParseResult inferred(Object value, String note) {
    return result(value, IdpResult.Grade.INFERRED, note);
  }

  public static ParseResult ambiguous(String note) {
    return result(null, IdpResult.Grade.AMBIGUOUS, note);
  }

  public static ParseResult failed(String note) {
    return result(null, IdpResult.Grade.FAILED, note);
  }

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

  /** Trim, collapse whitespace, lowercase — the text comparison form. */
  public static String normalize(String value) {
    return value == null
      ? ''
      : value.trim().replaceAll('\\s+', ' ').toLowerCase();
  }

  /**
   * Fits a canonical value into the Apex type the target field expects.
   * Types return proper Apex values (Decimal, Date, ...), so this is a
   * narrow adapter, not a parser; a genuine mismatch (a Text value type on
   * a Currency field fed non-numeric text) throws with a clear message.
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

  /** Decimal from any typed value; null when it is not numeric. */
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

  // ───────────────────────────── Text ─────────────────────────────

  public class TextType implements IValueType {
    public ParseResult parse(Object raw, Config cfg) {
      return exact(String.valueOf(raw).trim());
    }

    public Object canonical(Object value, Config cfg) {
      return value == null ? null : normalize(String.valueOf(value));
    }

    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      if (stored == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      return canonical(extracted, cfg) == canonical(stored, cfg)
        ? IdpResult.CompareOutcome.MATCH
        : IdpResult.CompareOutcome.MISMATCH;
    }

    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }

  // ─────────────────────────── Boolean ────────────────────────────

  public class BooleanType implements IValueType {
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

    public Object canonical(Object value, Config cfg) {
      if (value instanceof Boolean) {
        return value;
      }
      ParseResult parsed = parse(value, cfg);
      return parsed.value;
    }

    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      if (stored == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      return canonical(extracted, cfg) == canonical(stored, cfg)
        ? IdpResult.CompareOutcome.MATCH
        : IdpResult.CompareOutcome.MISMATCH;
    }

    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }

  // ─────────────────────────── Number ─────────────────────────────

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
      Matcher letters = Pattern.compile('([A-Za-z]+)\\s*$').matcher(text);
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

    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }

    private Decimal scaled(Decimal value, Config cfg) {
      return cfg.scaleFactor == null ? value : value * cfg.scaleFactor;
    }

    private Decimal looseDecimalOf(Object value) {
      return value instanceof String ? null : looseDecimal(value);
    }
  }

  private class SeparatorReading {
    public String normalized;
    public Boolean inferred = false;
    public String note;
    public String error;
  }

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
   * ISO code or unambiguous symbol stated next to the amount; null when the
   * document says nothing decidable. Ambiguous symbols ($, ¥, kr) are
   * deliberately not decided here — declare the currency on the value type
   * instead of letting the engine guess between dollars.
   */
  @TestVisible
  private static String detectCurrency(String text) {
    Matcher iso = Pattern.compile('(?<![A-Za-z])([A-Za-z]{3})(?![A-Za-z])')
      .matcher(text);
    while (iso.find()) {
      String candidate = iso.group(1).toUpperCase();
      if (ISO_CURRENCIES.contains(candidate)) {
        return candidate;
      }
    }
    for (String symbol : SYMBOL_ORDER) {
      if (symbol.isAlpha() || symbol == 'R$') {
        // Alphabetic symbols need a word-ish boundary so "GBR" never
        // reads as rand.
        if (
          Pattern.compile(
              '(^|[^A-Za-z])' + escapeRegex(symbol) + '([^A-Za-z]|$)'
            )
            .matcher(text)
            .find()
        ) {
          return SYMBOL_CURRENCIES.get(symbol);
        }
      } else if (text.contains(symbol)) {
        return SYMBOL_CURRENCIES.get(symbol);
      }
    }
    return null;
  }

  private static String escapeRegex(String literal) {
    String escaped = '';
    for (Integer i = 0; i < literal.length(); i++) {
      String c = literal.substring(i, i + 1);
      escaped += ('\\^$.|?*+()[]{}'.contains(c) ? '\\' : '') + c;
    }
    return escaped;
  }

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

  /** True when the code is a known ISO 4217 currency — load-time config
   *  validation uses this. */
  public static Boolean isKnownCurrency(String code) {
    return code != null && ISO_CURRENCIES.contains(code.trim().toUpperCase());
  }

  // ──────────────────────────── Date ──────────────────────────────

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
    public List<String> tokens = new List<String>();
    public Pattern regex;
  }

  private static Map<String, DatePattern> compiledDatePatterns = new Map<String, DatePattern>();

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

  /** The century is chosen so the year lands inside [pivot, pivot+99]. */
  private static Integer pivotYear(Integer twoDigits, Config cfg) {
    Integer pivot = cfg.pivotYear == null ? 1950 : cfg.pivotYear;
    Integer candidate = (pivot / 100) * 100 + twoDigits;
    return candidate < pivot ? candidate + 100 : candidate;
  }

  // NB: no local here may be named "pattern" — Apex identifier resolution
  // would shadow the System.Pattern class.
  private static DatePattern compileDatePattern(String patternText) {
    if (compiledDatePatterns.containsKey(patternText)) {
      return compiledDatePatterns.get(patternText);
    }
    DatePattern compiled = new DatePattern();
    String regex = '';
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
          regex += '(\\d{1,2})';
        } else if (token == 'dd' || token == 'MM' || token == 'yy') {
          regex += '(\\d{2})';
        } else if (token == 'yyyy') {
          regex += '(\\d{4})';
        } else if (token == 'MMM' || token == 'MMMM') {
          // \p{L}, not [A-Za-z]: "Mär" and "Ιαν" are month names too.
          // The optional dot lets "Mrz." through; folding drops it.
          // MMM and MMMM both take three letters or more — abbreviations
          // are not three letters in every language (French "juil",
          // Finnish "tammikuuta"), so the language table decides what
          // counts as a month, not the token's length.
          regex += '(\\p{L}{3,}\\.?)';
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
        regex += literal == '' ? '\'' : escapeRegex(literal);
        i = close + 1;
      } else if (c == ' ') {
        regex += '\\s+';
        i++;
      } else if ('\\^$.|?*+()[]{}'.contains(c)) {
        regex += '\\' + c;
        i++;
      } else {
        regex += c;
        i++;
      }
    }
    try {
      compiled.regex = Pattern.compile(regex);
    } catch (Exception e) {
      compiled = null;
    }
    compiledDatePatterns.put(patternText, compiled);
    return compiled;
  }

  /** Renders a Date through the same token set the parser reads. */
  public static String formatDate(Date value, String pattern) {
    String output = '';
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
          output += String.valueOf(value.day());
        } else if (token == 'dd') {
          output += pad2(value.day());
        } else if (token == 'M') {
          output += String.valueOf(value.month());
        } else if (token == 'MM') {
          output += pad2(value.month());
        } else if (token == 'MMM') {
          output += MONTH_SHORT[value.month() - 1];
        } else if (token == 'MMMM') {
          output += MONTH_FULL[value.month() - 1];
        } else if (token == 'yy') {
          output += pad2(Math.mod(value.year(), 100));
        } else {
          output += String.valueOf(value.year()).leftPad(4, '0');
        }
        i = runEnd;
      } else if (c == '\'') {
        Integer close = pattern.indexOf('\'', i + 1);
        if (close < 0) {
          output += c;
          i++;
        } else {
          String literal = pattern.substring(i + 1, close);
          output += literal == '' ? '\'' : literal;
          i = close + 1;
        }
      } else {
        output += c;
        i++;
      }
    }
    return output;
  }

  private static String pad2(Integer value) {
    return String.valueOf(value).leftPad(2, '0');
  }

  // ────────────────────────── Datetime ────────────────────────────

  /**
   * ISO 8601. A timestamp with an explicit offset is EXACT. A naive one
   * ("2024-03-15 09:00") is read in the configured Timezone (EXACT) or as
   * GMT when none is configured (INFERRED, with a note — a silent
   * two-hour drift is exactly the kind of bug this engine exists to
   * avoid).
   */
  public class DatetimeType implements IValueType {
    public ParseResult parse(Object raw, Config cfg) {
      String text = String.valueOf(raw).trim();
      if (String.isBlank(text)) {
        return failed('The value is blank.');
      }
      if (Pattern.matches('.*([+-]\\d{2}:?\\d{2}|Z)$', text)) {
        Datetime parsed = deserializeIso(text);
        return parsed == null
          ? failed('"' + text + '" is not a valid ISO 8601 date/time.')
          : exact(parsed);
      }
      Matcher naive = Pattern.compile(
          '^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?$'
        )
        .matcher(text);
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

    public String render(Object canonicalValue, Config cfg) {
      if (!(canonicalValue instanceof Datetime)) {
        return canonicalValue == null ? null : String.valueOf(canonicalValue);
      }
      return ((Datetime) canonicalValue)
        .formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
  }

  private static Datetime deserializeIso(String text) {
    try {
      return (Datetime) JSON.deserialize('"' + text + '"', Datetime.class);
    } catch (Exception e) {
      return null;
    }
  }

  // ─────────────────────────── Phone ──────────────────────────────

  /**
   * Canonical form is E.164. "+27 82 123 4567", "0027821234567" and — with
   * Region = ZA — "082 123 4567" all canonicalize to +27821234567, so
   * Compliance stops reporting formatting as a mismatch. Without a region
   * (or with one no IDP_Country__mdt record covers), national numbers stay
   * digit strings and parse as INFERRED.
   */
  public class PhoneType implements IValueType {
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

    public Object canonical(Object value, Config cfg) {
      if (value == null) {
        return null;
      }
      ParseResult parsed = parse(String.valueOf(value), cfg);
      return parsed.value;
    }

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

  public static String dialCodeFor(String region) {
    return IdpLocaleData.dialCodeFor(region);
  }

  // ────────────────────────── ValueMap ────────────────────────────

  /**
   * Admin-editable dictionary: IDP_Value_Map_Entry__mdt records translate
   * what the document says into what the org stores ("Pty Ltd" → "Private
   * Company"). Unmapped input FAILs with a clear message rather than
   * writing free text into a controlled field.
   */
  public class ValueMapType implements IValueType {
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

    public Object canonical(Object value, Config cfg) {
      if (value == null) {
        return null;
      }
      String text = String.valueOf(value).trim();
      String mapped = applyMap(text, cfg);
      return normalize(mapped == null ? text : mapped);
    }

    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      if (stored == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      return canonical(extracted, cfg) == canonical(stored, cfg)
        ? IdpResult.CompareOutcome.MATCH
        : IdpResult.CompareOutcome.MISMATCH;
    }

    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }

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

  // ─────────────────────────── Regex ──────────────────────────────

  /**
   * Extracts the first capturing group (or the whole match) of the pattern
   * in Formats__c — for reference numbers buried in surrounding text, e.g.
   * "Estate No\\.?\\s*([0-9/]+)". The Formats value is used unsplit, so
   * alternations with | work.
   */
  public class RegexType implements IValueType {
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

    public Object canonical(Object value, Config cfg) {
      return value == null ? null : normalize(String.valueOf(value));
    }

    public IdpResult.CompareOutcome compare(
      Object extracted,
      Object stored,
      Config cfg
    ) {
      if (stored == null) {
        return IdpResult.CompareOutcome.MISMATCH;
      }
      return canonical(extracted, cfg) == canonical(stored, cfg)
        ? IdpResult.CompareOutcome.MATCH
        : IdpResult.CompareOutcome.MISMATCH;
    }

    public String render(Object canonicalValue, Config cfg) {
      return canonicalValue == null ? null : String.valueOf(canonicalValue);
    }
  }
}
