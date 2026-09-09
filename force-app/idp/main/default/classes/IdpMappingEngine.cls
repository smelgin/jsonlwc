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
 * A rule's Mode overrides the run's per field: Extraction, Compliance, or
 * Custom — the last hands the parsed field to the rule's IIdpFieldHandler
 * (skipped in Preview, which says so).
 *
 * Sections can opt into creating what a run cannot find (Extraction and
 * Preview only — Compliance never creates): unmatchedRows: "Create" on a
 * repeating section creates the rows no record matched, and whenNoAnchor:
 * "Create" on a fixed section creates its missing anchor.
 *
 * Sections reach their record either implicitly — the resolver walks
 * the schema along the one lookup that joins two objects — or explicitly,
 * with reachFrom / via naming the anchor and the lookup to follow, which
 * is how two sections address two different Accounts of one Case. An
 * object joined to a resolved record by several lookups is never guessed
 * at: the section gets an AMBIGUOUS_RELATIONSHIP finding naming them.
 *
 * Cost model: one ContentDocumentLink query for the run, grouped anchor
 * queries per object (or per explicit section), one query per repeating
 * section group, and at most one insert plus one update DML — query count
 * does not scale with rule or row count.
 */
public inherited sharing class IdpMappingEngine {
  public static final String MODE_EXTRACTION = 'Extraction';
  public static final String MODE_COMPLIANCE = 'Compliance';
  public static final String MODE_PREVIEW = 'Preview';
  /** Per-rule only — never a run mode. */
  public static final String MODE_CUSTOM = 'Custom';
  private static final String POLICY_CREATE = 'Create';

  // Query-budget model, checked against the limits guard before a run starts.
  // Flat cost of a run: the ContentDocumentLink query plus one spare.
  private static final Integer BASE_QUERIES = 2;
  // Worst case for one anchored object across the resolver's passes: the
  // root fetch, hub expansion, then a parent and a child hop on each of the
  // three passes.
  private static final Integer QUERIES_PER_ANCHOR = 7;

  /** One document in, one Result out. Seed either a file
   *  (contentDocumentId) or a record (seedRecordId — the batch path). */
  public class DocumentWork {
    public Id contentDocumentId;
    public Id seedRecordId;
    public String jsonString;

    private Object root;
    private IdpContextResolver.DocContext context;
    private IdpResult.Result result;
    /** Distinguishes this document's created anchors from another's. */
    private Integer docIndex;
  }

  public static List<IdpResult.Result> run(
    List<DocumentWork> works,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    return run(
      works,
      IdpConfigLoader.load(mappingSetName),
      mode,
      findingHandler
    );
  }

  /**
   * The same run against a config that is already assembled, so a
   * definition can be tried before it is saved. Everything after this
   * point is identical either way — the config is the only thing a stored
   * set contributes, so a draft that assembles to the same config runs
   * the same.
   */
  public static List<IdpResult.Result> run(
    List<DocumentWork> works,
    IdpConfigLoader.SetConfig config,
    String mode,
    String findingHandler
  ) {
    List<IdpResult.Result> results = new List<IdpResult.Result>();
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
      work.docIndex = eligible.size();
      eligible.add(work);
    }
    if (eligible.isEmpty()) {
      return results;
    }

    IdpContextResolver.Plan plan = buildPlan(config);
    // An anchor whose filter reads document values (referencesDocument)
    // resolves with one query per document instead of one grouped query
    // for the whole run — see IdpContextResolver's docBound query paths —
    // so it must be weighted by document count, not treated like a
    // grouped anchor.
    Integer groupedAnchors = 0;
    Integer docBoundAnchors = 0;
    for (IdpContextResolver.AnchorSpec spec : plan.byObject.values()) {
      if (IdpFilterBinder.referencesDocument(spec.filter)) {
        docBoundAnchors++;
      } else {
        groupedAnchors++;
      }
    }
    for (IdpContextResolver.AnchorSpec spec : plan.bySection.values()) {
      if (IdpFilterBinder.referencesDocument(spec.filter)) {
        docBoundAnchors++;
      } else {
        groupedAnchors++;
      }
    }
    Integer estimate =
      BASE_QUERIES +
      groupedAnchors * QUERIES_PER_ANCHOR +
      docBoundAnchors * eligible.size() +
      config.sections.size();
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
    IdpContextResolver.resolveAll(contexts, plan);

    IdpDmlExecutor executor = new IdpDmlExecutor();
    for (DocumentWork work : eligible) {
      for (IdpConfigLoader.SectionConfig section : config.sections) {
        if (!section.repeating) {
          processFixedSection(
            section,
            config,
            work,
            runMode,
            previewing,
            executor
          );
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
    // compliant needs no roll-up here: IdpResult.Result.add() clears it the
    // moment a VALUE_MISMATCH finding is recorded.
    for (IdpResult.Result result : results) {
      result.finalizeDocumentConfidence();
    }
    invokeFindingHandler(findingHandler, config, runMode, results);
    return results;
  }

  // ──────────────────────── fixed sections ────────────────────────

  private static void processFixedSection(
    IdpConfigLoader.SectionConfig section,
    IdpConfigLoader.SetConfig config,
    DocumentWork work,
    String runMode,
    Boolean previewing,
    IdpDmlExecutor executor
  ) {
    if (section.rules.isEmpty()) {
      return;
    }
    SObject anchor = anchorFor(section, work.context);
    if (anchor == null) {
      SObject source = section.reachFrom == null
        ? null
        : work.context.anchorFor(sourceKeyFor(section, config));
      if (
        section.noAnchorPolicy == POLICY_CREATE &&
        runMode != MODE_COMPLIANCE &&
        (section.reachFrom == null ||
        source != null)
      ) {
        createAnchor(section, source, work, runMode, previewing, executor);
        return;
      }
      reportUnreachable(section, source, work);
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

  /**
   * The reason a fixed section has no record, as a finding: an explicit
   * path names the hop that came up empty; an implicit target that the
   * walk declined to guess at is AMBIGUOUS_RELATIONSHIP with the
   * candidates; anything else is plain UNREACHABLE_TARGET.
   */
  private static void reportUnreachable(
    IdpConfigLoader.SectionConfig section,
    SObject source,
    DocumentWork work
  ) {
    String code = IdpResult.CODE_UNREACHABLE_TARGET;
    String message;
    String ambiguity = work.context.ambiguities.get(section.targetObject);
    if (section.reachFrom != null && source == null) {
      message =
        'Section ' +
        section.name +
        ' reaches ' +
        section.targetObject +
        ' from "' +
        section.reachFrom +
        '", which was not resolved for this document; the section was skipped.';
    } else if (section.reachFrom != null) {
      message =
        'No ' +
        section.targetObject +
        ' record is reachable from ' +
        section.sourceObject +
        ' via ' +
        section.relationshipField +
        (section.childHop
          ? ' (no such child record)'
          : ' (the lookup is empty, or points at a record you cannot see)') +
        ' — section ' +
        section.name +
        ' was skipped.';
    } else if (ambiguity != null) {
      code = IdpResult.CODE_AMBIGUOUS_RELATIONSHIP;
      message =
        'Section ' +
        section.name +
        ' targets ' +
        section.targetObject +
        ', which this document reaches only through an ambiguous ' +
        'relationship: ' +
        ambiguity +
        '. Set reachFrom and via on the section to choose one; nothing was guessed.';
    } else {
      message =
        'No ' +
        section.targetObject +
        ' record is reachable from this document — section ' +
        section.name +
        ' was skipped.';
    }
    IdpResult.Finding finding = work.result.add(
      code,
      IdpResult.SEV_ERROR,
      message
    );
    finding.objectName = section.targetObject;
    finding.sectionName = section.name;
  }

  /**
   * whenNoAnchor: "Create" (ENG-3) — builds the missing anchor in memory,
   * links it to its source, applies the section's Extraction rules onto
   * it and stages it for the run's single insert. The link follows the
   * section's relationship: a child hop writes the lookup on the new
   * record; a parent hop stages a back-link that sets the source's
   * lookup once the insert has an Id; an implicit section links to the
   * first resolved record with a single lookup to it. Compliance rules
   * are skipped: there is nothing to compare on a record that does not
   * exist yet. A created anchor is not added to the document's anchor
   * map, so rows cannot hang off it within the same run.
   */
  private static void createAnchor(
    IdpConfigLoader.SectionConfig section,
    SObject source,
    DocumentWork work,
    String runMode,
    Boolean previewing,
    IdpDmlExecutor executor
  ) {
    String objectName = section.targetObject;
    String dedupeKey =
      'anchor|' +
      objectName +
      '|' +
      (section.reachFrom == null ? '' : section.name) +
      '|' +
      work.docIndex;
    SObject record = executor.stagedInsert(dedupeKey);
    if (record == null) {
      record = IdpSchemaCache.typeOf(objectName).newSObject();
      String linkNote = '';
      if (section.reachFrom != null && section.childHop) {
        record.put(section.relationshipField, source.Id);
      } else if (section.reachFrom != null) {
        executor.stageBackLink(
          dedupeKey,
          work.result,
          source.getSObjectType(),
          source.Id,
          section.relationshipField
        );
        linkNote =
          ' and point ' +
          section.sourceObject +
          '.' +
          section.relationshipField +
          ' at it';
      } else {
        List<String> anchored = new List<String>(work.context.anchors.keySet());
        anchored.sort();
        for (String candidate : anchored) {
          String lookup = IdpSchemaCache.findLookupTo(objectName, candidate);
          if (lookup != null) {
            record.put(lookup, work.context.anchors.get(candidate).Id);
            break;
          }
        }
      }
      if (previewing) {
        IdpResult.Finding planned = work.result.add(
          IdpResult.CODE_ANCHOR_CREATED,
          IdpResult.SEV_INFO,
          'Section ' +
            section.name +
            ' would create a ' +
            objectName +
            ' record' +
            linkNote +
            ' (whenNoAnchor is "Create").'
        );
        planned.objectName = objectName;
        planned.sectionName = section.name;
      }
    }
    record = executor.stageInsert(
      dedupeKey,
      record,
      work.result,
      false,
      section.name,
      null,
      null
    );
    for (IdpConfigLoader.RuleConfig rule : section.rules) {
      String mode = effectiveMode(rule, runMode);
      if (mode == MODE_COMPLIANCE) {
        continue;
      }
      IdpRuleEvaluator.apply(
        rule,
        mode,
        previewing,
        work.root,
        record,
        objectName,
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
   * matched and updated; unmatched keys are data, not errors — unless the
   * section opts in with unmatchedRows: "Create" (ENG-2), in which case
   * they join the run's single insert.
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
    Schema.DescribeFieldResult matchField = IdpSchemaCache.fieldDescribe(
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
    String matchFieldName = matchField.getName();

    // Group by lookup field (docs without a parent constraint group under
    // null) — one query per group.
    Map<String, List<DocRows>> groups = new Map<String, List<DocRows>>();
    for (DocRows docRows : allDocRows) {
      String groupKey = docRows.lookupField == null ? '' : docRows.lookupField;
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
    Schema.DescribeFieldResult matchField,
    String label
  ) {
    Object raw = IdpJsonReader.read(work.root, section.rowPath);
    if (raw == null) {
      return null;
    }
    if (matchField == null || !matchField.isAccessible()) {
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

    if (section.unscopedRows) {
      return docRows; // rowScope: "None" — keys stand on their own
    }
    // Rows are constrained to their parent record, so a key unique only
    // within one account cannot reach another account's rows.
    if (section.reachFrom != null) {
      SObject parent = work.context.anchorFor(sourceKeyFor(section, config));
      if (parent == null) {
        IdpResult.Finding finding = work.result.add(
          IdpResult.CODE_ROW_LOOKUP_FAILED,
          IdpResult.SEV_ERROR,
          label +
            ': rows are scoped to "' +
            section.reachFrom +
            '", which was not resolved for this document; the rows were skipped.'
        );
        finding.sectionName = section.name;
        return null;
      }
      docRows.lookupField = section.relationshipField;
      docRows.parentId = parent.Id;
      return docRows;
    }
    // No reachFrom: the first anchored object (sorted, so deterministic)
    // the row object has exactly one lookup to. Several lookups to an
    // anchored object and no single-lookup alternative is an ambiguity
    // to report, not a reason to run the rows unscoped.
    List<String> anchored = new List<String>(work.context.anchors.keySet());
    anchored.sort();
    List<String> ambiguous = new List<String>();
    for (String candidate : anchored) {
      List<String> lookups = IdpSchemaCache.lookupsTo(
        section.targetObject,
        candidate
      );
      if (lookups.size() == 1) {
        docRows.lookupField = lookups[0];
        docRows.parentId = work.context.anchors.get(candidate).Id;
        return docRows;
      }
      if (lookups.size() > 1) {
        ambiguous.add(candidate + ' (' + String.join(lookups, ', ') + ')');
      }
    }
    if (!ambiguous.isEmpty()) {
      IdpResult.Finding finding = work.result.add(
        IdpResult.CODE_AMBIGUOUS_RELATIONSHIP,
        IdpResult.SEV_ERROR,
        label +
          ': ' +
          section.targetObject +
          ' rows could be scoped to a resolved record through several ' +
          'lookups — ' +
          String.join(ambiguous, '; ') +
          '. Set reachFrom and via on the section to choose one; the rows were skipped.'
      );
      finding.sectionName = section.name;
      finding.objectName = section.targetObject;
      return null;
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
    for (IdpConfigLoader.RuleConfig rule : section.rules) {
      Schema.DescribeFieldResult describe = IdpSchemaCache.fieldDescribe(
        objectName,
        rule.targetField
      );
      if (describe != null && describe.isAccessible()) {
        selected.add(describe.getName());
      }
    }
    if (
      UserInfo.isMultiCurrencyOrganization() &&
      IdpSchemaCache.field(objectName, 'CurrencyIsoCode') != null
    ) {
      selected.add('CurrencyIsoCode'); // for the currency guard
    }

    // Per-document queries only when the filter binds document values.
    Boolean docBound = IdpFilterBinder.referencesDocument(section.recordFilter);
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
        Boolean created = false;
        if (record == null) {
          if (
            section.unmatchedRowPolicy == POLICY_CREATE &&
            runMode != MODE_COMPLIANCE
          ) {
            record = stageRowCreation(
              section,
              docRows,
              key,
              index,
              matchFieldName,
              previewing,
              executor,
              label
            );
            created = record != null;
          }
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
                ').' +
                (section.unmatchedRowPolicy == POLICY_CREATE
                  ? ''
                  : ' Rows are matched, not created, unless the section' +
                    ' sets unmatchedRows to "Create".')
            );
            finding.sectionName = section.name;
            finding.rowIndex = index;
            finding.rowKey = key;
            continue;
          }
        }
        if (!created) {
          docRows.work.result.rowsMatched++;
        }
        IdpRuleEvaluator.RowInfo rowInfo = new IdpRuleEvaluator.RowInfo(
          section.name,
          index,
          key
        );
        for (IdpConfigLoader.RuleConfig rule : section.rules) {
          String mode = effectiveMode(rule, runMode);
          if (created && mode == MODE_COMPLIANCE) {
            continue; // nothing to compare on a record being created
          }
          IdpRuleEvaluator.apply(
            rule,
            mode,
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

  /**
   * unmatchedRows: "Create" (ENG-2) — builds the missing row in memory
   * with its match key and parent lookup, and stages it for the run's
   * single insert. Deduplicated across documents by (object, parent, key),
   * so two statements naming the same new row share one record, mirroring
   * how updates merge. Null when the match key cannot be written (reported).
   */
  private static SObject stageRowCreation(
    IdpConfigLoader.SectionConfig section,
    DocRows docRows,
    String key,
    Integer index,
    String matchFieldName,
    Boolean previewing,
    IdpDmlExecutor executor,
    String label
  ) {
    String objectName = section.targetObject;
    String dedupeKey =
      'row|' +
      objectName +
      '|' +
      (docRows.parentId == null ? '' : String.valueOf(docRows.parentId)) +
      '|' +
      key;
    SObject record = executor.stagedInsert(dedupeKey);
    if (record == null) {
      record = IdpSchemaCache.typeOf(objectName).newSObject();
      try {
        record.put(matchFieldName, key);
      } catch (Exception e) {
        IdpResult.Finding finding = docRows.work.result.add(
          IdpResult.CODE_ROW_LOOKUP_FAILED,
          IdpResult.SEV_ERROR,
          label +
            ': key "' +
            key +
            '" cannot be written to Match Field ' +
            matchFieldName +
            ', so the row was not created — ' +
            e.getMessage()
        );
        finding.sectionName = section.name;
        finding.rowIndex = index;
        finding.rowKey = key;
        return null;
      }
      if (docRows.lookupField != null && docRows.parentId != null) {
        record.put(docRows.lookupField, docRows.parentId);
      }
      if (previewing) {
        IdpResult.Finding planned = docRows.work.result.add(
          IdpResult.CODE_ROW_CREATED,
          IdpResult.SEV_INFO,
          label +
            ': a ' +
            objectName +
            ' record would be created for key "' +
            key +
            '" (unmatchedRows is "Create").'
        );
        planned.objectName = objectName;
        planned.sectionName = section.name;
        planned.rowIndex = index;
        planned.rowKey = key;
      }
    }
    return executor.stageInsert(
      dedupeKey,
      record,
      docRows.work.result,
      true,
      section.name,
      index,
      key
    );
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

  // ─────────────────────────── plumbing ───────────────────────────

  /** The record a section addresses: its own explicit anchor when it
   *  declares a path, else the implicit anchor of its target object. */
  private static SObject anchorFor(
    IdpConfigLoader.SectionConfig section,
    IdpContextResolver.DocContext context
  ) {
    return section.reachFrom == null
      ? context.anchors.get(section.targetObject)
      : context.anchorsBySection.get(section.name);
  }

  /**
   * The resolver key of the anchor a section is reached from: an explicit
   * source section's name, an implicit source section's target object,
   * or the root object named directly.
   */
  private static String sourceKeyFor(
    IdpConfigLoader.SectionConfig section,
    IdpConfigLoader.SetConfig config
  ) {
    if (!section.reachFromSection) {
      return section.sourceObject;
    }
    IdpConfigLoader.SectionConfig source = sectionNamed(
      config,
      section.reachFrom
    );
    if (source == null) {
      return section.sourceObject;
    }
    return source.reachFrom == null ? source.targetObject : source.name;
  }

  private static IdpConfigLoader.SectionConfig sectionNamed(
    IdpConfigLoader.SetConfig config,
    String name
  ) {
    for (IdpConfigLoader.SectionConfig candidate : config.sections) {
      if (candidate.name == name) {
        return candidate;
      }
    }
    return null;
  }

  /**
   * What the resolver must find: every fixed section as an implicit
   * (per object) or explicit (per section) target, and every source a
   * path starts from — resolved even when no rule writes to it.
   */
  private static IdpContextResolver.Plan buildPlan(
    IdpConfigLoader.SetConfig config
  ) {
    IdpContextResolver.Plan plan = new IdpContextResolver.Plan();
    plan.hubObject = config.hubObject;
    for (IdpConfigLoader.SectionConfig section : config.sections) {
      if (section.reachFrom != null) {
        ensureSource(plan, config, section);
      }
      if (section.repeating) {
        continue;
      }
      IdpContextResolver.AnchorSpec spec;
      if (section.reachFrom == null) {
        spec = specFor(plan.byObject, section.targetObject);
      } else {
        spec = new IdpContextResolver.AnchorSpec();
        spec.objectName = section.targetObject;
        spec.sourceKey = sourceKeyFor(section, config);
        spec.relationshipField = section.relationshipField;
        spec.childHop = section.childHop;
        plan.bySection.put(section.name, spec);
        plan.sectionOrder.add(section.name);
      }
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
    }
    return plan;
  }

  /** A path's source must be anchored: an implicit source section joins
   *  the per-object requests (with its filter); a root object named
   *  directly is requested so the walk reaches it when it is not a root;
   *  an explicit source section registers itself. */
  private static void ensureSource(
    IdpContextResolver.Plan plan,
    IdpConfigLoader.SetConfig config,
    IdpConfigLoader.SectionConfig section
  ) {
    if (!section.reachFromSection) {
      specFor(plan.byObject, section.sourceObject);
      return;
    }
    IdpConfigLoader.SectionConfig source = sectionNamed(
      config,
      section.reachFrom
    );
    if (source != null && source.reachFrom == null) {
      IdpContextResolver.AnchorSpec spec = specFor(
        plan.byObject,
        source.targetObject
      );
      if (String.isBlank(spec.filter)) {
        spec.filter = source.recordFilter;
      }
    }
  }

  private static IdpContextResolver.AnchorSpec specFor(
    Map<String, IdpContextResolver.AnchorSpec> requests,
    String objectName
  ) {
    IdpContextResolver.AnchorSpec spec = requests.get(objectName);
    if (spec == null) {
      spec = new IdpContextResolver.AnchorSpec();
      spec.objectName = objectName;
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
            'Finding handler "' +
            handlerName +
            '" failed: ' +
            e.getMessage();
        }
      }
    }
    if (failure != null) {
      for (IdpResult.Result result : withMismatches) {
        result.add(IdpResult.CODE_HANDLER_FAILED, IdpResult.SEV_ERROR, failure);
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
