/**
 * Tests for the configurator's server side. The Metadata API deployment
 * itself cannot run in a test context, so saveSet() short-circuits there;
 * what is worth asserting is everything around it — that a definition is
 * checked before it is sent, and that reads survive bad stored JSON.
 */
@IsTest
private class IdpConfiguratorControllerTest {
  private static final String GOOD =
    '{"sections":[{"name":"Header","label":"Header","sectionType":"Fixed",' +
    '"targetObject":"Case","rules":[{"name":"Email","jsonPath":"a",' +
    '"targetField":"SuppliedEmail"}]}]}';

  @IsTest
  static void listsSetsWithSectionAndRuleCounts() {
    List<IdpConfiguratorController.SetSummary> sets = IdpConfiguratorController.listSets();
    // The org seed ships two sample sets; assert the shape, not the count,
    // so adding a sample does not break this.
    for (IdpConfiguratorController.SetSummary summary : sets) {
      Assert.isNotNull(summary.name);
      Assert.isNotNull(summary.label);
      Assert.isTrue(
        summary.ruleCount >= 0,
        summary.name + ' reported a negative rule count'
      );
    }
  }

  @IsTest
  static void checkReturnsNothingForACleanDefinition() {
    Assert.areEqual(
      0,
      IdpConfiguratorController.check('Any_Set', GOOD).size(),
      'a definition naming real fields loads cleanly'
    );
  }

  @IsTest
  static void checkReportsAnUnknownField() {
    List<IdpConfiguratorController.Finding> findings = IdpConfiguratorController.check(
      'Any_Set',
      '{"sections":[{"name":"H","targetObject":"Case","rules":' +
      '[{"name":"R","jsonPath":"a","targetField":"Not_A_Field__c"}]}]}'
    );
    Assert.areEqual(1, findings.size());
    Assert.isTrue(findings[0].message.contains('Not_A_Field__c'));
  }

  @IsTest
  static void checkReportsUnreadableJsonAsAnError() {
    List<IdpConfiguratorController.Finding> findings = IdpConfiguratorController.check(
      'Any_Set',
      '{"sections": [ ,, ]'
    );
    Assert.areEqual(1, findings.size());
    Assert.areEqual(IdpResult.SEV_ERROR, findings[0].severity);
  }

