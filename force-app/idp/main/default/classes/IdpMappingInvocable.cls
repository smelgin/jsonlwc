/**
 * Flow / OmniScript entry point. Unlike v1, this is genuinely bulk: the
 * requests are grouped by (mapping set, mode, handler) and each group is
 * ONE engine run, so a Flow bulk-invoking 50 interviews costs the same
 * queries as one. Results come back in input order.
 */
public inherited sharing class IdpMappingInvocable {
  public class Request {
    @InvocableVariable(
      label='Content Document Id'
      description='Id of the reviewed file. Give this or a Record Id.'
    )
    public String contentDocumentId;

    @InvocableVariable(
      label='Record Id'
      description='Seed record to resolve context from, instead of a file.'
    )
    public String recordId;

    @InvocableVariable(
      required=true
      label='JSON String'
      description='The reviewed JSON, e.g. the jsonOutput of fileJsonReview.'
    )
    public String jsonString;

    @InvocableVariable(
      required=true
      label='Mapping Set Name'
      description='DeveloperName of the IDP_Mapping_Set__mdt to apply.'
    )
    public String mappingSetName;

    @InvocableVariable(
      label='Mode'
      description='Extraction (default), Compliance or Preview. A rule\'s Mode overrides this per field.'
    )
    public String mode;

    @InvocableVariable(
      label='Finding Handler Class'
      description='Apex class implementing IIdpFindingHandler, invoked when the run finds mismatches. Overrides the mapping set\'s default.'
    )
    public String findingHandler;
  }

  @InvocableMethod(
    label='Apply IDP Mapping Set'
    description='Extracts values from a reviewed JSON document into the Salesforce records reachable from it, checks them for compliance, or previews the changes — driven by IDP_Mapping_Set__mdt configuration.'
  )
  public static List<IdpResult.Result> apply(List<Request> requests) {
    List<IdpResult.Result> results = new List<IdpResult.Result>();
    Map<String, List<Integer>> groupIndexes = new Map<String, List<Integer>>();
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null); // placeholder, filled per group below
      Request request = requests[i];
      String groupKey =
        blank(request.mappingSetName) +
        '|' +
        blank(request.mode) +
        '|' +
        blank(request.findingHandler);
      if (!groupIndexes.containsKey(groupKey)) {
        groupIndexes.put(groupKey, new List<Integer>());
      }
      groupIndexes.get(groupKey).add(i);
    }

    for (List<Integer> indexes : groupIndexes.values()) {
      List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
      for (Integer index : indexes) {
        Request request = requests[index];
        IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
        work.contentDocumentId = asId(request.contentDocumentId);
        work.seedRecordId = asId(request.recordId);
        work.jsonString = request.jsonString;
        works.add(work);
      }
      Request first = requests[indexes[0]];
      List<IdpResult.Result> groupResults = IdpMappingEngine.run(
        works,
        first.mappingSetName,
        first.mode,
        first.findingHandler
      );
      for (Integer i = 0; i < indexes.size(); i++) {
        results[indexes[i]] = groupResults[i];
      }
    }
    return results;
  }

  private static String blank(String value) {
    return value == null ? '' : value;
  }

  private static Id asId(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    try {
      return Id.valueOf(value.trim());
    } catch (Exception e) {
      return null; // reported by the engine as INVALID_INPUT
    }
  }
}
