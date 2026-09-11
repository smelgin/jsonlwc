/**
 * Queueable path for documents too large for a synchronous transaction
 * (ENG-4). IdpMappingController.apply() runs synchronously and the limits
 * guard defers a document that would not fit; this is what a caller does
 * about it — enqueue the same work and let it run with a fresh set of
 * governor limits:
 *
 *   Id jobId = IdpAsyncProcessor.enqueue(documents, 'My_Set', null, null);
 *
 * The results cannot come back to the caller (there is no run log yet —
 * ENG-7), so outcomes are delivered through the usual finding handler and
 * the aggregate is written to the debug log. Documents the guard defers
 * even here are re-enqueued in a chained job, up to MAX_RETRIES, mirroring
 * IdpBatchProcessor's retry pass. Preview makes no sense asynchronously —
 * its whole output is the returned plan — so the engine's ordinary mode
 * validation applies and callers should not enqueue previews.
 *
 * @group IDP Processing
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpAsyncProcessor implements Queueable {
  /** Chained retry passes granted to documents the limits guard defers. */
  private static final Integer MAX_RETRIES = 2;

  /** One document, in the serializable shape Queueable state requires. */
  public class DocumentInput {
    /** Reviewed file, when the run is seeded from a ContentDocument. */
    public Id contentDocumentId;
    /** Seed record to resolve context from, instead of a file. */
    public Id seedRecordId;
    /** The reviewed JSON payload. */
    public String jsonString;
  }

  /** Documents this job carries. */
  private final List<DocumentInput> documents;

  /** DeveloperName of the mapping set to apply. */
  private final String mappingSetName;

  /** Run mode passed through to the engine. */
  private final String mode;

  /** Finding handler override, null to use the mapping set's default. */
  private final String findingHandler;

  /** Retry passes still available to deferred documents. */
  private final Integer retriesRemaining;

  /**
   * Creates a job with the full retry allowance.
   *
   * @param documents Documents to process.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; Preview is not valid here.
   * @param findingHandler Optional handler overriding the set's default.
   */
  public IdpAsyncProcessor(
    List<DocumentInput> documents,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    this(documents, mappingSetName, mode, findingHandler, MAX_RETRIES);
  }

  /**
   * Creates a chained job that carries the remaining retry allowance.
   *
   * @param documents Documents deferred by the previous pass.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; Preview is not valid here.
   * @param findingHandler Optional handler overriding the set's default.
   * @param retriesRemaining Retry passes left before deferrals are dropped.
   */
  private IdpAsyncProcessor(
    List<DocumentInput> documents,
    String mappingSetName,
    String mode,
    String findingHandler,
    Integer retriesRemaining
  ) {
    this.documents = documents == null ? new List<DocumentInput>() : documents;
    this.mappingSetName = mappingSetName;
    this.mode = mode;
    this.findingHandler = findingHandler;
    this.retriesRemaining = retriesRemaining;
  }

  /**
   * Queues the work so it runs against a fresh set of governor limits.
   *
   * @param documents Documents to process.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; Preview is not valid here.
   * @param findingHandler Optional handler overriding the set's default.
   * @return Id of the enqueued job.
   */
  public static Id enqueue(
    List<DocumentInput> documents,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    return System.enqueueJob(
      new IdpAsyncProcessor(documents, mappingSetName, mode, findingHandler)
    );
  }

  /**
   * Runs the engine over this job's documents and chains a retry pass.
   *
   * Outcomes reach the org through the configured finding handler; the
   * aggregate is written to the debug log, and documents the limits guard
   * defers again are re-enqueued while retries remain.
   *
   * @param context Queueable context supplied by the platform.
   */
  public void execute(QueueableContext context) {
    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (DocumentInput document : documents) {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.contentDocumentId = document.contentDocumentId;
      work.seedRecordId = document.seedRecordId;
      work.jsonString = document.jsonString;
      works.add(work);
    }
    if (works.isEmpty()) {
      return;
    }

    List<IdpResult.Result> results = IdpMappingEngine.run(
      works,
      mappingSetName,
      mode,
      findingHandler
    );

    List<DocumentInput> deferred = new List<DocumentInput>();
    Integer failed = 0;
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].deferred == true) {
        deferred.add(documents[i]);
      } else if (results[i].success == false) {
        failed++;
      }
    }
    System.debug(
      LoggingLevel.INFO,
      'IdpAsyncProcessor(' +
        mappingSetName +
        '): ' +
        results.size() +
        ' document(s) processed, ' +
        failed +
        ' with errors, ' +
        deferred.size() +
        ' deferred.'
    );
    if (!deferred.isEmpty() && retriesRemaining > 0 && !Test.isRunningTest()) {
      System.enqueueJob(
        new IdpAsyncProcessor(
          deferred,
          mappingSetName,
          mode,
          findingHandler,
          retriesRemaining - 1
        )
      );
    }
  }
}
