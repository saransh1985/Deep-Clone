/**
 * Purpose: Apex controller for Deep Clone, closing the old Facility and cloning supported related records.
 * Author: Saransh
 */
global with sharing class DeepCloneController implements Callable, Queueable {
  private static final String ACCOUNT_OBJECT = 'Account';
  private static final String IDENTIFIER_OBJECT = 'Identifier';
  private static final String HEALTHCARE_FACILITY_OBJECT = 'HealthcareFacility';
  private static final String RELATION_OBJECT = 'HealthCloudGA__AccountAccountRelation__c';
  private static final String RELATION_ROLE_OBJECT = 'HealthCloudGA__ReciprocalRole__c';
  private static final String RELATION_ROLE_NAME = 'Deep Clone Replacement Facility';
  private static final String RELATION_INVERSE_ROLE_NAME = 'Deep Clone Source Facility';
  private static Map<String, Schema.SObjectType> globalDescribeCache;
  private static Map<String, Schema.DescribeSObjectResult> objectDescribeCache = new Map<String, Schema.DescribeSObjectResult>();
  private static Map<String, Map<String, Schema.SObjectField>> fieldMapCache = new Map<String, Map<String, Schema.SObjectField>>();
  private Id queuedRecordId;
  private String queuedRequestJson;
  private String queuedNotificationEmail;

  @TestVisible
  private static Boolean bypassFacilityCheckForTests = false;

  @TestVisible
  private static Boolean forceFailureForTests = false;

  /**
   * Purpose: Allows Lightning, OmniStudio, and Salesforce runtime services to create this controller when needed.
   */
  global DeepCloneController() {
  }

  /**
   * Purpose: Stores one Integration Procedure request so the Queueable job can run Deep Clone after the IP returns.
   */
  private DeepCloneController(
    Id recordId,
    CloneRequest request,
    String notificationEmail
  ) {
    queuedRecordId = recordId;
    queuedRequestJson = JSON.serialize(request);
    queuedNotificationEmail = trimToNull(notificationEmail);
  }

  public class CloneRequest {
    @AuraEnabled
    public Boolean wdfaChanging { get; set; }
    @AuraEnabled
    public String newWdfa { get; set; }
    @AuraEnabled
    public Boolean facilityIdChanging { get; set; }
    @AuraEnabled
    public String newFacilityId { get; set; }
    @AuraEnabled
    public Boolean acpNumberChanging { get; set; }
    @AuraEnabled
    public String newAcpNumber { get; set; }
    @AuraEnabled
    public Boolean dsrIdChanging { get; set; }
    @AuraEnabled
    public String newDsrId { get; set; }
  }

  public class CloneContext {
    @AuraEnabled
    public Id accountId { get; set; }
    @AuraEnabled
    public String accountName { get; set; }
    @AuraEnabled
    public Boolean isFacility { get; set; }
    @AuraEnabled
    public String recordTypeDeveloperName { get; set; }
    @AuraEnabled
    public String recordTypeName { get; set; }
    @AuraEnabled
    public String wdfa { get; set; }
    @AuraEnabled
    public String facilityId { get; set; }
    @AuraEnabled
    public String acpNumber { get; set; }
    @AuraEnabled
    public String dsrId { get; set; }
  }

  public class CloneStep {
    @AuraEnabled
    public String name { get; set; }
    @AuraEnabled
    public Integer count { get; set; }

    /**
     * Purpose: Stores one progress step name and record count for display in the LWC progress modal.
     */
    public CloneStep(String name, Integer count) {
      this.name = name;
      this.count = count;
    }
  }

  public class CloneResult {
    @AuraEnabled
    public Id newAccountId { get; set; }
    @AuraEnabled
    public String message { get; set; }
    @AuraEnabled
    public List<CloneStep> steps { get; set; }
  }

  private class ChildCloneConfig {
    String objectName;
    String accountField;
    List<String> endFields = new List<String>();
    List<String> startFields = new List<String>();
    List<String> cloneClearFields = new List<String>();
    Map<String, Object> oldValues = new Map<String, Object>();
    Map<String, Object> newValues = new Map<String, Object>();
    Map<String, String> endFieldMustBeAfterFields = new Map<String, String>();
    Boolean hierarchyClone = false;

    /**
     * Purpose: Defines which child object and Account lookup field should be used for one clone operation.
     */
    ChildCloneConfig(String objectName, String accountField) {
      this.objectName = objectName;
      this.accountField = accountField;
    }
  }

  private class IdentifierHistoryChanges {
    List<SObject> recordsToInsert = new List<SObject>();
    List<SObject> recordsToUpdate = new List<SObject>();
    Set<Id> updateIds = new Set<Id>();
    Integer skippedCount = 0;

    /**
     * Purpose: Counts Identifier rows that were inserted, updated, or intentionally reused.
     */
    Integer totalCount() {
      return recordsToInsert.size() + recordsToUpdate.size() + skippedCount;
    }
  }

  private class CloneException extends Exception {
  }

  /**
   * Purpose: Lets an OmniStudio Integration Procedure call Deep Clone as a Remote Action through System.Callable.
   */
  global Object call(String action, Map<String, Object> args) {
    Map<String, Object> output = getCallableMap(args, 'output');
    Map<String, Object> response;
    try {
      response = handleCallableAction(action, args);
    } catch (Exception ex) {
      response = buildFailureResponse(formatCloneFailureMessage(ex));
    }
    output.putAll(response);
    return response;
  }

  /**
   * Purpose: Runs an Integration Procedure-started Deep Clone after the IP returns a Queueable job id.
   */
  global void execute(QueueableContext context) {
    String jobId = context == null ? null : context.getJobId();
    try {
      CloneResult result = runCloneFacility(
        queuedRecordId,
        deserializeQueuedRequest()
      );
      sendQueueCompletionEmail(true, jobId, result, null);
    } catch (Exception ex) {
      sendQueueCompletionEmail(
        false,
        jobId,
        null,
        formatCloneFailureMessage(ex)
      );
    }
  }

  /**
   * Purpose: Loads the selected Account details and confirms whether it is a Facility before the LWC allows cloning.
   */
  @AuraEnabled(cacheable=true)
  public static CloneContext getContext(Id recordId) {
    if (recordId == null) {
      throw new AuraHandledException('Account Id is required.');
    }

    try {
      Set<String> fields = new Set<String>{
        'Id',
        'Name',
        'RecordTypeId',
        'eHS_WDFA__c',
        'eHS_Facility_Id__c',
        'eHS_ACPNumber__c',
        'eHS_Source_System_Id__c'
      };
      SObject accountRecord = querySingleRecord(
        ACCOUNT_OBJECT,
        recordId,
        fields
      );
      CloneContext context = new CloneContext();
      context.accountId = recordId;
      context.accountName = getString(accountRecord, 'Name');
      context.wdfa = getString(accountRecord, 'eHS_WDFA__c');
      context.facilityId = getString(accountRecord, 'eHS_Facility_Id__c');
      context.acpNumber = getString(accountRecord, 'eHS_ACPNumber__c');
      context.dsrId = getString(accountRecord, 'eHS_Source_System_Id__c');

      Id recordTypeId = getId(accountRecord, 'RecordTypeId');
      if (recordTypeId != null) {
        Schema.RecordTypeInfo recordType = getRecordTypeInfo(
          ACCOUNT_OBJECT,
          recordTypeId
        );
        if (recordType != null) {
          context.recordTypeDeveloperName = recordType.getDeveloperName();
          context.recordTypeName = recordType.getName();
        }
      }

      context.isFacility =
        bypassFacilityCheckForTests ||
        context.recordTypeDeveloperName == 'Facility' ||
        context.recordTypeName == 'Facility';
      return context;
    } catch (Exception ex) {
      throw new AuraHandledException(
        'Unable to load Deep Clone context: ' + ex.getMessage()
      );
    }
  }

  /**
   * Purpose: Runs the full Deep Clone transaction and rolls back every change if any step fails.
   */
  @AuraEnabled
  public static CloneResult cloneFacility(Id recordId, CloneRequest request) {
    try {
      return runCloneFacility(recordId, request);
    } catch (Exception ex) {
      if (Test.isRunningTest()) {
        throw ex;
      }
      throw new AuraHandledException(formatCloneFailureMessage(ex));
    }
  }

  /**
   * Purpose: Runs the shared Deep Clone transaction used by both the LWC and Integration Procedure entry points.
   */
  private static CloneResult runCloneFacility(
    Id recordId,
    CloneRequest request
  ) {
    if (recordId == null) {
      throw new CloneException('Account Id is required.');
    }

    Savepoint savepoint = Database.setSavepoint();
    try {
      validateRequest(request);

      Datetime nowValue = Datetime.now();
      Date today = Date.today();
      CloneResult result = new CloneResult();
      result.steps = new List<CloneStep>();

      SObject oldAccount = querySingleRecord(
        ACCOUNT_OBJECT,
        recordId,
        getCloneQueryFields(ACCOUNT_OBJECT)
      );
      ensureFacilityRecordType(oldAccount);

      String identifierAuthoritySourceSystemId = buildIdentifierAuthoritySourceSystemId(
        oldAccount
      );
      List<SObject> identifiers = buildIdentifierRecords(
        oldAccount,
        request,
        nowValue,
        identifierAuthoritySourceSystemId
      );
      updateIdentifierAuthoritySourceSystemId(
        recordId,
        identifiers,
        identifierAuthoritySourceSystemId
      );
      IdentifierHistoryChanges identifierChanges = prepareIdentifierHistoryChanges(
        identifiers
      );
      saveRecords(
        identifierChanges.recordsToUpdate,
        true,
        'ending existing identifier history'
      );
      saveRecords(
        identifierChanges.recordsToInsert,
        false,
        'creating identifier history'
      );

      SObject oldAccountUpdate = newSObject(ACCOUNT_OBJECT);
      oldAccountUpdate.put('Id', recordId);
      setUpdateValue(oldAccountUpdate, 'EndDate', nowValue);
      setUpdateValue(oldAccountUpdate, 'eHS_Status__c', 'Closed');
      setUpdateValue(oldAccountUpdate, 'IsActive', false);
      setUpdateValue(oldAccountUpdate, 'HealthCloudGA__Active__c', 'No');
      setUpdateValue(oldAccountUpdate, 'eHS_WDFA__c', null);
      setUpdateValue(oldAccountUpdate, 'eHS_Facility_Id__c', null);
      setUpdateValue(oldAccountUpdate, 'eHS_ACPNumber__c', null);
      setUpdateValue(oldAccountUpdate, 'eHS_Source_System_Id__c', null);
      saveRecords(
        new List<SObject>{ oldAccountUpdate },
        true,
        'closing the old facility'
      );
      Integer healthcareFacilityCount = deleteOldHealthcareFacilities(recordId);

      SObject newAccount = newSObject(ACCOUNT_OBJECT);
      copyCreateableFields(oldAccount, newAccount);
      setCreateValue(newAccount, 'EndDate', null);
      setCreateValue(newAccount, 'EffectiveDate', nowValue);
      setCreateValue(newAccount, 'IsActive', true);
      setCreateValue(newAccount, 'HealthCloudGA__Active__c', 'Yes');
      applyRequestedIdentifierValues(oldAccount, newAccount, request);
      saveRecords(
        new List<SObject>{ newAccount },
        false,
        'creating the new facility',
        true
      );

      Id newAccountId = (Id) newAccount.get('Id');
      result.newAccountId = newAccountId;
      result.steps.add(new CloneStep('Facility', 1));
      result.steps.add(
        new CloneStep('Identifiers', identifierChanges.totalCount())
      );
      result.steps.add(
        new CloneStep('Healthcare Facilities', healthcareFacilityCount)
      );

      Integer relationCount = createAccountRelationships(
        recordId,
        newAccountId,
        today
      );
      result.steps.add(new CloneStep('Account Relationships', relationCount));

      Integer careProgramCount = cloneSimpleChildren(
        buildCareProgramTeamMemberConfig(),
        recordId,
        newAccountId,
        today,
        nowValue
      );
      result.steps.add(
        new CloneStep('Care Program Team Members', careProgramCount)
      );

      Integer practitionerFacilityCount = cloneSimpleChildren(
        buildHealthcarePractitionerFacilityConfig(),
        recordId,
        newAccountId,
        today,
        nowValue
      );
      result.steps.add(
        new CloneStep(
          'Healthcare Practitioner Facilities',
          practitionerFacilityCount
        )
      );

      Integer businessLicenseCount = cloneSimpleChildren(
        buildBusinessLicenseConfig(),
        recordId,
        newAccountId,
        today,
        nowValue
      );
      result.steps.add(
        new CloneStep('Business Licenses', businessLicenseCount)
      );

      Integer assetCount = cloneAssets(
        buildAssetConfig(),
        recordId,
        newAccountId,
        today,
        nowValue
      );
      result.steps.add(new CloneStep('Assets', assetCount));

      if (forceFailureForTests) {
        throw new CloneException('Forced rollback test failure.');
      }

      result.message = 'Deep Clone completed successfully.';
      return result;
    } catch (Exception ex) {
      Database.rollback(savepoint);
      throw ex;
    }
  }

  /**
   * Purpose: Submits one Deep Clone request to the async queue for Integration Procedure callers.
   */
  public static Id enqueueCloneFacility(
    Id recordId,
    CloneRequest request,
    String notificationEmail
  ) {
    if (recordId == null) {
      throw new CloneException('Account Id is required.');
    }
    validateRequest(request);
    return System.enqueueJob(
      new DeepCloneController(recordId, request, notificationEmail)
    );
  }

  /**
   * Purpose: Routes supported Integration Procedure actions to either a Queueable Deep Clone or a synchronous clone.
   */
  private static Map<String, Object> handleCallableAction(
    String action,
    Map<String, Object> args
  ) {
    String normalizedAction = normalizeAction(action);
    if (!isDeepCloneCallableAction(normalizedAction)) {
      throw new CloneException(
        'Unsupported Deep Clone callable action: ' + action
      );
    }

    Map<String, Object> input = getCallableMap(args, 'input');
    Map<String, Object> options = getCallableMap(args, 'options');
    Boolean defaultRunAsync = !isSynchronousCallableAction(normalizedAction);
    Object batchValue = firstValue(
      input,
      new List<String>{ 'requests', 'facilities', 'records', 'items' }
    );

    if (batchValue != null) {
      return submitCallableBatch(batchValue, options, defaultRunAsync);
    }
    return submitCallableRequest(input, options, defaultRunAsync);
  }

  /**
   * Purpose: Handles an Integration Procedure payload containing multiple Facility clone requests.
   */
  private static Map<String, Object> submitCallableBatch(
    Object batchValue,
    Map<String, Object> options,
    Boolean defaultRunAsync
  ) {
    List<Object> items = toObjectList(batchValue);
    List<Object> itemResponses = new List<Object>();
    Integer successCount = 0;
    Integer failureCount = 0;

    for (Object item : items) {
      try {
        Map<String, Object> itemInput = toStringObjectMap(item);
        if (itemInput.isEmpty()) {
          throw new CloneException(
            'Each Deep Clone batch item must be an object.'
          );
        }
        Map<String, Object> itemResponse = submitCallableRequest(
          itemInput,
          options,
          defaultRunAsync
        );
        itemResponses.add(itemResponse);
        if ((Boolean) itemResponse.get('success') == true) {
          successCount++;
        } else {
          failureCount++;
        }
      } catch (Exception ex) {
        failureCount++;
        itemResponses.add(buildFailureResponse(formatCloneFailureMessage(ex)));
      }
    }

    Map<String, Object> response = new Map<String, Object>();
    response.put('success', failureCount == 0);
    response.put('queued', defaultRunAsync);
    response.put('successCount', successCount);
    response.put('failureCount', failureCount);
    response.put('results', itemResponses);
    response.put(
      'message',
      'Deep Clone batch accepted. Successes: ' +
        successCount +
        ', Failures: ' +
        failureCount +
        '.'
    );
    return response;
  }

  /**
   * Purpose: Submits one Integration Procedure Deep Clone request and returns either a job id or clone result.
   */
  private static Map<String, Object> submitCallableRequest(
    Map<String, Object> input,
    Map<String, Object> options,
    Boolean defaultRunAsync
  ) {
    Id recordId = readCallableRecordId(input);
    CloneRequest request = buildCloneRequestFromCallable(input, recordId);
    Boolean runAsync = readRunAsync(input, options, defaultRunAsync);
    String notificationEmail = firstNonBlank(
      readStringValue(
        input,
        new List<String>{ 'notificationEmail', 'email', 'notifyEmail' }
      ),
      readStringValue(
        options,
        new List<String>{ 'notificationEmail', 'email', 'notifyEmail' }
      )
    );

    if (runAsync == true) {
      Id jobId = enqueueCloneFacility(recordId, request, notificationEmail);
      return buildQueuedResponse(recordId, jobId);
    }

    CloneResult result = runCloneFacility(recordId, request);
    return buildSynchronousResponse(recordId, result);
  }

  /**
   * Purpose: Creates the CloneRequest object from IP input, supporting both nested request values and top-level payload values.
   */
  private static CloneRequest buildCloneRequestFromCallable(
    Map<String, Object> input,
    Id recordId
  ) {
    Map<String, Object> values = callableRequestValues(input);
    CloneRequest request = new CloneRequest();
    request.newWdfa = readStringValue(
      values,
      new List<String>{ 'newWdfa', 'wdfa', 'eHS_WDFA__c' }
    );
    request.newFacilityId = readStringValue(
      values,
      new List<String>{
        'newFacilityId',
        'facilityIdentifier',
        'facilityId',
        'eHS_Facility_Id__c'
      }
    );
    request.newAcpNumber = readStringValue(
      values,
      new List<String>{ 'newAcpNumber', 'acpNumber', 'eHS_ACPNumber__c' }
    );
    request.newDsrId = readStringValue(
      values,
      new List<String>{
        'newDsrId',
        'dsrId',
        'eHS_Source_System_Id__c',
        'sourceSystemIdentifier'
      }
    );

    Boolean explicitWdfaChanging = readBooleanValue(
      values,
      new List<String>{ 'wdfaChanging', 'isWdfaChanging', 'changeWdfa' }
    );
    Boolean explicitFacilityIdChanging = readBooleanValue(
      values,
      new List<String>{
        'facilityIdChanging',
        'isFacilityIdChanging',
        'changeFacilityId'
      }
    );
    Boolean explicitAcpNumberChanging = readBooleanValue(
      values,
      new List<String>{
        'acpNumberChanging',
        'isAcpNumberChanging',
        'changeAcpNumber'
      }
    );
    Boolean explicitDsrIdChanging = readBooleanValue(
      values,
      new List<String>{ 'dsrIdChanging', 'isDsrIdChanging', 'changeDsrId' }
    );

    SObject oldAccount = needsCallableComparison(
        explicitWdfaChanging,
        request.newWdfa
      ) ||
      needsCallableComparison(
        explicitFacilityIdChanging,
        request.newFacilityId
      ) ||
      needsCallableComparison(
        explicitAcpNumberChanging,
        request.newAcpNumber
      ) ||
      needsCallableComparison(explicitDsrIdChanging, request.newDsrId)
      ? querySingleRecord(
          ACCOUNT_OBJECT,
          recordId,
          new Set<String>{
            'Id',
            'eHS_WDFA__c',
            'eHS_Facility_Id__c',
            'eHS_ACPNumber__c',
            'eHS_Source_System_Id__c'
          }
        )
      : null;

    request.wdfaChanging = resolveCallableChangeFlag(
      explicitWdfaChanging,
      request.newWdfa,
      oldAccount,
      'eHS_WDFA__c'
    );
    request.facilityIdChanging = resolveCallableChangeFlag(
      explicitFacilityIdChanging,
      request.newFacilityId,
      oldAccount,
      'eHS_Facility_Id__c'
    );
    request.acpNumberChanging = resolveCallableChangeFlag(
      explicitAcpNumberChanging,
      request.newAcpNumber,
      oldAccount,
      'eHS_ACPNumber__c'
    );
    request.dsrIdChanging = resolveCallableChangeFlag(
      explicitDsrIdChanging,
      request.newDsrId,
      oldAccount,
      'eHS_Source_System_Id__c'
    );
    return request;
  }

  /**
   * Purpose: Merges top-level IP payload values with a nested request object when the IP sends one.
   */
  private static Map<String, Object> callableRequestValues(
    Map<String, Object> input
  ) {
    Map<String, Object> values = new Map<String, Object>();
    if (input != null) {
      values.putAll(input);
      values.putAll(
        toStringObjectMap(
          firstValue(
            input,
            new List<String>{ 'request', 'cloneRequest', 'deepCloneRequest' }
          )
        )
      );
    }
    return values;
  }

  /**
   * Purpose: Identifies when the IP did not send an explicit change flag but did send a replacement value to compare.
   */
  private static Boolean needsCallableComparison(
    Boolean explicitChangeFlag,
    String newValue
  ) {
    return explicitChangeFlag == null && !String.isBlank(newValue);
  }

  /**
   * Purpose: Resolves an IP change flag by honoring explicit flags first and otherwise comparing new payload values to the Account.
   */
  private static Boolean resolveCallableChangeFlag(
    Boolean explicitChangeFlag,
    String newValue,
    SObject oldAccount,
    String accountField
  ) {
    if (explicitChangeFlag != null) {
      return explicitChangeFlag;
    }
    String normalizedNewValue = trimToNull(newValue);
    if (normalizedNewValue == null) {
      return false;
    }
    return normalizedNewValue !=
      trimToNull(getString(oldAccount, accountField));
  }

  /**
   * Purpose: Reads the Account Id that the IP must pass as recordId, accountId, oldAccountId, facilityAccountId, or Id.
   */
  private static Id readCallableRecordId(Map<String, Object> input) {
    String recordIdValue = readStringValue(
      input,
      new List<String>{
        'recordId',
        'accountId',
        'oldAccountId',
        'facilityAccountId',
        'Id'
      }
    );
    if (String.isBlank(recordIdValue)) {
      throw new CloneException(
        'Account Id is required. Pass recordId or accountId to the Deep Clone callable action.'
      );
    }
    try {
      return (Id) recordIdValue;
    } catch (Exception ex) {
      throw new CloneException(
        'Account Id must be a valid Salesforce Id: ' + recordIdValue
      );
    }
  }

  /**
   * Purpose: Reads whether an IP request should run async, defaulting to Queueable for IP calls.
   */
  private static Boolean readRunAsync(
    Map<String, Object> input,
    Map<String, Object> options,
    Boolean defaultRunAsync
  ) {
    Boolean inputValue = readBooleanValue(
      input,
      new List<String>{ 'runAsync', 'async', 'queueable' }
    );
    if (inputValue != null) {
      return inputValue;
    }
    Boolean optionValue = readBooleanValue(
      options,
      new List<String>{ 'runAsync', 'async', 'queueable' }
    );
    return optionValue == null ? defaultRunAsync : optionValue;
  }

  /**
   * Purpose: Returns the request stored on this Queueable job.
   */
  private CloneRequest deserializeQueuedRequest() {
    if (String.isBlank(queuedRequestJson)) {
      return new CloneRequest();
    }
    return (CloneRequest) JSON.deserialize(
      queuedRequestJson,
      CloneRequest.class
    );
  }

  /**
   * Purpose: Sends an optional completion or failure email for an IP-started Queueable Deep Clone.
   */
  private void sendQueueCompletionEmail(
    Boolean success,
    String jobId,
    CloneResult result,
    String errorMessage
  ) {
    if (String.isBlank(queuedNotificationEmail)) {
      return;
    }

    try {
      Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
      email.setToAddresses(new List<String>{ queuedNotificationEmail });
      email.setSubject(
        success == true ? 'Deep Clone completed' : 'Deep Clone failed'
      );
      email.setPlainTextBody(
        buildQueueCompletionEmailBody(success, jobId, result, errorMessage)
      );
      Messaging.sendEmail(
        new List<Messaging.SingleEmailMessage>{ email },
        false
      );
    } catch (Exception ex) {
      return;
    }
  }

  /**
   * Purpose: Builds the text body used by optional Queueable completion emails.
   */
  private String buildQueueCompletionEmailBody(
    Boolean success,
    String jobId,
    CloneResult result,
    String errorMessage
  ) {
    List<String> lines = new List<String>();
    lines.add(success == true ? 'Deep Clone completed.' : 'Deep Clone failed.');
    lines.add('Queueable Job Id: ' + String.valueOf(jobId));
    lines.add('Old Facility Account Id: ' + String.valueOf(queuedRecordId));
    if (result != null) {
      lines.add(
        'New Facility Account Id: ' + String.valueOf(result.newAccountId)
      );
      lines.add('Message: ' + result.message);
      lines.add('Steps: ' + queueStepSummary(result.steps));
    }
    if (!String.isBlank(errorMessage)) {
      lines.add('Error: ' + errorMessage);
    }
    return String.join(lines, '\n');
  }

  /**
   * Purpose: Converts clone step counts into one compact line for Queueable completion emails.
   */
  private static String queueStepSummary(List<CloneStep> steps) {
    if (steps == null || steps.isEmpty()) {
      return 'No step counts returned.';
    }
    List<String> summaries = new List<String>();
    for (CloneStep step : steps) {
      summaries.add(step.name + '=' + step.count);
    }
    return String.join(summaries, ', ');
  }

  /**
   * Purpose: Builds the response returned to an IP when Deep Clone has been queued.
   */
  private static Map<String, Object> buildQueuedResponse(
    Id recordId,
    Id jobId
  ) {
    Map<String, Object> response = buildSuccessResponse(true);
    response.put('recordId', String.valueOf(recordId));
    response.put('jobId', String.valueOf(jobId));
    response.put(
      'message',
      'Deep Clone has been queued. Check Apex Jobs with job id ' +
        String.valueOf(jobId) +
        '.'
    );
    return response;
  }

  /**
   * Purpose: Builds the response returned to an IP when Deep Clone is intentionally run synchronously.
   */
  private static Map<String, Object> buildSynchronousResponse(
    Id recordId,
    CloneResult result
  ) {
    Map<String, Object> response = buildSuccessResponse(false);
    response.put('recordId', String.valueOf(recordId));
    response.putAll(
      (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(result))
    );
    return response;
  }

  /**
   * Purpose: Creates a standard success response for IP callers.
   */
  private static Map<String, Object> buildSuccessResponse(Boolean queued) {
    Map<String, Object> response = new Map<String, Object>();
    response.put('success', true);
    response.put('queued', queued);
    return response;
  }

  /**
   * Purpose: Creates a standard failure response for IP callers without throwing away the readable error message.
   */
  private static Map<String, Object> buildFailureResponse(String message) {
    Map<String, Object> response = new Map<String, Object>();
    response.put('success', false);
    response.put('queued', false);
    response.put('message', message);
    response.put('errorMessage', message);
    return response;
  }

  /**
   * Purpose: Normalizes callable action names so IP designers can use readable action labels.
   */
  private static String normalizeAction(String action) {
    return String.isBlank(action)
      ? 'deepclone'
      : action.replaceAll('[^A-Za-z0-9]', '').toLowerCase();
  }

  /**
   * Purpose: Confirms whether a callable action name should run Deep Clone.
   */
  private static Boolean isDeepCloneCallableAction(String normalizedAction) {
    return new Set<String>{
        'deepclone',
        'startdeepclone',
        'clonefacility',
        'enqueuedeepclone',
        'enqueuedeepclonefacility',
        'deepclonesync',
        'clonefacilitysync'
      }
      .contains(normalizedAction);
  }

  /**
   * Purpose: Identifies the explicit callable actions that should run synchronously instead of queueing.
   */
  private static Boolean isSynchronousCallableAction(String normalizedAction) {
    return new Set<String>{ 'deepclonesync', 'clonefacilitysync' }
      .contains(normalizedAction);
  }

  /**
   * Purpose: Reads one of the standard OmniStudio Callable maps such as input, output, or options.
   */
  private static Map<String, Object> getCallableMap(
    Map<String, Object> args,
    String key
  ) {
    if (args == null) {
      return new Map<String, Object>();
    }
    return toStringObjectMap(args.get(key));
  }

  /**
   * Purpose: Converts an untyped IP object into a string-keyed map when possible.
   */
  private static Map<String, Object> toStringObjectMap(Object value) {
    if (value == null) {
      return new Map<String, Object>();
    }
    try {
      return (Map<String, Object>) value;
    } catch (Exception ex) {
      Object untyped = JSON.deserializeUntyped(JSON.serialize(value));
      try {
        return (Map<String, Object>) untyped;
      } catch (Exception innerEx) {
        return new Map<String, Object>();
      }
    }
  }

  /**
   * Purpose: Converts an untyped IP batch value into a list of request objects.
   */
  private static List<Object> toObjectList(Object value) {
    if (value == null) {
      return new List<Object>();
    }
    try {
      return (List<Object>) value;
    } catch (Exception ex) {
      Object untyped = JSON.deserializeUntyped(JSON.serialize(value));
      try {
        return (List<Object>) untyped;
      } catch (Exception innerEx) {
        throw new CloneException(
          'Batch Deep Clone requests must be passed as a list.'
        );
      }
    }
  }

  /**
   * Purpose: Reads the first matching value from a map while allowing case-insensitive IP payload keys.
   */
  private static Object firstValue(
    Map<String, Object> values,
    List<String> keys
  ) {
    if (values == null || values.isEmpty() || keys == null || keys.isEmpty()) {
      return null;
    }
    for (String key : keys) {
      if (values.containsKey(key)) {
        return values.get(key);
      }
    }

    Map<String, String> actualKeysByLower = new Map<String, String>();
    for (String actualKey : values.keySet()) {
      actualKeysByLower.put(actualKey.toLowerCase(), actualKey);
    }
    for (String key : keys) {
      String actualKey = actualKeysByLower.get(key.toLowerCase());
      if (actualKey != null) {
        return values.get(actualKey);
      }
    }
    return null;
  }

  /**
   * Purpose: Reads a string value from IP input and treats blanks as null.
   */
  private static String readStringValue(
    Map<String, Object> values,
    List<String> keys
  ) {
    Object value = firstValue(values, keys);
    if (value == null) {
      return null;
    }
    return trimToNull(String.valueOf(value));
  }

  /**
   * Purpose: Reads a boolean value from IP input, accepting true/false, yes/no, y/n, and 1/0.
   */
  private static Boolean readBooleanValue(
    Map<String, Object> values,
    List<String> keys
  ) {
    Object value = firstValue(values, keys);
    if (value == null) {
      return null;
    }
    if (value instanceof Boolean) {
      return (Boolean) value;
    }

    String textValue = String.valueOf(value).trim().toLowerCase();
    if (String.isBlank(textValue)) {
      return null;
    }
    if (new Set<String>{ 'true', 'yes', 'y', '1' }.contains(textValue)) {
      return true;
    }
    if (new Set<String>{ 'false', 'no', 'n', '0' }.contains(textValue)) {
      return false;
    }
    throw new CloneException(
      'Invalid boolean value for ' +
        (keys == null || keys.isEmpty() ? 'field' : keys[0]) +
        ': ' +
        String.valueOf(value)
    );
  }

  /**
   * Purpose: Formats clone failures consistently for LWC, Integration Procedure, and Queueable email paths.
   */
  private static String formatCloneFailureMessage(Exception ex) {
    String message = ex == null ? null : ex.getMessage();
    if (String.isBlank(message)) {
      message = 'Unexpected error.';
    }
    if (message.startsWith('Deep Clone failed.')) {
      return message;
    }
    return 'Deep Clone failed. All changes were rolled back. ' + message;
  }

  /**
   * Purpose: Validates that the LWC sent a request and that every changed identifier includes a new value.
   */
  private static void validateRequest(CloneRequest request) {
    if (request == null) {
      throw new CloneException('Deep Clone request is required.');
    }
    requireNewValue(request.wdfaChanging, request.newWdfa, 'WDFA');
    requireNewValue(
      request.facilityIdChanging,
      request.newFacilityId,
      'Facility ID'
    );
    requireNewValue(
      request.acpNumberChanging,
      request.newAcpNumber,
      'ACP Number'
    );
    requireNewValue(request.dsrIdChanging, request.newDsrId, 'DSR ID');
  }

  /**
   * Purpose: Throws a clear error when a yes/no field is marked as changing but the replacement value is blank.
   */
  private static void requireNewValue(
    Boolean isChanging,
    String value,
    String label
  ) {
    if (isChanging == true && String.isBlank(value)) {
      throw new CloneException(
        label + ' is marked as changing. Enter the new value.'
      );
    }
  }

  /**
   * Purpose: Stops Deep Clone unless the selected Account record type is Facility.
   */
  private static void ensureFacilityRecordType(SObject oldAccount) {
    if (bypassFacilityCheckForTests) {
      return;
    }

    Id recordTypeId = getId(oldAccount, 'RecordTypeId');
    if (recordTypeId == null) {
      throw new CloneException(
        'Deep Clone can run only for Account record type Facility.'
      );
    }

    Schema.RecordTypeInfo recordType = getRecordTypeInfo(
      ACCOUNT_OBJECT,
      recordTypeId
    );
    if (
      recordType == null ||
      (recordType.getDeveloperName() != 'Facility' &&
      recordType.getName() != 'Facility')
    ) {
      throw new CloneException(
        'Deep Clone can run only for Account record type Facility.'
      );
    }
  }

  /**
   * Purpose: Creates Identifier history records for current WDFA, Facility ID, ACP Number, and DSR ID values.
   */
  private static List<SObject> buildIdentifierRecords(
    SObject oldAccount,
    CloneRequest request,
    Datetime nowValue,
    String authoritySourceSystemId
  ) {
    if (!hasObject(IDENTIFIER_OBJECT)) {
      return new List<SObject>();
    }

    List<SObject> identifiers = new List<SObject>();
    addIdentifier(
      identifiers,
      oldAccount,
      'eHS_WDFA__c',
      'DSR - WDFA',
      request.wdfaChanging == true,
      nowValue,
      authoritySourceSystemId
    );
    addIdentifier(
      identifiers,
      oldAccount,
      'eHS_Facility_Id__c',
      'DSR - Facility ID',
      request.facilityIdChanging == true,
      nowValue,
      authoritySourceSystemId
    );
    addIdentifier(
      identifiers,
      oldAccount,
      'eHS_ACPNumber__c',
      'DSR - ACP Number',
      request.acpNumberChanging == true,
      nowValue,
      authoritySourceSystemId
    );
    addIdentifier(
      identifiers,
      oldAccount,
      'eHS_Source_System_Id__c',
      'DSR - ID',
      request.dsrIdChanging == true,
      nowValue,
      authoritySourceSystemId
    );
    return identifiers;
  }

  /**
   * Purpose: Adds one Identifier history row for a nonblank old Account identifier value.
   */
  private static void addIdentifier(
    List<SObject> identifiers,
    SObject oldAccount,
    String accountField,
    String usageType,
    Boolean isChanging,
    Datetime nowValue,
    String authoritySourceSystemId
  ) {
    String value = getString(oldAccount, accountField);
    if (String.isBlank(value)) {
      return;
    }

    SObject identifier = newSObject(IDENTIFIER_OBJECT);
    setCreateValue(identifier, 'ParentRecordId', (Id) oldAccount.get('Id'));
    setCreateValue(identifier, 'IssuingAuthorityId', (Id) oldAccount.get('Id'));
    setCreateValue(identifier, 'IdValue', value);
    setCreateValue(identifier, 'IdUsageType', usageType);
    setCreateValue(identifier, 'EffectiveDate', nowValue);
    setCreateValue(identifier, 'EndDate', isChanging == true ? nowValue : null);
    setCreateValue(
      identifier,
      'SourceSystem',
      firstNonBlank(getString(oldAccount, 'eHS_Source_System__c'), 'DSR')
    );
    setCreateValue(
      identifier,
      'SourceSystemIdentifier',
      getString(oldAccount, 'eHS_Source_System_Id__c')
    );
    setCreateValue(
      identifier,
      'eHS_Source_System_Id__c',
      buildIdentifierExternalKey(authoritySourceSystemId, usageType, value)
    );
    identifiers.add(identifier);
  }

  /**
   * Purpose: Temporarily gives the old Account a clone-specific source key so the Identifier flow creates unique history keys.
   */
  private static void updateIdentifierAuthoritySourceSystemId(
    Id recordId,
    List<SObject> identifiers,
    String authoritySourceSystemId
  ) {
    if (
      identifiers == null ||
      identifiers.isEmpty() ||
      String.isBlank(authoritySourceSystemId) ||
      !hasField(ACCOUNT_OBJECT, 'eHS_Source_System_Id__c') ||
      !getFieldDescribe(ACCOUNT_OBJECT, 'eHS_Source_System_Id__c').isUpdateable()
    ) {
      return;
    }

    SObject authorityUpdate = newSObject(ACCOUNT_OBJECT);
    authorityUpdate.put('Id', recordId);
    setUpdateValue(
      authorityUpdate,
      'eHS_Source_System_Id__c',
      authoritySourceSystemId
    );
    saveRecords(
      new List<SObject>{ authorityUpdate },
      true,
      'preparing identifier history authority'
    );
  }

  /**
   * Purpose: Splits Identifier history work into inserts, end-date updates, and duplicate-safe skips.
   */
  private static IdentifierHistoryChanges prepareIdentifierHistoryChanges(
    List<SObject> identifiers
  ) {
    IdentifierHistoryChanges changes = new IdentifierHistoryChanges();
    if (identifiers == null || identifiers.isEmpty()) {
      return changes;
    }

    Map<String, SObject> existingByLookupKey = queryExistingIdentifierHistory(
      identifiers
    );
    Set<String> pendingLookupKeys = new Set<String>();
    for (SObject identifier : identifiers) {
      String sourceKey = buildIdentifierSourceLookupKey(identifier);
      String parentValueKey = buildIdentifierParentValueLookupKey(identifier);
      SObject existing = firstExistingIdentifier(
        existingByLookupKey,
        sourceKey,
        parentValueKey
      );
      if (existing != null) {
        reuseExistingIdentifierHistory(changes, existing, identifier);
        continue;
      }

      if (
        (!String.isBlank(sourceKey) && pendingLookupKeys.contains(sourceKey)) ||
        (!String.isBlank(parentValueKey) &&
        pendingLookupKeys.contains(parentValueKey))
      ) {
        changes.skippedCount++;
        continue;
      }

      changes.recordsToInsert.add(identifier);
      if (!String.isBlank(sourceKey)) {
        pendingLookupKeys.add(sourceKey);
      }
      if (!String.isBlank(parentValueKey)) {
        pendingLookupKeys.add(parentValueKey);
      }
    }
    return changes;
  }

  /**
   * Purpose: Finds Identifier rows that would collide with the active Identifier key flow.
   */
  private static Map<String, SObject> queryExistingIdentifierHistory(
    List<SObject> identifiers
  ) {
    Map<String, SObject> existingByLookupKey = new Map<String, SObject>();
    Set<String> sourceKeys = new Set<String>();
    Set<Id> parentIds = new Set<Id>();
    Set<String> idValues = new Set<String>();
    collectIdentifierLookupValues(identifiers, sourceKeys, parentIds, idValues);

    List<String> conditions = new List<String>();
    if (
      !sourceKeys.isEmpty() &&
      hasField(IDENTIFIER_OBJECT, 'eHS_Source_System_Id__c')
    ) {
      conditions.add('eHS_Source_System_Id__c IN :sourceKeys');
    }
    if (!parentIds.isEmpty() && !idValues.isEmpty()) {
      conditions.add('(ParentRecordId IN :parentIds AND IdValue IN :idValues)');
    }
    if (conditions.isEmpty()) {
      return existingByLookupKey;
    }

    Set<String> fields = new Set<String>{
      'Id',
      'ParentRecordId',
      'IdValue',
      'EndDate',
      'eHS_Source_System_Id__c'
    };
    List<String> validFields = new List<String>();
    for (String fieldName : fields) {
      if (hasField(IDENTIFIER_OBJECT, fieldName)) {
        validFields.add(fieldName);
      }
    }
    validFields.sort();

    String soql =
      'SELECT ' +
      String.join(validFields, ', ') +
      ' FROM ' +
      IDENTIFIER_OBJECT +
      ' WHERE ' +
      String.join(conditions, ' OR ');
    for (SObject existing : Database.query(soql)) {
      addIdentifierLookup(existingByLookupKey, existing);
    }
    return existingByLookupKey;
  }

  /**
   * Purpose: Collects the flow-generated source keys and parent/value keys used to detect existing Identifier rows.
   */
  private static void collectIdentifierLookupValues(
    List<SObject> identifiers,
    Set<String> sourceKeys,
    Set<Id> parentIds,
    Set<String> idValues
  ) {
    for (SObject identifier : identifiers) {
      String sourceKey = getString(identifier, 'eHS_Source_System_Id__c');
      if (!String.isBlank(sourceKey)) {
        sourceKeys.add(sourceKey);
      }

      Id parentId = getId(identifier, 'ParentRecordId');
      String idValue = getString(identifier, 'IdValue');
      if (parentId != null && !String.isBlank(idValue)) {
        parentIds.add(parentId);
        idValues.add(idValue);
      }
    }
  }

  /**
   * Purpose: Stores every lookup key that can identify an existing Identifier history row.
   */
  private static void addIdentifierLookup(
    Map<String, SObject> existingByLookupKey,
    SObject existing
  ) {
    String sourceKey = buildIdentifierSourceLookupKey(existing);
    if (!String.isBlank(sourceKey)) {
      existingByLookupKey.put(sourceKey, existing);
    }

    String parentValueKey = buildIdentifierParentValueLookupKey(existing);
    if (!String.isBlank(parentValueKey)) {
      existingByLookupKey.put(parentValueKey, existing);
    }
  }

  /**
   * Purpose: Chooses the existing Identifier found by source key first, then by parent and value.
   */
  private static SObject firstExistingIdentifier(
    Map<String, SObject> existingByLookupKey,
    String sourceKey,
    String parentValueKey
  ) {
    if (
      !String.isBlank(sourceKey) && existingByLookupKey.containsKey(sourceKey)
    ) {
      return existingByLookupKey.get(sourceKey);
    }
    if (
      !String.isBlank(parentValueKey) &&
      existingByLookupKey.containsKey(parentValueKey)
    ) {
      return existingByLookupKey.get(parentValueKey);
    }
    return null;
  }

  /**
   * Purpose: Reuses an existing Identifier row and end-dates it when the cloned identifier is changing.
   */
  private static void reuseExistingIdentifierHistory(
    IdentifierHistoryChanges changes,
    SObject existing,
    SObject proposed
  ) {
    Object proposedEndDate = proposed.get('EndDate');
    if (proposedEndDate == null || existing.get('EndDate') != null) {
      changes.skippedCount++;
      return;
    }

    Id existingId = (Id) existing.get('Id');
    if (changes.updateIds.contains(existingId)) {
      changes.skippedCount++;
      return;
    }

    SObject updateRow = newSObject(IDENTIFIER_OBJECT);
    updateRow.put('Id', existingId);
    setUpdateValue(updateRow, 'EndDate', proposedEndDate);
    changes.recordsToUpdate.add(updateRow);
    changes.updateIds.add(existingId);
  }

  /**
   * Purpose: Builds the same unique external id that the org's Identifier before-save flow generates.
   */
  private static String buildIdentifierExternalKey(
    String authoritySourceSystemId,
    String usageType,
    String value
  ) {
    return limitLength(
      firstNonBlank(authoritySourceSystemId, value) + usageType + value,
      255
    );
  }

  /**
   * Purpose: Builds the temporary Account source id consumed by the Identifier before-save flow.
   */
  private static String buildIdentifierAuthoritySourceSystemId(
    SObject oldAccount
  ) {
    return limitLength(
      firstNonBlank(
        getString(oldAccount, 'eHS_Source_System_Id__c'),
        'DeepClone'
      ) +
        '-' +
        String.valueOf(oldAccount.get('Id')),
      120
    );
  }

  /**
   * Purpose: Builds a lookup key from the Identifier external id field.
   */
  private static String buildIdentifierSourceLookupKey(SObject identifier) {
    String sourceKey = getString(identifier, 'eHS_Source_System_Id__c');
    return String.isBlank(sourceKey) ? null : 'source:' + sourceKey;
  }

  /**
   * Purpose: Builds a lookup key matching the standard IdentifierKey parent/value uniqueness behavior.
   */
  private static String buildIdentifierParentValueLookupKey(
    SObject identifier
  ) {
    Id parentId = getId(identifier, 'ParentRecordId');
    String idValue = getString(identifier, 'IdValue');
    if (parentId == null || String.isBlank(idValue)) {
      return null;
    }
    return 'parentValue:' + String.valueOf(parentId) + ':' + idValue;
  }

  /**
   * Purpose: Puts either the user-entered replacement values or the old carry-forward values onto the new Account.
   */
  private static void applyRequestedIdentifierValues(
    SObject oldAccount,
    SObject newAccount,
    CloneRequest request
  ) {
    setCreateValue(
      newAccount,
      'eHS_WDFA__c',
      request.wdfaChanging == true
        ? trimToNull(request.newWdfa)
        : getString(oldAccount, 'eHS_WDFA__c')
    );
    setCreateValue(
      newAccount,
      'eHS_Facility_Id__c',
      request.facilityIdChanging == true
        ? trimToNull(request.newFacilityId)
        : getString(oldAccount, 'eHS_Facility_Id__c')
    );
    setCreateValue(
      newAccount,
      'eHS_ACPNumber__c',
      request.acpNumberChanging == true
        ? trimToNull(request.newAcpNumber)
        : getString(oldAccount, 'eHS_ACPNumber__c')
    );
    setCreateValue(
      newAccount,
      'eHS_Source_System_Id__c',
      request.dsrIdChanging == true
        ? trimToNull(request.newDsrId)
        : getString(oldAccount, 'eHS_Source_System_Id__c')
    );
  }

  /**
   * Purpose: Defines how CareProgramTeamMember rows are ended on the old Account and started on the new Account.
   */
  private static ChildCloneConfig buildCareProgramTeamMemberConfig() {
    ChildCloneConfig config = new ChildCloneConfig(
      'CareProgramTeamMember',
      'AccountId'
    );
    config.endFields.add('ehs_TeamMemberRoleEndDate__c');
    config.startFields.add('ehs_TeamMemberRoleStartDate__c');
    config.cloneClearFields.add('ehs_TeamMemberRoleEndDate__c');
    config.oldValues.put('eHS_Status__c', 'In Active');
    config.newValues.put('eHS_Status__c', 'Active');
    return config;
  }

  /**
   * Purpose: Defines how HealthcarePractitionerFacility rows are ended, cloned, and reconnected to the new HealthcareFacility.
   */
  private static ChildCloneConfig buildHealthcarePractitionerFacilityConfig() {
    ChildCloneConfig config = new ChildCloneConfig(
      'HealthcarePractitionerFacility',
      'AccountId'
    );
    config.endFields.add('EffectiveTo');
    config.endFields.add('TerminationDate');
    config.endFieldMustBeAfterFields.put('EffectiveTo', 'EffectiveFrom');
    config.startFields.add('EffectiveFrom');
    config.startFields.add('InitialStartDate');
    config.cloneClearFields.add('EffectiveTo');
    config.cloneClearFields.add('TerminationDate');
    config.oldValues.put('IsActive', false);
    config.newValues.put('IsActive', true);
    return config;
  }

  /**
   * Purpose: Defines how BusinessLicense rows are ended on the old Account and started on the new Account.
   */
  private static ChildCloneConfig buildBusinessLicenseConfig() {
    ChildCloneConfig config = new ChildCloneConfig(
      'BusinessLicense',
      'AccountId'
    );
    config.endFields.add('PeriodEnd');
    config.startFields.add('PeriodStart');
    config.cloneClearFields.add('PeriodEnd');
    config.oldValues.put('IsActive', false);
    config.newValues.put('IsActive', true);
    return config;
  }

  /**
   * Purpose: Defines how Asset rows are cloned, including parent-child hierarchy handling.
   */
  private static ChildCloneConfig buildAssetConfig() {
    ChildCloneConfig config = new ChildCloneConfig('Asset', 'AccountId');
    config.endFields.add('UsageEndDate');
    config.startFields.add('InstallDate');
    config.cloneClearFields.add('UsageEndDate');
    config.hierarchyClone = true;
    return config;
  }

  /**
   * Purpose: Clones non-hierarchical child records, clears old external ids, restores clone external ids, and writes chatter backup.
   */
  private static Integer cloneSimpleChildren(
    ChildCloneConfig config,
    Id oldAccountId,
    Id newAccountId,
    Date today,
    Datetime nowValue
  ) {
    if (!canCloneObject(config)) {
      return 0;
    }

    List<SObject> oldRows = queryChildRecords(config, oldAccountId);
    if (oldRows.isEmpty()) {
      return 0;
    }

    Id newHealthcareFacilityId = resolveNewHealthcareFacilityId(
      config,
      oldRows,
      newAccountId
    );
    List<SObject> updates = new List<SObject>();
    List<SObject> inserts = new List<SObject>();
    List<FeedItem> feedItems = new List<FeedItem>();

    for (SObject oldRow : oldRows) {
      String sourceSystemId = getString(oldRow, 'eHS_Source_System_Id__c');
      SObject oldUpdate = buildOldChildUpdate(config, oldRow, today, nowValue);
      updates.add(oldUpdate);

      SObject clone = newSObject(config.objectName);
      copyCreateableFields(oldRow, clone);
      setCreateValue(clone, config.accountField, newAccountId);
      applyNewChildValues(config, clone, today, nowValue);
      if (newHealthcareFacilityId != null) {
        setCreateValue(clone, 'HealthcareFacilityId', newHealthcareFacilityId);
      }
      setCreateValue(clone, 'eHS_Source_System_Id__c', sourceSystemId);
      inserts.add(clone);

      addSourceSystemFeed(feedItems, oldRow, config.objectName, sourceSystemId);
    }

    saveRecords(updates, true, 'ending old ' + config.objectName + ' records');
    saveRecords(
      inserts,
      false,
      'creating new ' + config.objectName + ' records'
    );
    saveFeedItems(feedItems, oldAccountId);
    return inserts.size();
  }

  /**
   * Purpose: Finds the HealthcareFacility created by the Account flow so cloned HCPF rows point to the new facility record.
   */
  private static Id resolveNewHealthcareFacilityId(
    ChildCloneConfig config,
    List<SObject> oldRows,
    Id newAccountId
  ) {
    if (
      config.objectName != 'HealthcarePractitionerFacility' ||
      !hasField(config.objectName, 'HealthcareFacilityId')
    ) {
      return null;
    }

    Boolean oldRowsUseHealthcareFacility = false;
    for (SObject oldRow : oldRows) {
      if (getId(oldRow, 'HealthcareFacilityId') != null) {
        oldRowsUseHealthcareFacility = true;
        break;
      }
    }
    if (!oldRowsUseHealthcareFacility) {
      return null;
    }

    Id healthcareFacilityId = findHealthcareFacilityIdByAccount(newAccountId);
    if (healthcareFacilityId == null) {
      throw new CloneException(
        'A HealthcareFacility record was not created for the new facility. Check eHS_Account_After_InsertUpdate_Flow and eHS_Upsert_HealthcareFacility_from_Account.'
      );
    }
    return healthcareFacilityId;
  }

  /**
   * Purpose: Queries the latest HealthcareFacility linked to the new Account after the Account flow runs.
   */
  @TestVisible
  private static Id findHealthcareFacilityIdByAccount(Id accountId) {
    if (
      accountId == null ||
      !hasObject('HealthcareFacility') ||
      !hasField('HealthcareFacility', 'AccountId')
    ) {
      return null;
    }
    if (!isObjectReadable('HealthcareFacility')) {
      throw new CloneException(
        'Missing read permission for HealthcareFacility.'
      );
    }
    if (!isFieldReadable('HealthcareFacility', 'AccountId')) {
      throw new CloneException(
        'Missing read permission for HealthcareFacility.AccountId.'
      );
    }

    List<SObject> facilities = Database.queryWithBinds(
      'SELECT Id FROM HealthcareFacility WHERE AccountId = :accountId ORDER BY LastModifiedDate DESC, CreatedDate DESC LIMIT 1',
      new Map<String, Object>{ 'accountId' => accountId },
      AccessLevel.USER_MODE
    );
    return facilities.isEmpty() ? null : (Id) facilities[0].get('Id');
  }

  /**
   * Purpose: Removes the old HealthcareFacility before the Account flow creates the replacement record for carried-forward identifiers.
   */
  private static Integer deleteOldHealthcareFacilities(Id oldAccountId) {
    if (
      oldAccountId == null ||
      !hasObject(HEALTHCARE_FACILITY_OBJECT) ||
      !hasField(HEALTHCARE_FACILITY_OBJECT, 'AccountId')
    ) {
      return 0;
    }
    if (!isObjectReadable(HEALTHCARE_FACILITY_OBJECT)) {
      throw new CloneException(
        'Missing read permission for HealthcareFacility.'
      );
    }
    if (!isObjectDeletable(HEALTHCARE_FACILITY_OBJECT)) {
      throw new CloneException(
        'Missing delete permission for HealthcareFacility.'
      );
    }
    if (!isFieldReadable(HEALTHCARE_FACILITY_OBJECT, 'AccountId')) {
      throw new CloneException(
        'Missing read permission for HealthcareFacility.AccountId.'
      );
    }

    List<SObject> oldHealthcareFacilities = Database.queryWithBinds(
      'SELECT Id FROM HealthcareFacility WHERE AccountId = :oldAccountId',
      new Map<String, Object>{ 'oldAccountId' => oldAccountId },
      AccessLevel.USER_MODE
    );
    deleteRecords(
      oldHealthcareFacilities,
      'removing old HealthcareFacility records'
    );
    return oldHealthcareFacilities.size();
  }

  /**
   * Purpose: Clones Asset records in parent-first order so child Assets can point to newly cloned parent Assets.
   */
  private static Integer cloneAssets(
    ChildCloneConfig config,
    Id oldAccountId,
    Id newAccountId,
    Date today,
    Datetime nowValue
  ) {
    if (!canCloneObject(config)) {
      return 0;
    }

    List<SObject> oldAssets = queryChildRecords(config, oldAccountId);
    if (oldAssets.isEmpty()) {
      return 0;
    }

    List<SObject> updates = new List<SObject>();
    List<FeedItem> feedItems = new List<FeedItem>();
    Set<Id> oldAssetIds = new Set<Id>();
    for (SObject asset : oldAssets) {
      oldAssetIds.add((Id) asset.get('Id'));
      updates.add(buildOldChildUpdate(config, asset, today, nowValue));
      addSourceSystemFeed(
        feedItems,
        asset,
        config.objectName,
        getString(asset, 'eHS_Source_System_Id__c')
      );
    }
    saveRecords(updates, true, 'ending old Asset records');

    Map<Id, Id> oldToNewAssetIds = new Map<Id, Id>();
    List<SObject> pending = new List<SObject>();
    pending.addAll(oldAssets);

    while (!pending.isEmpty()) {
      List<SObject> readySources = new List<SObject>();
      List<SObject> stillPending = new List<SObject>();

      for (SObject source : pending) {
        Id parentId = getId(source, 'ParentId');
        if (
          parentId == null ||
          !oldAssetIds.contains(parentId) ||
          oldToNewAssetIds.containsKey(parentId)
        ) {
          readySources.add(source);
        } else {
          stillPending.add(source);
        }
      }

      if (readySources.isEmpty()) {
        readySources.addAll(stillPending);
        stillPending.clear();
      }

      List<SObject> readyInserts = new List<SObject>();
      for (SObject source : readySources) {
        SObject clone = newSObject(config.objectName);
        copyCreateableFields(source, clone);
        setCreateValue(clone, config.accountField, newAccountId);
        applyNewChildValues(config, clone, today, nowValue);
        setCreateValue(
          clone,
          'eHS_Source_System_Id__c',
          getString(source, 'eHS_Source_System_Id__c')
        );

        Id parentId = getId(source, 'ParentId');
        if (parentId != null && oldToNewAssetIds.containsKey(parentId)) {
          setCreateValue(clone, 'ParentId', oldToNewAssetIds.get(parentId));
        }
        readyInserts.add(clone);
      }

      saveRecords(readyInserts, false, 'creating new Asset hierarchy records');
      for (Integer i = 0; i < readySources.size(); i++) {
        oldToNewAssetIds.put(
          (Id) readySources[i].get('Id'),
          (Id) readyInserts[i].get('Id')
        );
      }
      pending = stillPending;
    }

    saveFeedItems(feedItems, oldAccountId);
    return oldAssets.size();
  }

  /**
   * Purpose: Confirms that a child object and its Account lookup field exist and are readable before cloning starts.
   */
  private static Boolean canCloneObject(ChildCloneConfig config) {
    if (!hasObject(config.objectName)) {
      return false;
    }
    if (!isObjectReadable(config.objectName)) {
      throw new CloneException(
        'Missing read permission for ' + config.objectName + '.'
      );
    }
    if (!hasField(config.objectName, config.accountField)) {
      return false;
    }
    if (!isFieldReadable(config.objectName, config.accountField)) {
      throw new CloneException(
        'Missing read permission for ' +
          config.objectName +
          '.' +
          config.accountField +
          '.'
      );
    }
    return true;
  }

  /**
   * Purpose: Queries all cloneable child rows for the old Account using only fields the running user can read.
   */
  private static List<SObject> queryChildRecords(
    ChildCloneConfig config,
    Id oldAccountId
  ) {
    Set<String> fields = getCloneQueryFields(config.objectName);
    fields.add(config.accountField);
    if (config.hierarchyClone && hasField(config.objectName, 'ParentId')) {
      fields.add('ParentId');
    }

    List<String> fieldList = validFieldList(config.objectName, fields);
    String soql =
      'SELECT ' +
      String.join(fieldList, ', ') +
      ' FROM ' +
      config.objectName +
      ' WHERE ' +
      config.accountField +
      ' = :oldAccountId';
    return Database.queryWithBinds(
      soql,
      new Map<String, Object>{ 'oldAccountId' => oldAccountId },
      AccessLevel.USER_MODE
    );
  }

  /**
   * Purpose: Builds the update row that closes an old child record and clears its external id.
   */
  private static SObject buildOldChildUpdate(
    ChildCloneConfig config,
    SObject oldRow,
    Date today,
    Datetime nowValue
  ) {
    SObject oldUpdate = newSObject(config.objectName);
    oldUpdate.put('Id', oldRow.get('Id'));
    for (String fieldName : config.endFields) {
      setEndDateOrDatetime(
        config,
        oldUpdate,
        oldRow,
        fieldName,
        today,
        nowValue
      );
    }
    for (String fieldName : config.oldValues.keySet()) {
      setUpdateValue(oldUpdate, fieldName, config.oldValues.get(fieldName));
    }
    setUpdateValue(oldUpdate, 'eHS_Source_System_Id__c', null);
    return oldUpdate;
  }

  /**
   * Purpose: Applies start dates, blank end dates, and active values to a new cloned child record.
   */
  private static void applyNewChildValues(
    ChildCloneConfig config,
    SObject clone,
    Date today,
    Datetime nowValue
  ) {
    for (String fieldName : config.cloneClearFields) {
      setCreateValue(clone, fieldName, null);
    }
    for (String fieldName : config.startFields) {
      setDateOrDatetime(clone, fieldName, today, nowValue, true);
    }
    for (String fieldName : config.newValues.keySet()) {
      setCreateValue(clone, fieldName, config.newValues.get(fieldName));
    }
  }

  /**
   * Purpose: Chooses the safe end date for an old child record, including Effective To dates that must be after Effective From.
   */
  private static void setEndDateOrDatetime(
    ChildCloneConfig config,
    SObject oldUpdate,
    SObject oldRow,
    String fieldName,
    Date today,
    Datetime nowValue
  ) {
    Date endDate = today;
    String minimumFieldName = config.endFieldMustBeAfterFields.get(fieldName);
    if (!String.isBlank(minimumFieldName)) {
      endDate = dateAfterMinimum(today, getDate(oldRow, minimumFieldName));
    }
    setDateOrDatetime(oldUpdate, fieldName, endDate, nowValue, false);
  }

  /**
   * Purpose: Returns a date after the minimum required date so Salesforce date validation does not reject the update.
   */
  @TestVisible
  private static Date dateAfterMinimum(Date candidateDate, Date minimumDate) {
    if (minimumDate != null && candidateDate <= minimumDate) {
      return minimumDate.addDays(1);
    }
    return candidateDate;
  }

  /**
   * Purpose: Writes either a Date or Datetime value depending on the target field type.
   */
  private static void setDateOrDatetime(
    SObject row,
    String fieldName,
    Date today,
    Datetime nowValue,
    Boolean createMode
  ) {
    Schema.DescribeFieldResult fieldDescribe = getFieldDescribe(
      row.getSObjectType().getDescribe().getName(),
      fieldName
    );
    if (fieldDescribe == null) {
      return;
    }

    Object value = String.valueOf(fieldDescribe.getType()) == 'DATETIME'
      ? (Object) nowValue
      : (Object) today;
    if (createMode) {
      setCreateValue(row, fieldName, value);
    } else {
      setUpdateValue(row, fieldName, value);
    }
  }

  /**
   * Purpose: Creates old-to-new and new-to-old Account relationship records so admins can navigate both directions.
   */
  private static Integer createAccountRelationships(
    Id oldAccountId,
    Id newAccountId,
    Date today
  ) {
    if (!hasObject(RELATION_OBJECT)) {
      return 0;
    }

    Id roleId = getOrCreateAccountRelationRole();
    if (roleId == null) {
      throw new CloneException(
        'Unable to find or create an Account-Account Relationship role.'
      );
    }

    SObject forwardRelation = newSObject(RELATION_OBJECT);
    setCreateValue(forwardRelation, 'HealthCloudGA__Account__c', oldAccountId);
    setCreateValue(
      forwardRelation,
      'HealthCloudGA__RelatedAccount__c',
      newAccountId
    );
    setCreateValue(forwardRelation, 'HealthCloudGA__Role__c', roleId);
    setCreateValue(forwardRelation, 'HealthCloudGA__Active__c', true);
    setCreateValue(forwardRelation, 'HealthCloudGA__StartDate__c', today);
    setCreateValue(
      forwardRelation,
      'HealthCloudGA__ExternalId__c',
      'DeepClone-' + oldAccountId + '-' + newAccountId + '-forward'
    );

    SObject reverseRelation = newSObject(RELATION_OBJECT);
    setCreateValue(reverseRelation, 'HealthCloudGA__Account__c', newAccountId);
    setCreateValue(
      reverseRelation,
      'HealthCloudGA__RelatedAccount__c',
      oldAccountId
    );
    setCreateValue(reverseRelation, 'HealthCloudGA__Role__c', roleId);
    setCreateValue(reverseRelation, 'HealthCloudGA__Active__c', true);
    setCreateValue(reverseRelation, 'HealthCloudGA__StartDate__c', today);
    setCreateValue(
      reverseRelation,
      'HealthCloudGA__ExternalId__c',
      'DeepClone-' + newAccountId + '-' + oldAccountId + '-reverse'
    );

    List<SObject> relations = new List<SObject>{
      forwardRelation,
      reverseRelation
    };
    saveRecords(relations, false, 'linking old and new facilities');

    SObject forwardUpdate = newSObject(RELATION_OBJECT);
    forwardUpdate.put('Id', forwardRelation.get('Id'));
    setUpdateValue(
      forwardUpdate,
      'HealthCloudGA__InverseRelationship__c',
      reverseRelation.get('Id')
    );

    SObject reverseUpdate = newSObject(RELATION_OBJECT);
    reverseUpdate.put('Id', reverseRelation.get('Id'));
    setUpdateValue(
      reverseUpdate,
      'HealthCloudGA__InverseRelationship__c',
      forwardRelation.get('Id')
    );
    saveRecords(
      new List<SObject>{ forwardUpdate, reverseUpdate },
      true,
      'cross-linking Account-Account Relationships'
    );
    return 2;
  }

  /**
   * Purpose: Finds or creates the reciprocal role used by the Account-to-Account relationship records.
   */
  private static Id getOrCreateAccountRelationRole() {
    if (!hasObject(RELATION_ROLE_OBJECT)) {
      return null;
    }

    String roleName = RELATION_ROLE_NAME;
    String relationshipType = 'Account Account Relation';
    List<SObject> existingRoles = Database.query(
      'SELECT Id FROM ' +
        RELATION_ROLE_OBJECT +
        ' WHERE Name = :roleName AND HealthCloudGA__RelationshipType__c = :relationshipType LIMIT 1'
    );
    if (!existingRoles.isEmpty()) {
      return (Id) existingRoles[0].get('Id');
    }

    SObject role = newSObject(RELATION_ROLE_OBJECT);
    setCreateValue(role, 'Name', RELATION_ROLE_NAME);
    setCreateValue(
      role,
      'RecordTypeId',
      findRecordTypeId(RELATION_ROLE_OBJECT, 'AccountRole')
    );
    setCreateValue(
      role,
      'HealthCloudGA__RelationshipType__c',
      relationshipType
    );
    setCreateValue(
      role,
      'HealthCloudGA__InverseRole__c',
      RELATION_INVERSE_ROLE_NAME
    );
    setCreateValue(role, 'HealthCloudGA__CreateInverseRole__c', false);
    saveRecords(
      new List<SObject>{ role },
      false,
      'creating the Deep Clone Account relationship role'
    );
    return (Id) role.get('Id');
  }

  /**
   * Purpose: Looks up a Record Type Id by developer name for objects that need a specific record type on insert.
   */
  private static Id findRecordTypeId(String objectName, String developerName) {
    Schema.DescribeSObjectResult objectDescribe = getObjectDescribe(objectName);
    if (objectDescribe == null) {
      return null;
    }

    Schema.RecordTypeInfo recordType = objectDescribe
      .getRecordTypeInfosByDeveloperName()
      .get(developerName);
    return recordType == null ? null : recordType.getRecordTypeId();
  }

  /**
   * Purpose: Prepares a chatter FeedItem that records the old external id before the old child row is cleared.
   */
  private static void addSourceSystemFeed(
    List<FeedItem> feedItems,
    SObject oldRow,
    String objectName,
    String sourceSystemId
  ) {
    if (String.isBlank(sourceSystemId)) {
      return;
    }

    FeedItem item = new FeedItem();
    item.ParentId = (Id) oldRow.get('Id');
    item.Body =
      'Deep Clone preserved eHS_Source_System_Id__c before clearing it. Object: ' +
      objectName +
      ', Record: ' +
      String.valueOf(oldRow.get('Id')) +
      ', Source System Id: ' +
      sourceSystemId;
    item.IsRichText = false;
    item.Visibility = 'AllUsers';
    feedItems.add(item);
  }

  /**
   * Purpose: Saves chatter FeedItems on the child record when possible and falls back to the Account feed if needed.
   */
  private static void saveFeedItems(
    List<FeedItem> feedItems,
    Id fallbackParentId
  ) {
    if (feedItems.isEmpty()) {
      return;
    }

    Database.SaveResult[] results = Database.insert(feedItems, false);
    List<FeedItem> fallbackItems = new List<FeedItem>();
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        continue;
      }

      if (feedItems[i].ParentId == fallbackParentId) {
        throw new CloneException(
          'Unable to save source system id to chatter: ' +
          firstError(results[i])
        );
      }

      FeedItem fallback = new FeedItem();
      fallback.ParentId = fallbackParentId;
      fallback.Body =
        'Deep Clone preserved source system id for child record ' +
        String.valueOf(feedItems[i].ParentId) +
        '. ' +
        feedItems[i].Body;
      fallback.IsRichText = false;
      fallback.Visibility = 'AllUsers';
      fallbackItems.add(fallback);
    }

    List<SObject> fallbackRecords = new List<SObject>();
    fallbackRecords.addAll(fallbackItems);
    saveRecords(
      fallbackRecords,
      false,
      'saving source system ids to the Account chatter feed'
    );
  }

  /**
   * Purpose: Convenience overload that saves records without allowing duplicate-rule bypass.
   */
  private static void saveRecords(
    List<SObject> records,
    Boolean updateMode,
    String operationName
  ) {
    saveRecords(records, updateMode, operationName, false);
  }

  /**
   * Purpose: Inserts or updates records, gathers every row error, and throws one rollback-triggering exception.
   */
  private static void saveRecords(
    List<SObject> records,
    Boolean updateMode,
    String operationName,
    Boolean allowDuplicateSave
  ) {
    if (records == null || records.isEmpty()) {
      return;
    }

    Database.SaveResult[] results = updateMode
      ? Database.update(records, false)
      : Database.insert(records, buildDmlOptions(allowDuplicateSave));
    List<String> errors = new List<String>();
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        errors.add(
          recordErrorLabel(records[i]) + ': ' + firstError(results[i])
        );
      }
    }

    if (!errors.isEmpty()) {
      throw new CloneException(
        'Error while ' + operationName + '. ' + String.join(errors, ' | ')
      );
    }
  }

  /**
   * Purpose: Deletes records with per-row error reporting so any HealthcareFacility removal problem causes rollback.
   */
  private static void deleteRecords(
    List<SObject> records,
    String operationName
  ) {
    if (records == null || records.isEmpty()) {
      return;
    }

    Database.DeleteResult[] results = Database.delete(records, false);
    List<String> errors = new List<String>();
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        errors.add(
          recordErrorLabel(records[i]) + ': ' + firstDeleteError(results[i])
        );
      }
    }

    if (!errors.isEmpty()) {
      throw new CloneException(
        'Error while ' + operationName + '. ' + String.join(errors, ' | ')
      );
    }
  }

  /**
   * Purpose: Builds DML options and optionally allows the new Facility Account insert to bypass duplicate warnings.
   */
  @TestVisible
  private static Database.DMLOptions buildDmlOptions(
    Boolean allowDuplicateSave
  ) {
    Database.DMLOptions options = new Database.DMLOptions();
    options.optAllOrNone = false;
    if (allowDuplicateSave == true) {
      options.DuplicateRuleHeader.allowSave = true;
      options.DuplicateRuleHeader.runAsCurrentUser = true;
    }
    return options;
  }

  /**
   * Purpose: Converts the first Salesforce DML error into an admin-readable status and message.
   */
  private static String firstError(Database.SaveResult result) {
    if (result.getErrors().isEmpty()) {
      return 'Unknown DML error.';
    }
    Database.Error error = result.getErrors()[0];
    return error.getStatusCode() + ' - ' + error.getMessage();
  }

  /**
   * Purpose: Converts the first Salesforce delete error into an admin-readable status and message.
   */
  private static String firstDeleteError(Database.DeleteResult result) {
    if (result.getErrors().isEmpty()) {
      return 'Unknown DML error.';
    }
    Database.Error error = result.getErrors()[0];
    return error.getStatusCode() + ' - ' + error.getMessage();
  }

  /**
   * Purpose: Builds an error label that includes the object name and record Id when available.
   */
  private static String recordErrorLabel(SObject record) {
    String typeName = record.getSObjectType().getDescribe().getName();
    Object recordId = record.get('Id');
    return typeName + (recordId == null ? '' : ' ' + String.valueOf(recordId));
  }

  /**
   * Purpose: Queries one record in user mode using a safe, describe-filtered field list.
   */
  private static SObject querySingleRecord(
    String objectName,
    Id recordId,
    Set<String> requestedFields
  ) {
    if (!hasObject(objectName)) {
      throw new CloneException(
        objectName + ' object is not available in this org.'
      );
    }
    if (!isObjectReadable(objectName)) {
      throw new CloneException(
        'Missing read permission for ' + objectName + '.'
      );
    }

    List<String> fields = validFieldList(objectName, requestedFields);
    if (!fields.contains('Id')) {
      fields.add('Id');
    }
    fields.sort();

    String soql =
      'SELECT ' +
      String.join(fields, ', ') +
      ' FROM ' +
      objectName +
      ' WHERE Id = :recordId LIMIT 1';
    List<SObject> rows = Database.queryWithBinds(
      soql,
      new Map<String, Object>{ 'recordId' => recordId },
      AccessLevel.USER_MODE
    );
    if (rows.isEmpty()) {
      throw new CloneException(objectName + ' record was not found.');
    }
    return rows[0];
  }

  /**
   * Purpose: Builds the broad set of fields that are safe to read for cloning a specific object.
   */
  private static Set<String> getCloneQueryFields(String objectName) {
    Set<String> fields = new Set<String>{ 'Id' };
    if (!hasObject(objectName)) {
      return fields;
    }

    Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectName);
    for (String fieldName : fieldMap.keySet()) {
      Schema.DescribeFieldResult describe = fieldMap.get(fieldName)
        .getDescribe();
      if (isCloneQueryCandidate(fieldName, describe)) {
        fields.add(fieldName);
      }
    }
    return fields;
  }

  /**
   * Purpose: Decides whether a field should be included in the clone source query.
   */
  private static Boolean isCloneQueryCandidate(
    String fieldName,
    Schema.DescribeFieldResult describe
  ) {
    if (fieldName == 'Id' || fieldName == 'IsDeleted') {
      return false;
    }
    if (fieldName.startsWith('Person') || fieldName.endsWith('__pc')) {
      return false;
    }
    if (
      describe.isCalculated() ||
      describe.isAutoNumber() ||
      isUnsupportedField(describe)
    ) {
      return false;
    }
    return ((isCopyCandidate(fieldName, describe) &&
    (describe.isCreateable() || describe.isUpdateable())) ||
    isRequiredCloneReadField(fieldName));
  }

  /**
   * Purpose: Keeps only fields that exist, are readable, and are supported by this clone process.
   */
  private static List<String> validFieldList(
    String objectName,
    Set<String> requestedFields
  ) {
    List<String> fields = new List<String>();
    if (!hasObject(objectName)) {
      return fields;
    }

    Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectName);
    Set<String> seenFieldNames = new Set<String>();
    for (String fieldName : requestedFields) {
      String normalizedFieldName = fieldName == null
        ? ''
        : fieldName.toLowerCase();
      if (
        !seenFieldNames.contains(normalizedFieldName) &&
        fieldMap.containsKey(fieldName) &&
        fieldMap.get(fieldName).getDescribe().isAccessible() &&
        !isUnsupportedField(fieldMap.get(fieldName).getDescribe())
      ) {
        fields.add(fieldName);
        seenFieldNames.add(normalizedFieldName);
      }
    }
    if (!fields.contains('Id') && fieldMap.containsKey('Id')) {
      fields.add('Id');
    }
    fields.sort();
    return fields;
  }

  /**
   * Purpose: Copies createable, non-system fields from a source row to its new clone row.
   */
  private static void copyCreateableFields(SObject source, SObject target) {
    String objectName = target.getSObjectType().getDescribe().getName();
    Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectName);
    for (String fieldName : fieldMap.keySet()) {
      Schema.DescribeFieldResult describe = fieldMap.get(fieldName)
        .getDescribe();
      if (!isCopyCandidate(fieldName, describe) || !describe.isCreateable()) {
        continue;
      }

      Object value;
      try {
        value = source.get(fieldName);
      } catch (Exception ex) {
        continue;
      }
      if (value != null) {
        target.put(fieldName, value);
      }
    }
  }

  /**
   * Purpose: Decides whether a field is safe to copy from an old record to a new record.
   */
  private static Boolean isCopyCandidate(
    String fieldName,
    Schema.DescribeFieldResult describe
  ) {
    if (fieldName == 'Id' || fieldName == 'IsDeleted') {
      return false;
    }
    if (fieldName.startsWith('Person') || fieldName.endsWith('__pc')) {
      return false;
    }
    if (
      describe.isCalculated() ||
      describe.isAutoNumber() ||
      describe.isExternalId() ||
      isSourceSystemIdentifierField(fieldName) ||
      isUnsupportedField(describe)
    ) {
      return false;
    }
    return true;
  }

  /**
   * Purpose: Identifies source-system external id fields that must not be blindly copied.
   */
  private static Boolean isSourceSystemIdentifierField(String fieldName) {
    String lowerFieldName = fieldName == null ? '' : fieldName.toLowerCase();
    return lowerFieldName == 'sourcesystemidentifier' ||
      lowerFieldName.contains('sourcesystemid');
  }

  /**
   * Purpose: Identifies source-system fields that must be read even though they are not copied directly.
   */
  private static Boolean isRequiredCloneReadField(String fieldName) {
    String lowerFieldName = fieldName == null ? '' : fieldName.toLowerCase();
    return lowerFieldName == 'ehs_wdfa__c' ||
      lowerFieldName == 'ehs_facility_id__c' ||
      lowerFieldName == 'ehs_acpnumber__c' ||
      lowerFieldName == 'ehs_source_system_id__c' ||
      lowerFieldName == 'ehs_source_system__c' ||
      lowerFieldName == 'sourcesystem' ||
      lowerFieldName == 'sourcesystemidentifier';
  }

  /**
   * Purpose: Skips field types that dynamic Apex cannot safely copy or assign in this process.
   */
  private static Boolean isUnsupportedField(
    Schema.DescribeFieldResult describe
  ) {
    String typeName = String.valueOf(describe.getType());
    return typeName == 'ADDRESS' ||
      typeName == 'LOCATION' ||
      typeName == 'BASE64';
  }

  /**
   * Purpose: Sets a field only when it is createable on the target object.
   */
  private static void setCreateValue(
    SObject row,
    String fieldName,
    Object value
  ) {
    setFieldValue(row, fieldName, value, true);
  }

  /**
   * Purpose: Sets a field only when it is updateable on the target object.
   */
  private static void setUpdateValue(
    SObject row,
    String fieldName,
    Object value
  ) {
    setFieldValue(row, fieldName, value, false);
  }

  /**
   * Purpose: Performs describe-aware field assignment for create and update rows.
   */
  private static void setFieldValue(
    SObject row,
    String fieldName,
    Object value,
    Boolean createMode
  ) {
    String objectName = row.getSObjectType().getDescribe().getName();
    Schema.DescribeFieldResult fieldDescribe = getFieldDescribe(
      objectName,
      fieldName
    );
    if (
      fieldDescribe == null ||
      (createMode
        ? !fieldDescribe.isCreateable()
        : !fieldDescribe.isUpdateable()) ||
      isUnsupportedField(fieldDescribe)
    ) {
      return;
    }
    if (
      value != null &&
      String.valueOf(fieldDescribe.getType()) == 'PICKLIST' &&
      !picklistContains(fieldDescribe, String.valueOf(value))
    ) {
      return;
    }
    row.put(fieldName, value);
  }

  /**
   * Purpose: Checks whether a picklist value is active before assigning it dynamically.
   */
  private static Boolean picklistContains(
    Schema.DescribeFieldResult fieldDescribe,
    String value
  ) {
    for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
      if (entry.isActive() && entry.getValue() == value) {
        return true;
      }
    }
    return false;
  }

  /**
   * Purpose: Creates a blank SObject by API name and throws a clear error if the object is unavailable.
   */
  private static SObject newSObject(String objectName) {
    Schema.SObjectType objectType = getObjectType(objectName);
    if (objectType == null) {
      throw new CloneException(
        objectName + ' object is not available in this org.'
      );
    }
    return objectType.newSObject();
  }

  /**
   * Purpose: Checks whether an object API name exists in this org.
   */
  private static Boolean hasObject(String objectName) {
    return getObjectType(objectName) != null;
  }

  /**
   * Purpose: Checks whether a field API name exists on an object in this org.
   */
  private static Boolean hasField(String objectName, String fieldName) {
    return getFieldMap(objectName).containsKey(fieldName);
  }

  /**
   * Purpose: Checks whether the running user can read records for the object.
   */
  private static Boolean isObjectReadable(String objectName) {
    Schema.DescribeSObjectResult objectDescribe = getObjectDescribe(objectName);
    return objectDescribe != null && objectDescribe.isAccessible();
  }

  /**
   * Purpose: Checks whether the running user can delete records for the object.
   */
  private static Boolean isObjectDeletable(String objectName) {
    Schema.DescribeSObjectResult objectDescribe = getObjectDescribe(objectName);
    return objectDescribe != null && objectDescribe.isDeletable();
  }

  /**
   * Purpose: Checks whether the running user can read a specific field.
   */
  private static Boolean isFieldReadable(String objectName, String fieldName) {
    Schema.DescribeFieldResult fieldDescribe = getFieldDescribe(
      objectName,
      fieldName
    );
    return fieldDescribe != null && fieldDescribe.isAccessible();
  }

  /**
   * Purpose: Returns record type information for a record type Id on a given object.
   */
  private static Schema.RecordTypeInfo getRecordTypeInfo(
    String objectName,
    Id recordTypeId
  ) {
    Schema.DescribeSObjectResult objectDescribe = getObjectDescribe(objectName);
    if (objectDescribe == null || recordTypeId == null) {
      return null;
    }
    return objectDescribe.getRecordTypeInfosById().get(recordTypeId);
  }

  /**
   * Purpose: Returns and caches the field describe map for an object.
   */
  private static Map<String, Schema.SObjectField> getFieldMap(
    String objectName
  ) {
    if (String.isBlank(objectName) || !hasObject(objectName)) {
      return new Map<String, Schema.SObjectField>();
    }
    if (!fieldMapCache.containsKey(objectName)) {
      fieldMapCache.put(
        objectName,
        getObjectDescribe(objectName).fields.getMap()
      );
    }
    return fieldMapCache.get(objectName);
  }

  /**
   * Purpose: Returns describe information for one field, or null when the field is not available.
   */
  private static Schema.DescribeFieldResult getFieldDescribe(
    String objectName,
    String fieldName
  ) {
    Schema.SObjectField field = getFieldMap(objectName).get(fieldName);
    if (field == null) {
      return null;
    }
    return field.getDescribe();
  }

  /**
   * Purpose: Returns and caches the SObject type from global describe.
   */
  private static Schema.SObjectType getObjectType(String objectName) {
    if (String.isBlank(objectName)) {
      return null;
    }
    if (globalDescribeCache == null) {
      globalDescribeCache = Schema.getGlobalDescribe();
    }
    return globalDescribeCache.get(objectName);
  }

  /**
   * Purpose: Returns and caches object describe information.
   */
  private static Schema.DescribeSObjectResult getObjectDescribe(
    String objectName
  ) {
    Schema.SObjectType objectType = getObjectType(objectName);
    if (objectType == null) {
      return null;
    }
    if (!objectDescribeCache.containsKey(objectName)) {
      objectDescribeCache.put(objectName, objectType.getDescribe());
    }
    return objectDescribeCache.get(objectName);
  }

  /**
   * Purpose: Safely reads a field as a String without failing if the field is unavailable.
   */
  private static String getString(SObject row, String fieldName) {
    if (
      row == null ||
      !hasField(row.getSObjectType().getDescribe().getName(), fieldName)
    ) {
      return null;
    }
    try {
      Object value = row.get(fieldName);
      return value == null ? null : String.valueOf(value);
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * Purpose: Safely reads a field as an Id without failing if the field is unavailable.
   */
  private static Id getId(SObject row, String fieldName) {
    if (
      row == null ||
      !hasField(row.getSObjectType().getDescribe().getName(), fieldName)
    ) {
      return null;
    }
    try {
      Object value = row.get(fieldName);
      return value == null ? null : (Id) value;
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * Purpose: Safely reads a Date or Datetime field as a Date.
   */
  private static Date getDate(SObject row, String fieldName) {
    if (
      row == null ||
      !hasField(row.getSObjectType().getDescribe().getName(), fieldName)
    ) {
      return null;
    }
    try {
      Object value = row.get(fieldName);
      if (value instanceof Date) {
        return (Date) value;
      }
      if (value instanceof Datetime) {
        return ((Datetime) value).date();
      }
      return null;
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * Purpose: Converts blank user input to null and trims meaningful values.
   */
  private static String trimToNull(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    return value.trim();
  }

  /**
   * Purpose: Chooses the preferred value unless it is blank, then uses the fallback value.
   */
  private static String firstNonBlank(String preferred, String fallback) {
    return String.isBlank(preferred) ? fallback : preferred;
  }

  /**
   * Purpose: Truncates text to fit a target field length.
   */
  private static String limitLength(String value, Integer maxLength) {
    if (value == null || value.length() <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }
}