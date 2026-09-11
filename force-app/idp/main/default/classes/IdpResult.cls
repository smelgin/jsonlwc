/**
 * Result model of the IDP mapping engine. One Result per document, carrying
 * a single typed list of Findings instead of parallel string lists: every
 * noteworthy event — a config issue, an unparseable value, a compliance
 * mismatch, a deferred document — is a Finding with a machine-readable code,
 * a severity and a human message.
 *
 *  - success   = no ERROR findings for this document
 *  - compliant = no VALUE_MISMATCH findings (Near matches don't clear it)
 *
 * Grades qualify how a value was parsed (see IValueType): EXACT is a
 * deterministic parse, INFERRED a heuristic one, AMBIGUOUS one with several
 * readings, FAILED no reading at all. CompareOutcome is the three-state
 * compliance verdict: MATCH, NEAR (within the type's tolerance — for a
 * human to glance at), MISMATCH.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpResult {
  /**
   * How sure a value type is of the reading it produced.
   */
  public enum Grade {
    /** Deterministic parse. */
    EXACT,
    /** Heuristic parse the configuration allowed. */
    INFERRED,
    /** Several readings are equally defensible. */
    AMBIGUOUS,
    /** No reading at all. */
    FAILED
  }

  /**
   * Three-state compliance verdict for one compared field.
   */
  public enum CompareOutcome {
    MATCH,
    /** Within the value type's tolerance — worth a human glance. */
    NEAR,
    MISMATCH
  }

  // Severities
  public static final String SEV_INFO = 'Info';
  public static final String SEV_WARNING = 'Warning';
  public static final String SEV_ERROR = 'Error';

  // Finding codes
  public static final String CODE_CONFIG_ISSUE = 'CONFIG_ISSUE';
  public static final String CODE_JSON_INVALID = 'JSON_INVALID';
  public static final String CODE_INVALID_INPUT = 'INVALID_INPUT';
  public static final String CODE_INVALID_MODE = 'INVALID_MODE';
  public static final String CODE_UNREACHABLE_TARGET = 'UNREACHABLE_TARGET';
  /** The target is joined to a resolved record by several lookups and the
   *  section did not say which (reachFrom / via); nothing was guessed. */
  public static final String CODE_AMBIGUOUS_RELATIONSHIP = 'AMBIGUOUS_RELATIONSHIP';
  public static final String CODE_UNKNOWN_FIELD = 'UNKNOWN_FIELD';
  public static final String CODE_REQUIRED_MISSING = 'REQUIRED_MISSING';
  public static final String CODE_PARSE_FAILED = 'PARSE_FAILED';
  public static final String CODE_PARSE_AMBIGUOUS = 'PARSE_AMBIGUOUS';
  public static final String CODE_BELOW_MIN_GRADE = 'BELOW_MIN_GRADE';
  public static final String CODE_LOW_CONFIDENCE = 'LOW_CONFIDENCE';
  public static final String CODE_PICKLIST_INVALID = 'PICKLIST_INVALID';
  public static final String CODE_CURRENCY_MISMATCH = 'CURRENCY_MISMATCH';
  public static final String CODE_VALUE_MISMATCH = 'VALUE_MISMATCH';
  public static final String CODE_VALUE_NEAR = 'VALUE_NEAR';
  public static final String CODE_ROW_UNMATCHED = 'ROW_UNMATCHED';
  public static final String CODE_ROW_DUPLICATE_KEY = 'ROW_DUPLICATE_KEY';
  public static final String CODE_ROW_LOOKUP_FAILED = 'ROW_LOOKUP_FAILED';
  public static final String CODE_ROW_CREATED = 'ROW_CREATED';
  public static final String CODE_ANCHOR_CREATED = 'ANCHOR_CREATED';
  public static final String CODE_FLS_BLOCKED = 'FLS_BLOCKED';
  public static final String CODE_DML_FAILED = 'DML_FAILED';
  public static final String CODE_HANDLER_FAILED = 'HANDLER_FAILED';
  public static final String CODE_HANDLER_SKIPPED = 'HANDLER_SKIPPED';
  public static final String CODE_DOC_DEFERRED = 'DOC_DEFERRED';

  /**
   * Names a grade for findings and planned changes.
   *
   * @param grade Grade a value type awarded the parse.
   * @return Human-readable label, such as Exact.
   */
  public static String label(Grade grade) {
    switch on grade {
      when EXACT {
        return 'Exact';
      }
      when INFERRED {
        return 'Inferred';
      }
      when AMBIGUOUS {
        return 'Ambiguous';
      }
      when else {
        return 'Failed';
      }
    }
  }

  /**
   * Orders grades so Min Grade gating can compare them.
   *
   * @param grade Grade a value type awarded the parse.
   * @return Rank where lower is a better parse.
   */
  public static Integer rank(Grade grade) {
    switch on grade {
      when EXACT {
        return 0;
      }
      when INFERRED {
        return 1;
      }
      when AMBIGUOUS {
        return 2;
      }
      when else {
        return 3;
      }
    }
  }

  /** One noteworthy event of a run. Only code, severity and message are
   *  always present; the rest is context filled where it applies. */
  public class Finding {
    /** Machine-readable code, one of the CODE_* constants. */
    @InvocableVariable
    @AuraEnabled
    public String code;

    /** Info, Warning or Error. */
    @InvocableVariable
    @AuraEnabled
    public String severity;

    /** Explanation written for whoever reviews the run. */
    @InvocableVariable
    @AuraEnabled
    public String message;

    /** API name of the object the finding concerns. */
    @InvocableVariable
    @AuraEnabled
    public String objectName;

    /** Record the finding concerns, null before an insert lands. */
    @InvocableVariable
    @AuraEnabled
    public String recordId;

    /** API name of the field the finding concerns. */
    @InvocableVariable
    @AuraEnabled
    public String fieldName;

    /** JSON Path the value was read from. */
    @InvocableVariable
    @AuraEnabled
    public String jsonPath;

    /** Section of the mapping set the finding arose in. */
    @InvocableVariable
    @AuraEnabled
    public String sectionName;

    /** Rule the finding arose from. */
    @InvocableVariable
    @AuraEnabled
    public String ruleName;

    /** Row position within a repeating section; null for fixed sections. */
    @InvocableVariable
    @AuraEnabled
    public Integer rowIndex;

    /** Row match key within a repeating section; null for fixed sections. */
    @InvocableVariable
    @AuraEnabled
    public String rowKey;

    /** What the document literally said. */
    @InvocableVariable
    @AuraEnabled
    public String rawValue;

    /** The parsed/canonical value (extracted side). */
    @InvocableVariable
    @AuraEnabled
    public String extractedValue;

    /** The value currently stored on the record (compliance). */
    @InvocableVariable
    @AuraEnabled
    public String storedValue;

    /** Parse grade: Exact, Inferred, Ambiguous, Failed. */
    @InvocableVariable
    @AuraEnabled
    public String grade;

    /** Compliance verdict for this field: Match, Near, Mismatch. */
    @InvocableVariable
    @AuraEnabled
    public String compareOutcome;

    /** OCR confidence from the JSON envelope, when the document carried one. */
    @InvocableVariable
    @AuraEnabled
    public Decimal confidence;
  }

  /** One planned (or applied) field write — the Preview payload. */
  public class PlannedChange {
    /** API name of the object being written. */
    @InvocableVariable
    @AuraEnabled
    public String objectName;

    /** Record being written, null while the run still plans to create it. */
    @InvocableVariable
    @AuraEnabled
    public String recordId;

    /** API name of the field being written. */
    @InvocableVariable
    @AuraEnabled
    public String fieldName;

    /** Value the record holds today. */
    @InvocableVariable
    @AuraEnabled
    public String oldValue;

    /** Value the run would write. */
    @InvocableVariable
    @AuraEnabled
    public String newValue;

    /** Parse grade behind the new value. */
    @InvocableVariable
    @AuraEnabled
    public String grade;

    /** Section of the mapping set the write comes from. */
    @InvocableVariable
    @AuraEnabled
    public String sectionName;

    /** Row position within a repeating section; null for fixed sections. */
    @InvocableVariable
    @AuraEnabled
    public Integer rowIndex;

    /** True when the change belongs to a record the run plans to create
     *  (recordId is null until the insert lands). */
    @InvocableVariable
    @AuraEnabled
    public Boolean isNew;
  }

  /** Per-document outcome. */
  public class Result {
    /** Reviewed file, when the run was seeded from one. */
    @InvocableVariable
    @AuraEnabled
    public String contentDocumentId;

    /** Set when the run was seeded from a record instead of a file. */
    @InvocableVariable
    @AuraEnabled
    public String seedRecordId;

    /** Mode the document ran under. */
    @InvocableVariable
    @AuraEnabled
    public String mode;

    /** False once the document collected an Error finding. */
    @InvocableVariable
    @AuraEnabled
    public Boolean success = true;

    /** False once a value mismatch was found; Near matches do not clear it. */
    @InvocableVariable
    @AuraEnabled
    public Boolean compliant = true;

    /** True when the limits guard postponed this document — rerun it. */
    @InvocableVariable
    @AuraEnabled
    public Boolean deferred = false;

    /** Fields written by Extraction rules. */
    @InvocableVariable
    @AuraEnabled
    public Integer fieldsApplied = 0;

    /** Fields weighed by Compliance rules. */
    @InvocableVariable
    @AuraEnabled
    public Integer fieldsCompared = 0;

    /** Document rows matched to an existing record. */
    @InvocableVariable
    @AuraEnabled
    public Integer rowsMatched = 0;

    /** Matched rows whose record the run changed. */
    @InvocableVariable
    @AuraEnabled
    public Integer rowsUpdated = 0;

    /** Rows the run inserted a record for. */
    @InvocableVariable
    @AuraEnabled
    public Integer rowsCreated = 0;

    /**
     * Weighted document-level confidence, 0–1, from the rules that carry a
     * Confidence Weight. Null when no weighted field resolved with a
     * confidence — "no score" is distinguishable from "zero".
     */
    @InvocableVariable
    @AuraEnabled
    public Decimal documentConfidence;

    /** Records the run changed. */
    @InvocableVariable
    @AuraEnabled
    public List<String> updatedRecordIds = new List<String>();

    /** Records the run inserted. */
    @InvocableVariable
    @AuraEnabled
    public List<String> createdRecordIds = new List<String>();

    /** Row keys from the document that matched no record. */
    @InvocableVariable
    @AuraEnabled
    public List<String> unmatchedRowKeys = new List<String>();

    /** Everything noteworthy the document's run observed. */
    @InvocableVariable
    @AuraEnabled
    public List<Finding> findings = new List<Finding>();

    /** Field writes, planned in Preview and applied otherwise. */
    @InvocableVariable
    @AuraEnabled
    public List<PlannedChange> plannedChanges = new List<PlannedChange>();

    /** ENG-9 accumulator: Σ(weight × confidence) over weighted fields that
     *  resolved with a confidence. Not serialized to callers. */
    private Decimal confidenceWeightedSum = 0;

    /** ENG-9 accumulator: Σ(weight) over the same fields. Not serialized;
     *  documentConfidence is the published number. */
    private Decimal confidenceWeightTotal = 0;

    /**
     * Records one weighted field confidence.
     *
     * Both 0.93 and 93 are accepted, since IDP services report either
     * scale, matching jsonForm's convention.
     *
     * @param weight Confidence Weight configured on the rule.
     * @param confidence Confidence the document reported for the field.
     */
    public void addConfidenceSample(Decimal weight, Decimal confidence) {
      if (weight == null || weight <= 0 || confidence == null) {
        return;
      }
      Decimal fraction = confidence > 1 ? confidence / 100 : confidence;
      confidenceWeightedSum += weight * fraction;
      confidenceWeightTotal += weight;
    }

    /**
     * Rolls the collected samples up into documentConfidence.
     *
     * Leaves the score null when no weighted field yielded a confidence.
     * The engine calls this once per run.
     */
    public void finalizeDocumentConfidence() {
      documentConfidence = confidenceWeightTotal > 0
        ? (confidenceWeightedSum / confidenceWeightTotal).setScale(4)
        : null;
    }

    /**
     * Attaches a finding and updates the document's success and compliance.
     *
     * @param code One of the CODE_* constants.
     * @param severity Info, Warning or Error.
     * @param message Explanation for whoever reviews the run.
     * @return The new finding, so the caller can add its context.
     */
    public Finding add(String code, String severity, String message) {
      Finding finding = new Finding();
      finding.code = code;
      finding.severity = severity;
      finding.message = message;
      findings.add(finding);
      if (severity == SEV_ERROR) {
        success = false;
      }
      if (code == CODE_VALUE_MISMATCH) {
        compliant = false;
      }
      return finding;
    }

    /**
     * Selects this document's findings carrying one code.
     *
     * @param code One of the CODE_* constants.
     * @return Matching findings, empty when there are none.
     */
    public List<Finding> findingsWith(String code) {
      List<Finding> matched = new List<Finding>();
      for (Finding finding : findings) {
        if (finding.code == code) {
          matched.add(finding);
        }
      }
      return matched;
    }

    /**
     * Selects this document's findings that failed the run.
     *
     * @return Findings whose severity is Error.
     */
    public List<Finding> errors() {
      List<Finding> matched = new List<Finding>();
      for (Finding finding : findings) {
        if (finding.severity == SEV_ERROR) {
          matched.add(finding);
        }
      }
      return matched;
    }
  }

  /** Payload handed to IIdpFindingHandler implementations. */
  public class RunReport {
    /** DeveloperName of the mapping set the run applied. */
    public String mappingSetName;
    /** Mode the run executed under. */
    public String mode;
    /** One Result per document in the run. */
    public List<Result> results = new List<Result>();

    /**
     * Selects findings carrying one code across every document in the run.
     *
     * @param code One of the CODE_* constants.
     * @return Matching findings, empty when there are none.
     */
    public List<Finding> allFindingsWith(String code) {
      List<Finding> matched = new List<Finding>();
      for (Result result : results) {
        matched.addAll(result.findingsWith(code));
      }
      return matched;
    }
  }
}
