/**
 * Unit tests for token binding: document values become bind variables
 * (never concatenated SOQL), templates render row keys, and whole numbers
 * never pick up a decimal point on the way into a key.
 */
@IsTest
private class IdpFilterBinderTest {
  /** Sample document the tokens are resolved against. */
  private static final Map<String, Object> ROOT = new Map<String, Object>{
    'policy' => new Map<String, Object>{ 'number' => 'POL-9' },
    'Invoice' => 'A1'
  };

  /**
   * Verifies that a document value reaches the query as a bind variable.
   */
  @IsTest
  static void bindsDocumentValuesInsteadOfConcatenating() {
    Map<String, Object> binds = new Map<String, Object>();
    String bound = IdpFilterBinder.bindFilter(
      'Status__c = \'Active\' AND Policy_Number__c = {json:policy.number}',
      ROOT,
      null,
      null,
      binds
    );
    Assert.areEqual(
      'Status__c = \'Active\' AND Policy_Number__c = :boundValue0',
      bound
    );
    Assert.areEqual('POL-9', binds.get('boundValue0'));
  }

  /**
   * Verifies that a token appearing twice takes a single bind variable.
   */
  @IsTest
  static void repeatedTokensBindOnce() {
    Map<String, Object> binds = new Map<String, Object>{ 'seed' => 1 };
    String bound = IdpFilterBinder.bindFilter(
      'A__c = {json:Invoice} OR B__c = {json:Invoice}',
      ROOT,
      null,
      null,
      binds
    );
    Assert.areEqual('A__c = :boundValue1 OR B__c = :boundValue1', bound);
  }

  /**
   * Verifies row key rendering: whole numbers stay whole and an
   * unresolvable token yields no key at all.
   */
  @IsTest
  static void rendersRowTemplates() {
    Map<String, Object> row = new Map<String, Object>{ 'Qty' => 2.0 };
    Assert.areEqual(
      'INV-A1-3',
      IdpFilterBinder.renderTemplate(
        'INV-{json:Invoice}-{row:number}',
        ROOT,
        row,
        2
      )
    );
    Assert.areEqual(
      '2-of-2',
      IdpFilterBinder.renderTemplate('{row:Qty}-of-{row:Qty}', ROOT, row, 0),
      'whole numbers render without a decimal point'
    );
    Assert.isNull(
      IdpFilterBinder.renderTemplate('X-{row:Missing}', ROOT, row, 0),
      'an incomplete key is no key'
    );
  }

  /**
   * Verifies that only filters carrying tokens count as document-bound.
   */
  @IsTest
  static void detectsDocumentReferences() {
    Assert.isTrue(IdpFilterBinder.referencesDocument('X = {json:a.b}'));
    Assert.isTrue(IdpFilterBinder.referencesDocument('X = {row:n}'));
    Assert.isFalse(IdpFilterBinder.referencesDocument('Status = \'Active\''));
    Assert.isFalse(IdpFilterBinder.referencesDocument(null));
  }
}
