/**
 * The IDP mapping engine: applies one mapping set to a list of documents
 * in a single bulk pass. Orchestration only — configuration loading
 * (IdpConfigLoader), anchor resolution (IdpContextResolver), rule
 * evaluation (IdpRuleEvaluator) and DML (IdpDmlExecutor) each live in
 * their own class.
 *
 * Modes:
 *  - Extraction  writes extracted values into the anchored records
 *  - Compliance  writes nothing; compares through the value types and
 *                reports Match / Near / Mismatch per field
 *  - Preview     the full Extraction pipeline with the final DML skipped;
 *                each Result carries plannedChanges (old → new per field)
 *
 * A rule's Mode overrides the run's per field (Extraction/Compliance).
 * Cost model: one ContentDocumentLink query for the run, grouped anchor
 * queries per object, one query per repeating section group, and at most
 * one update DML — query count does not scale with rule or row count.
 */
public inherited sharing class IdpMappingEngine {
  public static final String MODE_EXTRACTION = 'Extraction';
  public static final String MODE_COMPLIANCE = 'Compliance';
  public static final String MODE_PREVIEW = 'Preview';

  /** One document in, one Result out. Seed either a file
   *  (contentDocumentId) or a record (seedRecordId — the batch path). */
  public class DocumentWork {
    public Id contentDocumentId;
    public Id seedRecordId;
    public String jsonString;

    private Object root;
    private IdpContextResolver.DocContext context;
    private IdpResult.Result result;
  }

  public static List<IdpResult.Result> run(
    List<DocumentWork> works,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    List<IdpResult.Result> results = new List<IdpResult.Result>();
    IdpConfigLoader.SetConfig config = IdpConfigLoader.load(mappingSetName);
    for (DocumentWork work : works) {
      work.result = new IdpResult.Result();
      work.result.contentDocumentId = asString(work.contentDocumentId);
      work.result.seedRecordId = asString(work.seedRecordId);
      results.add(work.result);
      for (IdpResult.Finding issue : config.issues) {
        work.result.add(issue.code, issue.severity, issue.message);
      }
    }
    if (!config.found) {
      return results;
    }

    String runMode = normalizeMode(
      String.isBlank(mode) ? config.defaultMode : mode
    );
    if (runMode == null) {
      for (DocumentWork work : works) {
        work.result.add(
          IdpResult.CODE_INVALID_MODE,
          IdpResult.SEV_ERROR,
          'Unknown mode "' +
            mode +
            '" — use "' +
            MODE_EXTRACTION +
            '", "' +
            MODE_COMPLIANCE +
            '" or "' +
            MODE_PREVIEW +
            '".'
        );
      }
      return results;
    }
    Boolean previewing = runMode == MODE_PREVIEW;

    List<DocumentWork> eligible = new List<DocumentWork>();
    for (DocumentWork work : works) {
      work.result.mode = runMode;
      if (work.contentDocumentId == null && work.seedRecordId == null) {
        work.result.add(
          IdpResult.CODE_INVALID_INPUT,
          IdpResult.SEV_ERROR,
          'Give each document a Content Document Id or a seed Record Id.'
        );
        continue;
      }
      try {
        work.root = JSON.deserializeUntyped(work.jsonString);
      } catch (Exception e) {
        work.result.add(
          IdpResult.CODE_JSON_INVALID,
          IdpResult.SEV_ERROR,
          'The JSON could not be parsed: ' + e.getMessage()
        );
        continue;
      }
      if (work.root == null) {
        work.result.add(
          IdpResult.CODE_JSON_INVALID,
          IdpResult.SEV_ERROR,
          'The JSON is empty.'
        );
        continue;
      }
      eligible.add(work);
    }
    if (eligible.isEmpty()) {
      return results;
    }

    Map<String, IdpContextResolver.AnchorSpec> requests = buildAnchorRequests(
      config
    );
    Integer estimate = 2 + requests.size() * 7 + config.sections.size();
    if (!IdpLimitsGuard.hasQueryHeadroom(estimate)) {
      for (DocumentWork work : eligible) {
        work.result.deferred = true;
        work.result.add(
          IdpResult.CODE_DOC_DEFERRED,
          IdpResult.SEV_ERROR,
          'Not enough governor-limit headroom remains in this transaction; rerun this document.'
        );
      }
      return results;
    }

    List<IdpContextResolver.DocContext> contexts = new List<IdpContextResolver.DocContext>();
    for (DocumentWork work : eligible) {
      work.context = new IdpContextResolver.DocContext();
      work.context.contentDocumentId = work.contentDocumentId;
      work.context.seedRecordId = work.seedRecordId;
      work.context.jsonRoot = work.root;
      contexts.add(work.context);
    }
    IdpContextResolver.resolveAll(contexts, requests);

    IdpDmlExecutor executor = new IdpDmlExecutor();
    for (DocumentWork work : eligible) {
      for (IdpConfigLoader.SectionConfig section : config.sections) {
        if (!section.repeating) {
          processFixedSection(section, work, runMode, previewing, executor);
        }
      }
    }
    for (IdpConfigLoader.SectionConfig section : config.sections) {
      if (section.repeating) {
        processRepeatingSection(
          section,
          config,
          eligible,
          runMode,
          previewing,
          executor
        );
      }
    }

    if (!previewing) {
      executor.flush();
    }
    for (IdpResult.Result result : results) {
      result.compliant = result.findingsWith(IdpResult.CODE_VALUE_MISMATCH)
        .isEmpty();
    }
    invokeFindingHandler(findingHandler, config, runMode, results);
    return results;
  }

  // ──────────────────────── fixed sections ────────────────────────

  private static void processFixedSection(
    IdpConfigLoader.SectionConfig section,
    DocumentWork work,
    String runMode,
    Boolean previewing,
    IdpDmlExecutor executor
  ) {
    if (section.rules.isEmpty()) {
      return;
    }
    SObject anchor = work.context.anchors.get(section.targetObject);
    if (anchor == null) {
      IdpResult.Finding finding = work.result.add(
        IdpResult.CODE_UNREACHABLE_TARGET,
        IdpResult.SEV_ERROR,
        'No ' +
          section.targetObject +
          ' record is reachable from this document — section ' +
          section.name +
          ' was skipped.'
      );
      finding.objectName = section.targetObject;
      finding.sectionName = section.name;
      return;
    }
    for (IdpConfigLoader.RuleConfig rule : section.rules) {
      IdpRuleEvaluator.apply(
        rule,
        effectiveMode(rule, runMode),
        previewing,
        work.root,
        anchor,
        section.targetObject,
        null,
        work.result,
        executor
      );
    }
  }

  // ────────────────────── repeating sections ──────────────────────

  /** One document's rows and keys for one repeating section. */
  private class DocRows {
    public DocumentWork work;
    public List<Object> rows;
    public List<String> keys = new List<String>();
    public Map<String, Integer> indexByKey = new Map<String, Integer>();
    public Id parentId;
    public String lookupField;
  }

  /**
   * Matches every document's rows against existing records with one query
   * per (lookup-field) group — a 200-line statement costs the same as a
   * 2-line invoice, and 10 statements cost the same as one. Rows are
   * matched and updated, never created; unmatched keys are data, not
   * errors.
   */
  private static void processRepeatingSection(
    IdpConfigLoader.SectionConfig section,
    IdpConfigLoader.SetConfig config,
    List<DocumentWork> works,
    String runMode,
    Boolean previewing,
    IdpDmlExecutor executor
  ) {
    String objectName = section.targetObject;
    String label = 'Section ' + section.name;
    Schema.SObjectField matchField = IdpSchemaCache.field(
      objectName,
      section.matchField
    );
    List<DocRows> allDocRows = new List<DocRows>();
    for (DocumentWork work : works) {
      DocRows docRows = collectRows(section, config, work, matchField, label);
      if (docRows != null) {
        allDocRows.add(docRows);
      }
    }
    if (allDocRows.isEmpty() || matchField == null) {
      return;
    }
    String matchFieldName = matchField.getDescribe().getName();

    // Group by lookup field (docs without a parent constraint group under
    // null) — one query per group.
    Map<String, List<DocRows>> groups = new Map<String, List<DocRows>>();
    for (DocRows docRows : allDocRows) {
      String groupKey = docRows.lookupField == null
        ? ''
        : docRows.lookupField;
      if (!groups.containsKey(groupKey)) {
        groups.put(groupKey, new List<DocRows>());
      }
      groups.get(groupKey).add(docRows);
    }

    for (String groupKey : groups.keySet()) {
      matchAndApplyGroup(
        section,
        groups.get(groupKey),
        String.isBlank(groupKey) ? null : groupKey,
        matchFieldName,
        runMode,
        previewing,
        executor,
        label
      );
    }
  }

  /** Reads and keys one document's rows; null when the document has no
   *  such region (not an error) or it is unusable (reported). */
  private static DocRows collectRows(
    IdpConfigLoader.SectionConfig section,
    IdpConfigLoader.SetConfig config,
    DocumentWork work,
    Schema.SObjectField matchField,
    String label
  ) {
    Object raw = IdpJsonReader.read(work.root, section.rowPath);
    if (raw == null) {
      return null;
    }
    if (matchField == null || !matchField.getDescribe().isAccessible()) {
      IdpResult.Finding finding = work.result.add(
        IdpResult.CODE_CONFIG_ISSUE,
        IdpResult.SEV_ERROR,
        label +
          ': Match Field ' +
          section.targetObject +
          '.' +
          section.matchField +
          ' does not exist or is not readable.'
      );
      finding.sectionName = section.name;
      return null;
    }
    if (!(raw instanceof List<Object>)) {
      IdpResult.Finding finding = work.result.add(
        IdpResult.CODE_ROW_LOOKUP_FAILED,
        IdpResult.SEV_ERROR,
        label + ': Row Path "' + section.rowPath + '" is not a list.'
      );
      finding.sectionName = section.name;
      return null;
    }
    List<Object> rows = (List<Object>) raw;
    if (rows.isEmpty()) {
      return null;
    }

    DocRows docRows = new DocRows();
    docRows.work = work;
    docRows.rows = rows;
    for (Integer i = 0; i < rows.size(); i++) {
      String key = IdpFilterBinder.renderTemplate(
        section.matchValue,
        work.root,
        rows[i],
        i
      );
      if (String.isBlank(key)) {
        IdpResult.Finding finding = work.result.add(
          IdpResult.CODE_ROW_LOOKUP_FAILED,
          IdpResult.SEV_ERROR,
          label + ': row ' + i + ' has no Match Value, so it was skipped.'
        );
        finding.sectionName = section.name;
        finding.rowIndex = i;
      } else if (docRows.indexByKey.containsKey(key)) {
        IdpResult.Finding finding = work.result.add(
          IdpResult.CODE_ROW_DUPLICATE_KEY,
          IdpResult.SEV_ERROR,
          label +
            ': rows ' +
            docRows.indexByKey.get(key) +
            ' and ' +
            i +
            ' produce the same Match Value "' +
            key +
            '"; row ' +
            i +
            ' was skipped.'
        );
        finding.sectionName = section.name;
        finding.rowIndex = i;
        finding.rowKey = key;
      } else {
        docRows.keys.add(key);
        docRows.indexByKey.put(key, i);
      }
    }
    if (docRows.keys.isEmpty()) {
      return null;
    }

    // Rows are constrained to the resolved parent record where a lookup
    // exists, so a key unique only within one account cannot reach
    // another account's rows.
    String parentObject = parentObjectFor(
      section,
      config,
      work.context.anchors
    );
    if (parentObject != null) {
      docRows.lookupField = IdpSchemaCache.findLookupTo(
        section.targetObject,
        parentObject
      );
      if (docRows.lookupField != null) {
        docRows.parentId = work.context.anchors.get(parentObject).Id;
      }
    }
    return docRows;
  }

  private static void matchAndApplyGroup(
    IdpConfigLoader.SectionConfig section,
    List<DocRows> docGroup,
    String lookupField,
    String matchFieldName,
    String runMode,
    Boolean previewing,
    IdpDmlExecutor executor,
    String label
  ) {
    String objectName = section.targetObject;
    Set<String> selected = new Set<String>{ 'Id', matchFieldName };
    if (lookupField != null) {
      selected.add(lookupField);
    }
    Map<String, Schema.SObjectField> described = IdpSchemaCache.fieldsOf(
      objectName
    );
    for (IdpConfigLoader.RuleConfig rule : section.rules) {
      Schema.SObjectField field = described.get(rule.targetField);
      if (field != null && field.getDescribe().isAccessible()) {
        selected.add(field.getDescribe().getName());
      }
    }
    if (
      UserInfo.isMultiCurrencyOrganization() &&
      described.get('CurrencyIsoCode') != null
    ) {
      selected.add('CurrencyIsoCode'); // for the currency guard
    }

    // Per-document queries only when the filter binds document values.
    Boolean docBound = IdpFilterBinder.referencesDocument(
      section.recordFilter
    );
    Map<String, SObject> recordsByKey = new Map<String, SObject>();
    if (docBound) {
      for (DocRows docRows : docGroup) {
        if (
          !queryRowsInto(
            recordsByKey,
            objectName,
            selected,
            matchFieldName,
            new Set<String>(docRows.keys),
            lookupField,
            docRows.parentId == null
              ? new Set<Id>()
              : new Set<Id>{ docRows.parentId },
            section.recordFilter,
            docRows.work.root,
            docRows.work.result,
            label
          )
        ) {
          return;
        }
      }
    } else {
      Set<String> allKeys = new Set<String>();
      Set<Id> parentIds = new Set<Id>();
      for (DocRows docRows : docGroup) {
        allKeys.addAll(docRows.keys);
        if (docRows.parentId != null) {
          parentIds.add(docRows.parentId);
        }
      }
      if (
        !queryRowsInto(
          recordsByKey,
          objectName,
          selected,
          matchFieldName,
          allKeys,
          lookupField,
          parentIds,
          section.recordFilter,
          null,
          docGroup[0].work.result,
          label
        )
      ) {
        return;
      }
    }

    for (DocRows docRows : docGroup) {
      for (String key : docRows.keys) {
        String bucketKey = docRows.lookupField == null
          ? key
          : docRows.parentId + '|' + key;
        SObject record = recordsByKey.get(bucketKey);
        Integer index = docRows.indexByKey.get(key);
        if (record == null) {
          docRows.work.result.unmatchedRowKeys.add(key);
          IdpResult.Finding finding = docRows.work.result.add(
            IdpResult.CODE_ROW_UNMATCHED,
            IdpResult.SEV_INFO,
            label +
              ': no ' +
              objectName +
              ' record matches key "' +
              key +
              '" (row ' +
              index +
              '). Rows are matched, never created.'
          );
          finding.sectionName = section.name;
          finding.rowIndex = index;
          finding.rowKey = key;
          continue;
        }
        docRows.work.result.rowsMatched++;
        IdpRuleEvaluator.RowInfo rowInfo = new IdpRuleEvaluator.RowInfo(
          section.name,
          index,
          key
        );
        for (IdpConfigLoader.RuleConfig rule : section.rules) {
          IdpRuleEvaluator.apply(
            rule,
            effectiveMode(rule, runMode),
            previewing,
            docRows.rows[index],
            record,
            objectName,
            rowInfo,
            docRows.work.result,
            executor
          );
        }
      }
    }
  }

  /** Runs one row-matching query and buckets results by key (and parent
   *  when constrained). Returns false when the query failed. */
  private static Boolean queryRowsInto(
    Map<String, SObject> recordsByKey,
    String objectName,
    Set<String> selected,
    String matchFieldName,
    Set<String> keys,
    String lookupField,
    Set<Id> parentIds,
    String filter,
    Object jsonRoot,
    IdpResult.Result reportTo,
    String label
  ) {
    Map<String, Object> binds = new Map<String, Object>{ 'keys' => keys };
    String whereClause = matchFieldName + ' IN :keys';
    if (lookupField != null && !parentIds.isEmpty()) {
      binds.put('parentIds', parentIds);
      whereClause += ' AND ' + lookupField + ' IN :parentIds';
    }
    if (String.isNotBlank(filter)) {
      whereClause +=
        ' AND (' +
        IdpFilterBinder.bindFilter(filter, jsonRoot, null, null, binds) +
        ')';
    }
    String soql =
      'SELECT ' +
      String.join(new List<String>(selected), ', ') +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause;
    try {
      for (
        SObject record : Database.queryWithBinds(
          soql,
          binds,
          AccessLevel.USER_MODE
        )
      ) {
        Object keyValue = record.get(matchFieldName);
        if (keyValue == null) {
          continue;
        }
        String key = String.valueOf(keyValue);
        if (lookupField != null) {
          Id parentId = (Id) record.get(lookupField);
          key = parentId + '|' + key;
        }
        if (!recordsByKey.containsKey(key)) {
          recordsByKey.put(key, record);
        }
      }
      return true;
    } catch (Exception e) {
      reportTo.add(
        IdpResult.CODE_ROW_LOOKUP_FAILED,
        IdpResult.SEV_ERROR,
        label + ': row lookup failed — ' + e.getMessage()
      );
      return false;
    }
  }

  /** The object whose resolved record constrains a section's rows: the
   *  declared Parent Section when given, otherwise the first anchored
   *  object (sorted, so deterministic) the row object looks up to. */
  private static String parentObjectFor(
    IdpConfigLoader.SectionConfig section,
    IdpConfigLoader.SetConfig config,
    Map<String, SObject> anchors
  ) {
    if (String.isNotBlank(section.parentSectionName)) {
      for (IdpConfigLoader.SectionConfig candidate : config.sections) {
        if (candidate.name == section.parentSectionName) {
          return anchors.containsKey(candidate.targetObject)
            ? candidate.targetObject
            : null;
        }
      }
      return null;
    }
    List<String> anchored = new List<String>(anchors.keySet());
    anchored.sort();
    for (String candidate : anchored) {
      if (
        IdpSchemaCache.findLookupTo(section.targetObject, candidate) != null
      ) {
        return candidate;
      }
    }
    return null;
  }

  // ─────────────────────────── plumbing ───────────────────────────

  /** The per-object anchor requests the resolver needs. */
  private static Map<String, IdpContextResolver.AnchorSpec> buildAnchorRequests(
    IdpConfigLoader.SetConfig config
  ) {
    Map<String, IdpContextResolver.AnchorSpec> requests = new Map<String, IdpContextResolver.AnchorSpec>();
    for (IdpConfigLoader.SectionConfig section : config.sections) {
      if (!section.repeating) {
        IdpContextResolver.AnchorSpec spec = specFor(
          requests,
          section.targetObject
        );
        for (IdpConfigLoader.RuleConfig rule : section.rules) {
          spec.fields.add(rule.targetField);
        }
        if (UserInfo.isMultiCurrencyOrganization()) {
          // The currency guard compares against the record's denomination;
          // the resolver drops the field where an object lacks it.
          spec.fields.add('CurrencyIsoCode');
        }
        if (String.isBlank(spec.filter)) {
          spec.filter = String.isNotBlank(section.recordFilter)
            ? section.recordFilter
            : firstAnchorFilter(section);
        }
      } else if (String.isNotBlank(section.parentSectionName)) {
        // A repeating section's rows hang off a parent record, so that
        // parent must be resolved even when no rule writes to it.
        for (IdpConfigLoader.SectionConfig candidate : config.sections) {
          if (candidate.name == section.parentSectionName) {
            IdpContextResolver.AnchorSpec spec = specFor(
              requests,
              candidate.targetObject
            );
            if (String.isBlank(spec.filter)) {
              spec.filter = candidate.recordFilter;
            }
          }
        }
      }
    }
    return requests;
  }

  private static IdpContextResolver.AnchorSpec specFor(
    Map<String, IdpContextResolver.AnchorSpec> requests,
    String objectName
  ) {
    IdpContextResolver.AnchorSpec spec = requests.get(objectName);
    if (spec == null) {
      spec = new IdpContextResolver.AnchorSpec();
      requests.put(objectName, spec);
    }
    return spec;
  }

  private static String firstAnchorFilter(
    IdpConfigLoader.SectionConfig section
  ) {
    for (IdpConfigLoader.RuleConfig rule : section.rules) {
      if (String.isNotBlank(rule.anchorFilter)) {
        return rule.anchorFilter;
      }
    }
    return null;
  }

  private static String effectiveMode(
    IdpConfigLoader.RuleConfig rule,
    String runMode
  ) {
    if (String.isNotBlank(rule.mode)) {
      return rule.mode;
    }
    return runMode == MODE_PREVIEW ? MODE_EXTRACTION : runMode;
  }

  private static void invokeFindingHandler(
    String handlerOverride,
    IdpConfigLoader.SetConfig config,
    String runMode,
    List<IdpResult.Result> results
  ) {
    String handlerName = String.isNotBlank(handlerOverride)
      ? handlerOverride
      : config.findingHandler;
    if (String.isBlank(handlerName)) {
      return;
    }
    List<IdpResult.Result> withMismatches = new List<IdpResult.Result>();
    for (IdpResult.Result result : results) {
      if (result.compliant == false) {
        withMismatches.add(result);
      }
    }
    if (withMismatches.isEmpty()) {
      return;
    }

    IdpResult.RunReport report = new IdpResult.RunReport();
    report.mappingSetName = config.name;
    report.mode = runMode;
    report.results = results;

    String failure;
    Type handlerType = Type.forName(handlerName);
    if (handlerType == null) {
      failure = 'Finding handler class "' + handlerName + '" was not found.';
    } else {
      Object instance;
      try {
        instance = handlerType.newInstance();
      } catch (Exception e) {
        failure =
          'Finding handler "' +
          handlerName +
          '" could not be instantiated: ' +
          e.getMessage();
      }
      if (failure == null && !(instance instanceof IIdpFindingHandler)) {
        failure =
          'Finding handler "' +
          handlerName +
          '" does not implement IIdpFindingHandler.';
      }
      if (failure == null) {
        try {
          ((IIdpFindingHandler) instance).handle(report);
        } catch (Exception e) {
          failure =
            'Finding handler "' + handlerName + '" failed: ' + e.getMessage();
        }
      }
    }
    if (failure != null) {
      for (IdpResult.Result result : withMismatches) {
        result.add(
          IdpResult.CODE_HANDLER_FAILED,
          IdpResult.SEV_ERROR,
          failure
        );
      }
    }
  }

  private static String normalizeMode(String mode) {
    String trimmed = mode == null ? '' : mode.trim();
    if (String.isBlank(trimmed)) {
      return MODE_EXTRACTION;
    }
    if (
      trimmed.equalsIgnoreCase(MODE_EXTRACTION) ||
      trimmed.equalsIgnoreCase('Data Extraction')
    ) {
      return MODE_EXTRACTION;
    }
    if (
      trimmed.equalsIgnoreCase(MODE_COMPLIANCE) ||
      trimmed.equalsIgnoreCase('Compliance Check')
    ) {
      return MODE_COMPLIANCE;
    }
    if (
      trimmed.equalsIgnoreCase(MODE_PREVIEW) ||
      trimmed.equalsIgnoreCase('Dry Run')
    ) {
      return MODE_PREVIEW;
    }
    return null;
  }

  private static String asString(Id value) {
    return value == null ? null : String.valueOf(value);
  }
}
