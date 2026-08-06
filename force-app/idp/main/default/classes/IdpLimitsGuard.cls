/**
 * Governor-limit headroom checks. The engine asks before starting a run;
 * when the transaction is too close to its limits the documents are
 * deferred (reported, rerunnable) instead of blowing up mid-write.
 */
public inherited sharing class IdpLimitsGuard {
  private static final Integer QUERY_BUFFER = 5;
  private static final Integer DML_BUFFER = 2;

  /** Test hook: pretend this many queries remain. */
  @TestVisible
  private static Integer testQueryHeadroom;

  public static Boolean hasQueryHeadroom(Integer needed) {
    Integer remaining = testQueryHeadroom != null
      ? testQueryHeadroom
      : Limits.getLimitQueries() - Limits.getQueries() - QUERY_BUFFER;
    return needed <= remaining;
  }

  public static Boolean hasDmlHeadroom() {
    return Limits.getDmlStatements() + DML_BUFFER <=
      Limits.getLimitDmlStatements();
  }
}
