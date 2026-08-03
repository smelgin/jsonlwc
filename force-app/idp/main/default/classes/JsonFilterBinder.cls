/**
 * Turns a configured SOQL fragment or value template into something safe to
 * run: {json:path} tokens are replaced with values read from the reviewed
 * document, and {row:...} tokens with values from the current row.
 *
 * Two entry points, because the two uses differ in what "safe" means:
 *
 *  - bindFilter() is for WHERE fragments. Document values become bind
 *    variables, never concatenated text, so content extracted from a file
 *    cannot inject SOQL. The fragment around them is metadata written by
 *    whoever deploys the mapping set.
 *  - renderTemplate() is for values (a row's Match Value). There is no query
 *    to inject into, so tokens are substituted textually; the result is
 *    itself passed to SOQL later as a bind variable.
 *
 * Tokens:
 *   {json:path}    read from the document root  (applicant.name, a.b[0].c)
 *   {row:path}     read from the current row    (Quantity)
 *   {row:index}    0-based position of the row
 *   {row:number}   1-based position of the row
 */
public inherited sharing class JsonFilterBinder {
  private static final Pattern TOKEN = Pattern.compile(
    '\\{(json|row):([^}]+)\\}'
  );

  /**
   * Replaces every token in a WHERE fragment with a bind variable, adding
   * the value to binds. Returns the rewritten fragment.
   */
  public static String bindFilter(
    String fragment,
    Object jsonRoot,
    Object row,
    Integer rowIndex,
    Map<String, Object> binds
  ) {
    if (String.isBlank(fragment)) {
      return fragment;
    }
    String processed = fragment;
    Matcher matcher = TOKEN.matcher(fragment);
    Integer counter = binds.size();
    while (matcher.find()) {
      String token = matcher.group(0);
      if (!processed.contains(token)) {
        continue; // repeated token, already replaced
      }
      String bindName = 'boundValue' + counter;
      binds.put(
        bindName,
        resolveToken(
          matcher.group(1),
          matcher.group(2),
          jsonRoot,
          row,
          rowIndex
        )
      );
      processed = processed.replace(token, ':' + bindName);
      counter++;
    }
    return processed;
  }

  /** Replaces every token with its value as text. Returns null when the
   *  template is blank or any token resolves to nothing, so callers can
   *  treat an incomplete key as "no key". */
  public static String renderTemplate(
    String template,
    Object jsonRoot,
    Object row,
    Integer rowIndex
  ) {
    if (String.isBlank(template)) {
      return null;
    }
    String processed = template;
    Matcher matcher = TOKEN.matcher(template);
    while (matcher.find()) {
      String token = matcher.group(0);
      if (!processed.contains(token)) {
        continue;
      }
      Object value = resolveToken(
        matcher.group(1),
        matcher.group(2),
        jsonRoot,
        row,
        rowIndex
      );
      if (value == null) {
        return null;
      }
      processed = processed.replace(token, stringify(value));
    }
    return processed;
  }

  private static Object resolveToken(
    String scope,
    String path,
    Object jsonRoot,
    Object row,
    Integer rowIndex
  ) {
    if (scope == 'json') {
      return JsonPathReader.read(jsonRoot, path);
    }
    if (path == 'index') {
      return rowIndex;
    }
    if (path == 'number') {
      return rowIndex == null ? null : rowIndex + 1;
    }
    return JsonPathReader.read(row, path);
  }

  /** Whole numbers must not pick up a decimal point on the way into a key:
   *  line 2 is "2", never "2.0". */
  private static String stringify(Object value) {
    if (value instanceof Decimal) {
      Decimal numeric = (Decimal) value;
      if (numeric == numeric.round()) {
        return String.valueOf(numeric.longValue());
      }
    }
    return String.valueOf(value);
  }
}
