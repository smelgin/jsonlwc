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
 */
public inherited sharing class IdpResult {
  public enum Grade {
    EXACT,
    INFERRED,
    AMBIGUOUS,
    FAILED
  }

  public enum CompareOutcome {
    MATCH,
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

  /** Human-readable grade label for findings and planned changes. */
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

  /** Rank for Min Grade gating: lower is better. */
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
    @InvocableVariable
    @AuraEnabled
    public String code;

    @InvocableVariable
    @AuraEnabled
    public String severity;

    @InvocableVariable
    @AuraEnabled
    public String message;

    @InvocableVariable
    @AuraEnabled
    public String objectName;

    @InvocableVariable
    @AuraEnabled
    public String recordId;

    @InvocableVariable
    @AuraEnabled
    public String fieldName;

    @InvocableVariable
    @AuraEnabled
    public String jsonPath;

    @InvocableVariable
    @AuraEnabled
    public String sectionName;

    @InvocableVariable
    @AuraEnabled
    public String ruleName;

    @InvocableVariable
    @AuraEnabled
    public Integer rowIndex;

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
    @InvocableVariable
    @AuraEnabled
    public String objectName;

    @InvocableVariable
    @AuraEnabled
    public String recordId;

    @InvocableVariable
    @AuraEnabled
    public String fieldName;

    @InvocableVariable
    @AuraEnabled
    public String oldValue;

    @InvocableVariable
    @AuraEnabled
    public String newValue;

    @InvocableVariable
    @AuraEnabled
    public String grade;

    @InvocableVariable
    @AuraEnabled
    public String sectionName;

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
    @InvocableVariable
    @AuraEnabled
    public String contentDocumentId;

    /** Set when the run was seeded from a record instead of a file. */
    @InvocableVariable
    @AuraEnabled
    public String seedRecordId;

    @InvocableVariable
    @AuraEnabled
    public String mode;

    @InvocableVariable
    @AuraEnabled
    public Boolean success = true;

    @InvocableVariable
    @AuraEnabled
    public Boolean compliant = true;

    /** True when the limits guard postponed this document — rerun it. */
    @InvocableVariable
    @AuraEnabled
    public Boolean deferred = false;

    @InvocableVariable
    @AuraEnabled
    public Integer fieldsApplied = 0;

    @InvocableVariable
    @AuraEnabled
    public Integer fieldsCompared = 0;

    @InvocableVariable
    @AuraEnabled
    public Integer rowsMatched = 0;

    @InvocableVariable
    @AuraEnabled
    public Integer rowsUpdated = 0;

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

    @InvocableVariable
    @AuraEnabled
    public List<String> updatedRecordIds = new List<String>();

    @InvocableVariable
    @AuraEnabled
    public List<String> createdRecordIds = new List<String>();

    @InvocableVariable
    @AuraEnabled
    public List<String> unmatchedRowKeys = new List<String>();

    @InvocableVariable
    @AuraEnabled
    public List<Finding> findings = new List<Finding>();

    @InvocableVariable
    @AuraEnabled
    public List<PlannedChange> plannedChanges = new List<PlannedChange>();

    // ENG-9 accumulators — Σ(weight × confidence) and Σ(weight) over the
    // weighted fields that resolved with a confidence. Not serialized to
    // callers; documentConfidence is the published number.
    private Decimal confidenceWeightedSum = 0;
    private Decimal confidenceWeightTotal = 0;

    /**
     * Records one weighted field confidence. Both 0.93 and 93 are accepted
     * (IDP services report either scale), matching jsonForm's convention.
     */
    public void addConfidenceSample(Decimal weight, Decimal confidence) {
      if (weight == null || weight <= 0 || confidence == null) {
        return;
      }
      Decimal fraction = confidence > 1 ? confidence / 100 : confidence;
      confidenceWeightedSum += weight * fraction;
      confidenceWeightTotal += weight;
    }

    /** Rolls the samples up into documentConfidence; null when no weighted
     *  field yielded a confidence. The engine calls this once per run. */
    public void finalizeDocumentConfidence() {
      documentConfidence = confidenceWeightTotal > 0
        ? (confidenceWeightedSum / confidenceWeightTotal).setScale(4)
        : null;
    }

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

    public List<Finding> findingsWith(String code) {
      List<Finding> matched = new List<Finding>();
      for (Finding finding : findings) {
        if (finding.code == code) {
          matched.add(finding);
        }
      }
      return matched;
    }

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
    public String mappingSetName;
    public String mode;
    public List<Result> results = new List<Result>();

    public List<Finding> allFindingsWith(String code) {
      List<Finding> matched = new List<Finding>();
      for (Result result : results) {
        matched.addAll(result.findingsWith(code));
      }
      return matched;
    }
  }
}
