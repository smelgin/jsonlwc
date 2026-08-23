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
 */
public inherited sharing class IdpAsyncProcessor implements Queueable {
  private static final Integer MAX_RETRIES = 2;

  /** One document, in the serializable shape Queueable state requires. */
  public class DocumentInput {
    public Id contentDocumentId;
    public Id seedRecordId;
    public String jsonString;
  }

  private final List<DocumentInput> documents;
  private final String mappingSetName;
  private final String mode;
  private final String findingHandler;
  private final Integer retriesRemaining;

  public IdpAsyncProcessor(
    List<DocumentInput> documents,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    this(documents, mappingSetName, mode, findingHandler, MAX_RETRIES);
  }

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

  /** Convenience: build, enqueue, return the job Id. */
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