  @IsTest
  static void readingAnUnknownSetIsAHandledError() {
    try {
      IdpConfiguratorController.readSet('No_Such_Set_Anywhere');
      Assert.fail('expected an AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void readingASeededSetReturnsTidyJsonAndItsSchema() {
    List<IdpConfiguratorController.SetSummary> sets = IdpConfiguratorController.listSets();
    if (sets.isEmpty()) {
      return; // an org with no mapping sets has nothing to assert
    }
    IdpConfiguratorController.SetDetail detail = IdpConfiguratorController.readSet(
      sets[0].name
    );
    Assert.areEqual(sets[0].name, detail.name);
    Assert.isTrue(
      detail.definition.contains('sections'),
      'the stored definition is returned re-indented'
    );
    Assert.isTrue(
      detail.definition.contains('\n'),
      'prettified, so the editor opens on readable text'
    );
    for (IdpConfiguratorController.ObjectFields entry : detail.schema) {
      Assert.isFalse(
        entry.fields.isEmpty(),
        entry.objectName + ' resolved no fields'
      );
    }
  }

  @IsTest
  static void saveRefusesADefinitionThatWillNotLoad() {
    IdpConfiguratorController.deployAllowedOverride = true;
    try {
      IdpConfiguratorController.saveSet('Estate_Intake', '{"sections": [ ,, ]');
      Assert.fail('expected the save to be refused');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void saveRefusesAnUnknownSet() {
    IdpConfiguratorController.deployAllowedOverride = true;
    try {
      IdpConfiguratorController.saveSet('No_Such_Set_Anywhere', GOOD);
      Assert.fail('expected the save to be refused');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void saveRefusesWithoutThePermission() {
    IdpConfiguratorController.deployAllowedOverride = false;
    try {
      IdpConfiguratorController.saveSet('Estate_Intake', GOOD);
      Assert.fail('expected the save to be refused');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void saveEnqueuesADeploymentForAValidDefinition() {
    List<IdpConfiguratorController.SetSummary> sets = IdpConfiguratorController.listSets();
    if (sets.isEmpty()) {
      return;
    }
    IdpConfiguratorController.deployAllowedOverride = true;
    // The Metadata API deployment itself cannot run in a test context, so
    // saveSet short-circuits after building the container. Everything up to
    // that point — the gate, the check, the record lookup — is real.
    Assert.areEqual(
      'TEST-DEPLOYMENT',
      IdpConfiguratorController.saveSet(sets[0].name, GOOD)
    );
  }

  @IsTest
  static void warningsDoNotBlockASave() {
    List<IdpConfiguratorController.SetSummary> sets = IdpConfiguratorController.listSets();
    if (sets.isEmpty()) {
      return;
    }
    IdpConfiguratorController.deployAllowedOverride = true;
    // An unknown field is a warning, not an error: staging a rule ahead of
    // the field it needs is a normal thing for an admin to be doing.
    String withWarning =
      '{"sections":[{"name":"H","targetObject":"Case","rules":' +
      '[{"name":"R","jsonPath":"a","targetField":"Not_A_Field__c"}]}]}';
    Assert.areEqual(
      'TEST-DEPLOYMENT',
      IdpConfiguratorController.saveSet(sets[0].name, withWarning)
    );
  }

  @IsTest
  static void fieldsOfListsAccessibleFieldsAndToleratesJunk() {
    List<IdpConfiguratorController.FieldOption> fields = IdpConfiguratorController.fieldsOf(
      'Case'
    );
    Map<String, IdpConfiguratorController.FieldOption> byApi = new Map<String, IdpConfiguratorController.FieldOption>();
    for (IdpConfiguratorController.FieldOption option : fields) {
      byApi.put(option.value, option);
    }
    Assert.isTrue(byApi.containsKey('SuppliedEmail'));
    Assert.isTrue(
      byApi.get('SuppliedEmail').label.contains('SuppliedEmail'),
      'the label carries the API name so an admin can recognise it'
    );
    Assert.isTrue(
      byApi.get('SuppliedEmail').updateable,
      'a writable field is offered as a rule target'
    );
    Assert.isFalse(
      byApi.get('Id').updateable,
      'Id is readable but never a rule target'
    );
    for (Integer i = 1; i < fields.size(); i++) {
      // compareTo, not <=, because the sort uses compareTo and the two
      // disagree on case.
      Assert.isTrue(
        fields[i - 1].label.compareTo(fields[i].label) <= 0,
        'the picker arrives sorted: ' +
          fields[i - 1].label +
          ' then ' +
          fields[i].label
      );
    }
    Assert.areEqual(
      0,
      IdpConfiguratorController.fieldsOf('No_Such_Object__c').size(),
      'an unknown object yields nothing rather than throwing'
    );
  }

  @IsTest
  static void pickersReturnObjectsAndValueTypes() {
    // EntityDefinition cannot be paged with queryMore(), so pickers() walks
    // it by keyset. This asserts the walk's two failure modes — a repeated
    // page, and a page that starts over — neither of which shows up in an
    // org small enough to fit in one batch.
    IdpConfiguratorController.PickerData data = IdpConfiguratorController.pickers();
    Assert.isFalse(data.objects.isEmpty(), 'the object picker needs a list');
    Boolean sawCase = false;
    Set<String> seen = new Set<String>();
    String previous = '';
    for (IdpConfiguratorController.Option option : data.objects) {
      if (option.value == 'Case') {
        sawCase = true;
        Assert.isTrue(option.label.contains('Case'));
      }
      Assert.isTrue(
        seen.add(option.value),
        option.value + ' was listed twice: the keyset walk repeated a page'
      );
      // Lowercased because SOQL orders and compares strings without regard
      // to case, and the keyset walk leans on that: ORDER BY and the `>`
      // that resumes each page share one collation. Comparing with a
      // case-sensitive compareTo here would fail on honestly-ordered rows.
      Assert.isTrue(
        previous.toLowerCase().compareTo(option.value.toLowerCase()) < 0,
        'the walk must stay ordered: ' + previous + ' then ' + option.value
      );
      previous = option.value;
    }
    Assert.isTrue(sawCase, 'Case is customizable and queryable in every org');
    for (IdpConfiguratorController.Option option : data.valueTypes) {
      Assert.isNotNull(option.value);
      Assert.isNotNull(option.label);
    }
  }
}
