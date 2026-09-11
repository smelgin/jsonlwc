/**
 * The engine's locale reference data, read from IDP_Country__mdt and
 * IDP_Language__mdt rather than hardcoded: dial codes, decimal separators
 * and month names.
 *
 * Deliberately not Java locale data. Datetime.parse and friends resolve
 * against the *running user's* locale, so the same document would read
 * differently depending on who happened to run the job — precisely the
 * class of bug v2 exists to eliminate. A value type names the locale of
 * the document, and that is the only locale consulted.
 *
 * Custom metadata SOQL does not count against query limits, and both
 * tables are cached for the transaction, so the performance model is
 * unaffected. English month names are also compiled in as a last-resort
 * fallback: a partial deploy degrades to today's behaviour, never below.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpLocaleData {
  /**
   * Resolves a country's E.164 dial code.
   *
   * @param region ISO country code, as the IDP_Country__mdt DeveloperName.
   * @return Dial code, or null when the country is unknown or has none.
   */
  public static String dialCodeFor(String region) {
    Country country = countryFor(region);
    return country == null || String.isBlank(country.dialCode)
      ? null
      : country.dialCode;
  }

  /**
   * Resolves the decimal separator a locale's documents use.
   *
   * The country subtag wins over the language, so de-CH reads Swiss dot
   * decimals while de-DE reads German comma decimals.
   *
   * @param locale Locale tag, such as de-CH.
   * @return "." or ",", or null when nothing in the tag decides it.
   */
  public static String decimalSeparatorFor(String locale) {
    Tag tag = parseTag(locale);
    if (tag == null) {
      return null;
    }
    Country country = countries().get(tag.country);
    if (country != null && String.isNotBlank(country.decimalSeparator)) {
      return country.decimalSeparator;
    }
    Language language = languages().get(tag.language);
    if (language != null && String.isNotBlank(language.decimalSeparator)) {
      return language.decimalSeparator;
    }
    return null;
  }

  /**
   * Reads a month name written in the locale's language.
   *
   * A prefix shared by two months (Portuguese "ma" for março and maio) is
   * undecidable and reported as such — the caller turns that into a failed
   * parse rather than a guess.
   *
   * @param text Month name or abbreviation taken from the document.
   * @param locale Locale tag whose language supplies the spellings.
   * @return 1–12, or null when no month or more than one answers to it.
   */
  public static Integer monthNumberFor(String text, String locale) {
    if (String.isBlank(text)) {
      return null;
    }
    List<List<String>> months = monthAliasesFor(locale);
    if (months.isEmpty()) {
      return null;
    }
    String probe = fold(text);
    if (String.isBlank(probe)) {
      return null;
    }
    for (Integer month = 0; month < months.size(); month++) {
      for (String alias : months[month]) {
        if (alias == probe) {
          return month + 1;
        }
      }
    }
    if (probe.length() < 3) {
      return null; // too short to identify a month by prefix
    }
    Integer hit = null;
    for (Integer month = 0; month < months.size(); month++) {
      for (String alias : months[month]) {
        if (alias.startsWith(probe)) {
          if (hit != null && hit != month + 1) {
            return null; // several months share the prefix
          }
          hit = month + 1;
        }
      }
    }
    return hit;
  }

  /**
   * Reports whether the org has seeded reference data for a country.
   *
   * @param region ISO country code to check.
   * @return True when an IDP_Country__mdt record exists for the code.
   */
  public static Boolean isKnownCountry(String region) {
    return countryFor(region) != null;
  }

  /**
   * Reports whether a locale tag resolves to seeded reference data.
   *
   * Load-time validation uses this to surface typos in configuration.
   *
   * @param locale Locale tag to check.
   * @return True when an IDP_Language__mdt matches its language or an
   *         IDP_Country__mdt matches its country.
   */
  public static Boolean isKnownLocale(String locale) {
    Tag tag = parseTag(locale);
    return tag != null &&
      (languages().containsKey(tag.language) ||
      countries().containsKey(tag.country));
  }

  /**
   * Reports whether a locale's own language declares month names.
   *
   * Not whether reading one would succeed, which the English fallback
   * would always make true: load-time validation needs the honest answer.
   *
   * @param locale Locale tag to check.
   * @return True when that language seeded its own month spellings.
   */
  public static Boolean readsMonthNames(String locale) {
    return !declaredMonthsFor(locale).isEmpty();
  }

  /** Reference data held for one country. */
  public class Country {
    /** E.164 dial code, null when the record leaves it unset. */
    public String dialCode;
    /** Decimal separator this country's documents use. */
    public String decimalSeparator;
  }

  /** Reference data held for one language. */
  public class Language {
    /** Decimal separator this language's documents use. */
    public String decimalSeparator;
    /** Twelve slots, January first; each holds that month's folded
     *  spellings. Empty when the language declares no month names. */
    public List<List<String>> months = new List<List<String>>();
  }

  /** The two halves of a parsed locale tag. */
  private class Tag {
    /** Lowercased language subtag. */
    public String language;
    /** Uppercased country subtag, null when the tag carries none. */
    public String country;
  }

  /**
   * Splits a locale tag into its language and country subtags.
   *
   * @param locale Locale tag, with either "-" or "_" as separator.
   * @return Parsed tag, or null when no tag was supplied.
   */
  private static Tag parseTag(String locale) {
    if (String.isBlank(locale)) {
      return null;
    }
    List<String> parts = locale.trim().replace('_', '-').split('-');
    Tag tag = new Tag();
    tag.language = parts[0].toLowerCase();
    tag.country = parts.size() > 1 ? parts[1].toUpperCase() : null;
    return tag;
  }

  /**
   * Looks a country up by code, ignoring case and surrounding space.
   *
   * @param region ISO country code.
   * @return Country reference data, or null when it is not seeded.
   */
  private static Country countryFor(String region) {
    return String.isBlank(region)
      ? null
      : countries().get(region.trim().toUpperCase());
  }

  /**
   * Lists the month spellings a locale's own language declares.
   *
   * @param locale Locale tag whose language is consulted.
   * @return Twelve alias lists, or empty when the language names none.
   */
  private static List<List<String>> declaredMonthsFor(String locale) {
    Tag tag = parseTag(locale);
    Language language = tag == null ? null : languages().get(tag.language);
    return language == null ? new List<List<String>>() : language.months;
  }

  /**
   * Chooses the month spellings used to read a document.
   *
   * Falls back to English so a locale the org has not seeded still reads
   * "15 March 2024".
   *
   * @param locale Locale tag whose language is consulted first.
   * @return Twelve alias lists, never empty in a seeded org.
   */
  private static List<List<String>> monthAliasesFor(String locale) {
    List<List<String>> declared = declaredMonthsFor(locale);
    if (!declared.isEmpty()) {
      return declared;
    }
    Language english = languages().get('en');
    return english != null && !english.months.isEmpty()
      ? english.months
      : FALLBACK_ENGLISH_MONTHS;
  }

  /** IDP_Country__mdt records read once per transaction. */
  @TestVisible
  private static Map<String, Country> countryCache;

  /** IDP_Language__mdt records read once per transaction. */
  @TestVisible
  private static Map<String, Language> languageCache;

  /**
   * Reads country reference data, once per transaction.
   *
   * @return Country data keyed by uppercased ISO code.
   */
  private static Map<String, Country> countries() {
    if (countryCache == null) {
      countryCache = new Map<String, Country>();
      for (IDP_Country__mdt record : [
        SELECT DeveloperName, Dial_Code__c, Decimal_Separator__c
        FROM IDP_Country__mdt
      ]) {
        Country country = new Country();
        country.dialCode = trimmed(record.Dial_Code__c);
        country.decimalSeparator = trimmed(record.Decimal_Separator__c);
        countryCache.put(record.DeveloperName.toUpperCase(), country);
      }
    }
    return countryCache;
  }

  /**
   * Reads language reference data, once per transaction.
   *
   * @return Language data keyed by lowercased language subtag.
   */
  private static Map<String, Language> languages() {
    if (languageCache == null) {
      languageCache = new Map<String, Language>();
      for (IDP_Language__mdt record : [
        SELECT DeveloperName, Decimal_Separator__c, Month_Names__c
        FROM IDP_Language__mdt
      ]) {
        Language language = new Language();
        language.decimalSeparator = trimmed(record.Decimal_Separator__c);
        language.months = compileMonths(record.Month_Names__c);
        languageCache.put(record.DeveloperName.toLowerCase(), language);
      }
    }
    return languageCache;
  }

  /**
   * Normalises a metadata value, treating blank as absent.
   *
   * @param value Field value read from custom metadata.
   * @return Trimmed value, or null when it holds nothing.
   */
  private static String trimmed(String value) {
    return String.isBlank(value) ? null : value.trim();
  }

  /**
   * Compiles a Month_Names__c spec into folded spellings per month.
   *
   * Reads "Januar|Februar|März,Maerz,Mrz|…". Anything that is not twelve
   * complete months is ignored here, and the loader reports it.
   *
   * @param monthNames Pipe-separated months, each a comma-separated list
   *        of spellings.
   * @return Twelve alias lists, or empty when the spec is unusable.
   */
  @TestVisible
  private static List<List<String>> compileMonths(String monthNames) {
    List<List<String>> months = new List<List<String>>();
    if (String.isBlank(monthNames)) {
      return months;
    }
    List<String> entries = monthNames.trim().split('\\|');
    if (entries.size() != 12) {
      return new List<List<String>>();
    }
    for (String entry : entries) {
      List<String> aliases = new List<String>();
      for (String alias : entry.split(',')) {
        String folded = fold(alias);
        if (String.isNotBlank(folded)) {
          aliases.add(folded);
        }
      }
      if (aliases.isEmpty()) {
        return new List<List<String>>(); // an empty slot makes the row unusable
      }
      months.add(aliases);
    }
    return months;
  }

  /**
   * Reduces a month name to its comparison form.
   *
   * Trimmed, lowercased, stripped of a trailing abbreviation dot, and with
   * accents removed so "März" and "MARZ" meet. Accents are dropped, not
   * expanded — a language whose documents spell "Maerz" lists that
   * spelling explicitly.
   *
   * @param text Month name as written in the document or in metadata.
   * @return Folded form, empty string when nothing was supplied.
   */
  @TestVisible
  private static String fold(String text) {
    if (String.isBlank(text)) {
      return '';
    }
    String lower = text.trim().toLowerCase().removeEnd('.').trim();
    if (Pattern.matches('[a-z]*', lower)) {
      return lower; // the overwhelmingly common case, untouched
    }
    List<String> folded = new List<String>();
    for (Integer i = 0; i < lower.length(); i++) {
      String c = lower.substring(i, i + 1);
      String replacement = FOLDING.get(c);
      folded.add(replacement == null ? c : replacement);
    }
    return String.join(folded, '');
  }

  /** base:variants; groups separated by ";". */
  private static final String FOLDING_SPEC =
    'a:àáâãäåāăą;c:çćĉčċ;d:ďđð;e:èéêëēĕėęě;g:ĝğġģ;h:ĥħ;i:ìíîïĩīĭįı;' +
    'j:ĵ;k:ķ;l:ĺļľŀł;n:ñńņňŉ;o:òóôõöøōŏő;r:ŕŗř;s:śŝşšſ;t:ţťŧț;' +
    'u:ùúûüũūŭůűų;w:ŵ;y:ýÿŷ;z:źżž;ss:ß;ae:æ;oe:œ;th:þ;' +
    'α:ά;ε:έ;η:ή;ι:ίϊΐ;ο:ό;υ:ύϋΰ;ω:ώ;σ:ς;е:ё';

  /** Accented character to base character, compiled from the spec. */
  private static final Map<String, String> FOLDING = buildFolding();

  /**
   * Expands the folding spec into a per-character lookup.
   *
   * @return Map from each accented character to its base form.
   */
  private static Map<String, String> buildFolding() {
    // NB: no local here may be named "group" — Apex reserves it for SOQL.
    Map<String, String> folding = new Map<String, String>();
    for (String rule : FOLDING_SPEC.split(';')) {
      String base = rule.substringBefore(':');
      String variants = rule.substringAfter(':');
      for (Integer i = 0; i < variants.length(); i++) {
        folding.put(variants.substring(i, i + 1), base);
      }
    }
    return folding;
  }

  /** Last-resort month names. Declared last: compileMonths folds, and the
   *  folding map must already exist. */
  private static final List<List<String>> FALLBACK_ENGLISH_MONTHS = compileMonths(
    'January|February|March|April|May|June|July|August|September|October|November|December'
  );
}
