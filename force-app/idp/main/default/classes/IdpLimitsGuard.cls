/**
 * Governor-limit headroom checks. The engine asks before starting a run;
 * when the transaction is too close to its limits the documents are
 * deferred (reported, rerunnable) instead of blowing up mid-write.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpLimitsGuard {
  /** Queries held back for callers that run after the engine. */
  private static final Integer QUERY_BUFFER = 5;

  /** DML statements held back for callers that run after the engine. */
  private static final Integer DML_BUFFER = 2;

  /** Test hook: pretend this many queries remain. */
  @TestVisible
  private static Integer testQueryHeadroom;

  /**
   * Reports whether the transaction can still afford the planned queries.
   *
   * @param needed Number of queries the caller is about to issue.
   * @return True when the queries fit inside the remaining budget.
   */
  public static Boolean hasQueryHeadroom(Integer needed) {
    Integer remaining = testQueryHeadroom != null
      ? testQueryHeadroom
      : Limits.getLimitQueries() - Limits.getQueries() - QUERY_BUFFER;
    return needed <= remaining;
  }

  /**
   * Reports whether another DML statement still fits in the transaction.
   *
   * @return True when a further DML statement stays inside the budget.
   */
  public static Boolean hasDmlHeadroom() {
    return Limits.getDmlStatements() + DML_BUFFER <=
      Limits.getLimitDmlStatements();
  }
}
