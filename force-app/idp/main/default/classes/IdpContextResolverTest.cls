/**
 * Tests for bulk anchor resolution: several documents resolve in a fixed
 * number of queries, parent and child hops walk the one lookup joining
 * two objects, explicit hops keep one anchor per section, and a document
 * can be seeded from a record instead of a file.
 */
@IsTest
private class IdpContextResolverTest {
  private static IdpContextResolver.DocContext docFor(Id contentDocumentId) {
    IdpContextResolver.DocContext doc = new IdpContextResolver.DocContext();
    doc.contentDocumentId = contentDocumentId;
    return doc;
  }

  private static Map<String, IdpContextResolver.AnchorSpec> requests(
    Map<String, List<String>> fieldsByObject
  ) {
    Map<String, IdpContextResolver.AnchorSpec> specs = new Map<String, IdpContextResolver.AnchorSpec>();
    for (String objectName : fieldsByObject.keySet()) {
      IdpContextResolver.AnchorSpec spec = new IdpContextResolver.AnchorSpec();
      spec.fields.addAll(fieldsByObject.get(objectName));
      specs.put(objectName, spec);
    }
    return specs;
  }

  @IsTest
  static void resolvesSeveralDocumentsInConstantQueries() {
    IdpTestData.CaseWithFile first = IdpTestData.caseWithFile('One', '1');
    IdpTestData.CaseWithFile second = IdpTestData.caseWithFile('Two', '2');
    List<IdpContextResolver.DocContext> docs = new List<IdpContextResolver.DocContext>{
      docFor(first.contentDocumentId),
      docFor(second.contentDocumentId)
    };

    Test.startTest();
    Integer before = Limits.getQueries();
    IdpContextResolver.resolveAll(
      docs,
      requests(
        new Map<String, List<String>>{
          'Case' => new List<String>{ 'SuppliedName' },
          'Account' => new List<String>{ 'Phone' }
        }
      )
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(
      first.caseRecord.Id,
      docs[0].anchors.get('Case').Id,
      'each document anchors its own Case'
    );
    Assert.areEqual(second.caseRecord.Id, docs[1].anchors.get('Case').Id);
    Assert.areEqual(
      first.account.Id,
      docs[0].anchors.get('Account').Id,
      'Account reached by parent hop from the Case'
    );
    Assert.areEqual(second.account.Id, docs[1].anchors.get('Account').Id);
    Assert.isTrue(
      used <= 3,
      'links + cases + accounts should be 3 grouped queries, used ' + used
    );
  }

  @IsTest
  static void resolvesChildHopToNewestChild() {
    Account account = new Account(Name = 'Holder');
    insert account;
    Case older = new Case(AccountId = account.Id, Subject = 'Old');
    insert older;
    Case newer = new Case(AccountId = account.Id, Subject = 'New');
    insert newer;
    Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));
    Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));
    Id fileId = IdpTestData.linkFile(account.Id, 'On the account');

    List<IdpContextResolver.DocContext> docs = new List<IdpContextResolver.DocContext>{
      docFor(fileId)
    };
    Test.startTest();
    IdpContextResolver.resolveAll(
      docs,
      requests(
        new Map<String, List<String>>{ 'Case' => new List<String>{ 'Subject' } }
      )
    );
    Test.stopTest();

    Assert.areEqual(
      newer.Id,
      docs[0].anchors.get('Case').Id,
      'the newest child wins, as in v1'
    );
  }

  @IsTest
  static void seedsFromARecordWithoutAFile() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpContextResolver.DocContext doc = new IdpContextResolver.DocContext();
    doc.seedRecordId = data.caseRecord.Id; // no contentDocumentId at all

    Test.startTest();
    IdpContextResolver.resolveAll(
      new List<IdpContextResolver.DocContext>{ doc },
      requests(
        new Map<String, List<String>>{
          'Case' => new List<String>{ 'Subject' },
          'Account' => new List<String>{ 'Phone' }
        }
      )
    );
    Test.stopTest();

    Assert.areEqual(data.caseRecord.Id, doc.anchors.get('Case').Id);
    Assert.areEqual(
      data.account.Id,
      doc.anchors.get('Account').Id,
      'hops keep working from a seeded record — the batch entry path'
    );
  }

  @IsTest
  static void appliesDocumentBoundFiltersPerDocument() {
    IdpTestData.CaseWithFile match = IdpTestData.caseWithFile('M', '111');
    IdpTestData.CaseWithFile miss = IdpTestData.caseWithFile('X', '222');

    Map<String, IdpContextResolver.AnchorSpec> specs = requests(
      new Map<String, List<String>>{
        'Case' => new List<String>{ 'Subject' },
        'Account' => new List<String>{ 'Phone' }
      }
    );
    specs.get('Account').filter = 'Phone = {json:phone}';

    IdpContextResolver.DocContext matching = docFor(match.contentDocumentId);
    matching.jsonRoot = new Map<String, Object>{ 'phone' => '111' };
    IdpContextResolver.DocContext missing = docFor(miss.contentDocumentId);
    missing.jsonRoot = new Map<String, Object>{ 'phone' => 'nope' };

    Test.startTest();
    IdpContextResolver.resolveAll(
      new List<IdpContextResolver.DocContext>{ matching, missing },
      specs
    );
    Test.stopTest();

    Assert.areEqual(
      match.account.Id,
      matching.anchors.get('Account').Id,
      'the filter binds this document\'s phone value'
    );
    Assert.isFalse(
      missing.anchors.containsKey('Account'),
      'a filter that matches nothing anchors nothing'
    );
  }

  @IsTest
  static void explicitHopsKeepTwoAnchorsOfOneObject() {
    Account owner = new Account(Name = 'Owner');
    Account servicer = new Account(Name = 'Servicer');
    insert new List<Account>{ owner, servicer };
    Asset asset = new Asset(
      Name = 'Fund',
      AccountId = owner.Id,
      AssetServicedById = servicer.Id
    );
    insert asset;
    IdpContextResolver.DocContext doc = docFor(
      IdpTestData.linkFile(asset.Id, 'Statement')
    );

    IdpContextResolver.Plan plan = new IdpContextResolver.Plan();
    // Implicit Account: three lookups from Asset, so never guessed.
    plan.byObject.put('Account', new IdpContextResolver.AnchorSpec());
    plan.bySection.put(
      'Owner',
      explicitSpec('Account', 'Asset', 'AccountId', false)
    );
    plan.bySection.put(
      'Servicer',
      explicitSpec('Account', 'Asset', 'AssetServicedById', false)
    );
    plan.sectionOrder.addAll(new List<String>{ 'Owner', 'Servicer' });

    Test.startTest();
    IdpContextResolver.resolveAll(
      new List<IdpContextResolver.DocContext>{ doc },
      plan
    );
    Test.stopTest();

    Assert.areEqual(owner.Id, doc.anchorsBySection.get('Owner').Id);
    Assert.areEqual(servicer.Id, doc.anchorsBySection.get('Servicer').Id);
    Assert.isFalse(
      doc.anchors.containsKey('Account'),
      'the implicit walk does not pick one of several lookups'
    );
    Assert.isTrue(
      doc.ambiguities.get('Account').contains('AssetServicedById'),
      'and says which lookups competed: ' + doc.ambiguities
    );
    Assert.areEqual(owner.Id, doc.anchorFor('Owner').Id);
    Assert.areEqual(asset.Id, doc.anchorFor('Asset').Id, 'pool fallback');
  }

  @IsTest
  static void explicitChildHopChainsFromAnExplicitSection() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Asset holding = new Asset(Name = 'Fund', AccountId = data.account.Id);
    insert holding;
    IdpContextResolver.DocContext doc = docFor(data.contentDocumentId);

    IdpContextResolver.Plan plan = new IdpContextResolver.Plan();
    // Case (root) --AccountId--> Account (section Holder)
    //   --Asset.AccountId (child hop)--> Asset (section Holding)
    plan.bySection.put(
      'Holder',
      explicitSpec('Account', 'Case', 'AccountId', false)
    );
    plan.bySection.put(
      'Holding',
      explicitSpec('Asset', 'Holder', 'AccountId', true)
    );
    plan.sectionOrder.addAll(new List<String>{ 'Holder', 'Holding' });

    Test.startTest();
    Integer before = Limits.getQueries();
    IdpContextResolver.resolveAll(
      new List<IdpContextResolver.DocContext>{ doc },
      plan
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(data.account.Id, doc.anchorsBySection.get('Holder').Id);
    Assert.areEqual(holding.Id, doc.anchorsBySection.get('Holding').Id);
    Assert.isTrue(
      used <= 4,
      'links + case root + two explicit hops in one pass; used ' + used
    );
  }

  private static IdpContextResolver.AnchorSpec explicitSpec(
    String objectName,
    String sourceKey,
    String relationshipField,
    Boolean childHop
  ) {
    IdpContextResolver.AnchorSpec spec = new IdpContextResolver.AnchorSpec();
    spec.objectName = objectName;
    spec.sourceKey = sourceKey;
    spec.relationshipField = relationshipField;
    spec.childHop = childHop;
    return spec;
  }

  @IsTest
  static void hubObjectExpandsTheNamedRootsLookups() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpContextResolver.DocContext doc = docFor(data.contentDocumentId);
    IdpContextResolver.Plan plan = new IdpContextResolver.Plan();
    plan.hubObject = 'Case'; // nothing is requested; the hub alone drives it

    Test.startTest();
    IdpContextResolver.resolveAll(
      new List<IdpContextResolver.DocContext>{ doc },
      plan
    );
    Test.stopTest();

    Assert.areEqual(data.caseRecord.Id, doc.anchors.get('Case').Id);
    Assert.areEqual(
      data.account.Id,
      doc.anchors.get('Account').Id,
      'the hub\'s AccountId parent is anchored as a stepping stone'
    );
  }

  @IsTest
  static void ignoresSystemLinkTypes() {
    // A file in a library is linked to a ContentWorkspace; only the record
    // link should anchor.
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    List<IdpContextResolver.DocContext> docs = new List<IdpContextResolver.DocContext>{
      docFor(data.contentDocumentId)
    };
    Test.startTest();
    IdpContextResolver.resolveAll(
      docs,
      requests(
        new Map<String, List<String>>{ 'Case' => new List<String>{ 'Subject' } }
      )
    );
    Test.stopTest();
    Assert.isFalse(docs[0].anchors.containsKey('User'));
    Assert.areEqual(data.caseRecord.Id, docs[0].anchors.get('Case').Id);
  }
}
