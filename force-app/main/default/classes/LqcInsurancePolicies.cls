/**
 * Prefill provider for the "Insurance Policies" LQC tab, backed by the FSC
 * Insurance data model (standard objects): InsurancePolicy records where the
 * Deceased (the Case's standard Account, Case.AccountId) is the Named Insured,
 * with the beneficiary resolved from InsurancePolicyParticipant.
 *
 * ------------------------------------------------------------------ FFLIB --
 * On FFLIB adoption: move both queries into an InsurancePoliciesSelector /
 * InsurancePolicyParticipantsSelector (fflib_SObjectSelector), resolved via
 * Application.Selector so tests stub them with fflib_ApexMocks; this class
 * keeps only the row-mapping. No DML here - persistence goes through
 * ILqcStorage, which should use fflib_ISObjectUnitOfWork when FFLIB lands.
 * ---------------------------------------------------------------------------
 */
public with sharing class LqcInsurancePolicies implements ILqcPrefill {

    @TestVisible
    private static final String BENEFICIARY_ROLE = 'Beneficiary';

    public List<Map<String, Object>> refresh(Id recordId) {
        Id deceasedId = LqcFscService.deceasedAccountId(recordId);

        List<InsurancePolicy> policies = [
            SELECT Id, Name, PolicyType, Status, PremiumAmount
            FROM InsurancePolicy
            WHERE NameInsuredId = :deceasedId
            WITH USER_MODE
            ORDER BY Name
        ];

        Map<Id, String> beneficiaryByPolicy = beneficiaryNames(policies);

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (InsurancePolicy policy : policies) {
            rows.add(new Map<String, Object>{
                'policyNumber' => policy.Name,
                'policyNumberRecordId' => policy.Id,
                'policyType' => policy.PolicyType,
                'status' => policy.Status,
                // TODO: PremiumAmount is a PLACEHOLDER. The cover amount lives
                // in your org's product design - typically a custom field such
                // as Sum_Insured__c on InsurancePolicy, or an aggregate over
                // the policy's InsurancePolicyCoverage records. Replace before
                // relying on the subtotal.
                'coverAmount' => policy.PremiumAmount,
                'beneficiary' => beneficiaryByPolicy.get(policy.Id)
            });
        }
        return rows;
    }

    /**
     * First active Beneficiary participant name per policy. Multiple
     * beneficiaries are joined with ", ".
     */
    private static Map<Id, String> beneficiaryNames(List<InsurancePolicy> policies) {
        Map<Id, String> names = new Map<Id, String>();
        if (policies.isEmpty()) {
            return names;
        }
        for (InsurancePolicyParticipant participant : [
            SELECT InsurancePolicyId, PrimaryParticipantAccount.Name
            FROM InsurancePolicyParticipant
            WHERE InsurancePolicyId IN :policies
            AND Role = :BENEFICIARY_ROLE
            WITH USER_MODE
            ORDER BY PrimaryParticipantAccount.Name
        ]) {
            String participantName = participant.PrimaryParticipantAccount?.Name;
            if (String.isBlank(participantName)) {
                continue;
            }
            String existing = names.get(participant.InsurancePolicyId);
            names.put(
                participant.InsurancePolicyId,
                existing == null ? participantName : existing + ', ' + participantName
            );
        }
        return names;
    }
}
