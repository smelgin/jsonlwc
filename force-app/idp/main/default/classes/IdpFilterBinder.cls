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
 *
 * Reads go through IdpJsonReader, so confidence envelopes are transparent
 * here too.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpFilterBinder {
  /** Matches a {json:...} or {row:...} token and captures scope and path. */
  private static final Pattern TOKEN = Pattern.compile(
    '\\{(json|row):([^}]+)\\}'
  );

  /**
   * Rewrites a WHERE fragment so every token becomes a bind variable.
   *
   * Document values never reach the query as text, so content extracted
   * from a file cannot inject SOQL.
   *
   * @param fragment Configured WHERE fragment, possibly containing tokens.
   * @param jsonRoot Reviewed document, the root for {json:...} reads.
   * @param row Current row, the root for {row:...} reads.
   * @param rowIndex 0-based row position, backing {row:index} and
   *        {row:number}.
   * @param binds Bind map the resolved values are added to.
   * @return Fragment with each token replaced by its bind variable.
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

  /**
   * Substitutes every token in a value template with its text form.
   *
   * A blank template, or any token that resolves to nothing, yields null so
   * callers can treat an incomplete key as "no key".
   *
   * @param template Configured value template, such as a row Match Value.
   * @param jsonRoot Reviewed document, the root for {json:...} reads.
   * @param row Current row, the root for {row:...} reads.
   * @param rowIndex 0-based row position, backing {row:index} and
   *        {row:number}.
   * @return Rendered text, or null when the template cannot be completed.
   */
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

  /**
   * Reports whether a fragment reads document values.
   *
   * Such filters bind per-document values and so cannot share a grouped
   * query with other documents in the run.
   *
   * @param fragment Configured WHERE fragment to inspect.
   * @return True when the fragment contains at least one token.
   */
  public static Boolean referencesDocument(String fragment) {
    return String.isNotBlank(fragment) && TOKEN.matcher(fragment).find();
  }

  /**
   * Reads the value one token stands for.
   *
   * @param scope Token scope, either json or row.
   * @param path Path within that scope, or the index/number keyword.
   * @param jsonRoot Reviewed document, the root for json reads.
   * @param row Current row, the root for row reads.
   * @param rowIndex 0-based row position.
   * @return Value behind the token, null when the path is absent.
   */
  private static Object resolveToken(
    String scope,
    String path,
    Object jsonRoot,
    Object row,
    Integer rowIndex
  ) {
    if (scope == 'json') {
      return IdpJsonReader.read(jsonRoot, path);
    }
    if (path == 'index') {
      return rowIndex;
    }
    if (path == 'number') {
      return rowIndex == null ? null : rowIndex + 1;
    }
    return IdpJsonReader.read(row, path);
  }

  /**
   * Renders a resolved token value as key text.
   *
   * Whole numbers must not pick up a decimal point on the way into a key:
   * line 2 is "2", never "2.0".
   *
   * @param value Resolved token value.
   * @return Text form safe to embed in a match key.
   */
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
