@IsTest
private class DeepCloneControllerTest {
  private static final String OLD_ACCOUNT_NAME = 'Deep Clone Test Facility';

  @TestSetup
  static void setupData() {
    Account facility = new Account(Name = OLD_ACCOUNT_NAME);
    Id facilityRecordTypeId = findFacilityRecordTypeId();
    if (facilityRecordTypeId != null) {
      facility.RecordTypeId = facilityRecordTypeId;
    }
    putIfWriteable(facility, 'IsActive', true, true);
    putIfWriteable(
      facility,
      'EffectiveDate',
      Datetime.now().addDays(-30),
      true
    );
    putIfWriteable(facility, 'eHS_WDFA__c', 'WDFA-OLD', true);
    putIfWriteable(facility, 'eHS_Facility_Id__c', 'FAC001', true);
    putIfWriteable(facility, 'eHS_ACPNumber__c', 'ACP001', true);
    putIfWriteable(facility, 'eHS_Source_System_Id__c', 'DSR-OLD', true);
    putIfWriteable(facility, 'SourceSystemIdentifier', 'DSR-OLD', true);
    putIfWriteable(
      facility,
      'HealthCloudGA__SourceSystemId__c',
      'DSR-OLD',
      true
    );
    putIfWriteable(facility, 'eHS_Source_System__c', 'DSR', true);
    putIfWriteable(facility, 'HealthCloudGA__SourceSystem__c', 'DSR', true);
    putIfWriteable(facility, 'eHS_Status__c', 'Open', true);
    insert facility;

    createAssetHierarchy(facility.Id);
  }

  @IsTest
  static void getContextReturnsCurrentIdentifierValues() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];

    DeepCloneController.bypassFacilityCheckForTests = true;
    DeepCloneController.CloneContext context = DeepCloneController.getContext(
      facility.Id
    );

    System.assertEquals(facility.Id, context.accountId);
    System.assertEquals(true, context.isFacility);
    if (hasField('Account', 'eHS_WDFA__c')) {
      System.assertEquals('WDFA-OLD', context.wdfa);
    }
  }

  @IsTest
  static void cloneFacilityCreatesNewFacilityAndClonesAssets() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];

    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.wdfaChanging = true;
    request.newWdfa = 'WDFA-NEW';
    request.facilityIdChanging = false;
    request.acpNumberChanging = true;
    request.newAcpNumber = 'ACP002';
    request.dsrIdChanging = true;
    request.newDsrId = 'DSR-NEW';

    DeepCloneController.bypassFacilityCheckForTests = true;
    Test.startTest();
    DeepCloneController.CloneResult result = DeepCloneController.cloneFacility(
      facility.Id,
      request
    );
    Test.stopTest();

    System.assertNotEquals(null, result.newAccountId);
    SObject oldFacility = queryAccount(facility.Id);
    SObject newFacility = queryAccount(result.newAccountId);

    System.assertEquals(false, oldFacility.get('IsActive'));
    System.assertEquals(true, newFacility.get('IsActive'));
    if (hasField('Account', 'eHS_WDFA__c')) {
      System.assertEquals(null, oldFacility.get('eHS_WDFA__c'));
      System.assertEquals('WDFA-NEW', newFacility.get('eHS_WDFA__c'));
    }
    if (hasField('Account', 'eHS_Facility_Id__c')) {
      System.assertEquals('FAC001', newFacility.get('eHS_Facility_Id__c'));
    }
    if (hasField('Account', 'eHS_ACPNumber__c')) {
      System.assertEquals('ACP002', newFacility.get('eHS_ACPNumber__c'));
    }
    if (hasField('Account', 'eHS_Source_System_Id__c')) {
      System.assertEquals(
        'DSR-NEW',
        newFacility.get('eHS_Source_System_Id__c')
      );
    }
    if (hasObject('Identifier')) {
      System.assertEquals(
        true,
        hasIdentifierUsage(facility.Id, 'DSR - WDFA'),
        'The old WDFA should be written to Identifier history.'
      );
    }

    if (hasObject('Asset')) {
      List<SObject> oldAssets = queryAssets(facility.Id);
      List<SObject> newAssets = queryAssets(result.newAccountId);
      System.assert(
        oldAssets.size() > 0,
        'Test setup should create assets to clone.'
      );
      System.assertEquals(
        oldAssets.size(),
        newAssets.size(),
        'Each old asset should have a new asset clone.'
      );

      if (hasField('Asset', 'UsageEndDate')) {
        for (SObject oldAsset : oldAssets) {
          System.assertEquals(Date.today(), oldAsset.get('UsageEndDate'));
        }
        for (SObject newAsset : newAssets) {
          System.assertEquals(null, newAsset.get('UsageEndDate'));
        }
      }
      if (hasField('Asset', 'InstallDate')) {
        for (SObject newAsset : newAssets) {
          System.assertEquals(Date.today(), newAsset.get('InstallDate'));
        }
      }
      if (isFieldReadable('Asset', 'eHS_Source_System_Id__c')) {
        for (SObject oldAsset : oldAssets) {
          System.assertEquals(null, oldAsset.get('eHS_Source_System_Id__c'));
        }
        for (SObject newAsset : newAssets) {
          System.assertNotEquals(null, newAsset.get('eHS_Source_System_Id__c'));
        }
      }
    }
  }

  @IsTest
  static void cloneFacilityRollsBackEveryChangeWhenAnyStepFails() {
    Account facility = new Account(Name = 'Deep Clone Rollback Facility');
    Id facilityRecordTypeId = findFacilityRecordTypeId();
    if (facilityRecordTypeId != null) {
      facility.RecordTypeId = facilityRecordTypeId;
    }
    putIfWriteable(facility, 'IsActive', true, true);
    putIfWriteable(facility, 'eHS_Source_System_Id__c', 'RB-DSR', true);
    putIfWriteable(facility, 'SourceSystemIdentifier', 'RB-DSR', true);
    putIfWriteable(
      facility,
      'HealthCloudGA__SourceSystemId__c',
      'RB-DSR',
      true
    );
    putIfWriteable(facility, 'eHS_Source_System__c', 'DSR', true);
    putIfWriteable(facility, 'HealthCloudGA__SourceSystem__c', 'DSR', true);
    insert facility;

    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.wdfaChanging = false;
    request.facilityIdChanging = false;
    request.acpNumberChanging = false;
    request.dsrIdChanging = false;

    DeepCloneController.bypassFacilityCheckForTests = true;
    DeepCloneController.forceFailureForTests = true;

    try {
      DeepCloneController.cloneFacility(facility.Id, request);
      System.assert(false, 'The forced failure should throw.');
    } catch (Exception ex) {
      System.assert(
        ex.getMessage().contains('Forced rollback test failure'),
        ex.getMessage()
      );
    } finally {
      DeepCloneController.forceFailureForTests = false;
    }

    SObject afterRollback = queryAccount(facility.Id);
    System.assertEquals(true, afterRollback.get('IsActive'));
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Account
        WHERE Name = 'Deep Clone Rollback Facility' AND Id != :facility.Id
      ]
    );
  }

  @IsTest
  static void cloneFacilityRequiresNewValuesForChangedIdentifiers() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.wdfaChanging = true;
    request.facilityIdChanging = false;
    request.acpNumberChanging = false;
    request.dsrIdChanging = false;

    DeepCloneController.bypassFacilityCheckForTests = true;
    try {
      DeepCloneController.cloneFacility(facility.Id, request);
      System.assert(false, 'Missing changed WDFA value should throw.');
    } catch (Exception ex) {
      System.assertNotEquals(null, ex.getMessage());
    }
  }

  @IsTest
  static void cloneFacilityReusesExistingIdentifierHistoryKeys() {
    if (!hasObject('Identifier')) {
      return;
    }

    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    insertIdentifierHistory(
      facility.Id,
      'FAC001',
      'DSR - Facility ID',
      null
    );
    SObject existingDsrIdentifier = insertIdentifierHistory(
      facility.Id,
      'DSR-OLD',
      'DSR - ID',
      null
    );

    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.wdfaChanging = true;
    request.newWdfa = 'DEDUP-WDFA';
    request.facilityIdChanging = false;
    request.acpNumberChanging = false;
    request.dsrIdChanging = true;
    request.newDsrId = 'DEDUP-DSR';

    DeepCloneController.bypassFacilityCheckForTests = true;
    Test.startTest();
    DeepCloneController.CloneResult result = DeepCloneController.cloneFacility(
      facility.Id,
      request
    );
    Test.stopTest();

    System.assertNotEquals(null, result.newAccountId);
    if (hasField('Identifier', 'EndDate')) {
      SObject endedIdentifier = queryIdentifier(
        (Id) existingDsrIdentifier.get('Id')
      );
      System.assertNotEquals(null, endedIdentifier.get('EndDate'));
    }
  }

  @IsTest
  static void callableRunsSynchronouslyWhenIpRequestsSync() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    Map<String, Object> input = new Map<String, Object>{
      'recordId' => facility.Id,
      'runAsync' => false,
      'request' => new Map<String, Object>{
        'newWdfa' => 'IPGT6W',
        'facilityIdChanging' => false,
        'acpNumberChanging' => false,
        'dsrIdChanging' => false
      }
    };
    Map<String, Object> args = new Map<String, Object>{
      'input' => input,
      'output' => new Map<String, Object>(),
      'options' => new Map<String, Object>()
    };

    DeepCloneController.bypassFacilityCheckForTests = true;
    Test.startTest();
    Map<String, Object> response = (Map<String, Object>) new DeepCloneController()
      .call('deepCloneSync', args);
    Test.stopTest();

    System.assertEquals(
      true,
      response.get('success'),
      String.valueOf(response)
    );
    System.assertEquals(false, response.get('queued'));
    System.assertNotEquals(null, response.get('newAccountId'));
    SObject newFacility = queryAccount(
      Id.valueOf(String.valueOf(response.get('newAccountId')))
    );
    if (hasField('Account', 'eHS_WDFA__c')) {
      System.assertEquals('IPGT6W', newFacility.get('eHS_WDFA__c'));
    }
  }

  @IsTest
  static void callableQueuesDeepCloneByDefaultForIp() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    Map<String, Object> args = new Map<String, Object>{
      'input' => new Map<String, Object>{
        'accountId' => facility.Id,
        'wdfaChanging' => false,
        'facilityIdChanging' => false,
        'acpNumberChanging' => false,
        'dsrIdChanging' => false
      },
      'output' => new Map<String, Object>(),
      'options' => new Map<String, Object>()
    };

    Test.startTest();
    Map<String, Object> response = (Map<String, Object>) new DeepCloneController()
      .call('startDeepClone', args);
    Test.stopTest();

    System.assertEquals(
      true,
      response.get('success'),
      String.valueOf(response)
    );
    System.assertEquals(true, response.get('queued'));
    System.assertNotEquals(null, response.get('jobId'));
  }

  @IsTest
  static void newFacilityInsertAllowsDuplicateRuleSave() {
    Database.DMLOptions options = DeepCloneController.buildDmlOptions(true);

    System.assertEquals(false, options.optAllOrNone);
    System.assertEquals(true, options.DuplicateRuleHeader.allowSave);
    System.assertEquals(true, options.DuplicateRuleHeader.runAsCurrentUser);
  }

  @IsTest
  static void hpfEffectiveToMovesAfterSameDayEffectiveFrom() {
    Date today = Date.today();

    System.assertEquals(
      today.addDays(1),
      DeepCloneController.dateAfterMinimum(today, today)
    );
    System.assertEquals(
      today,
      DeepCloneController.dateAfterMinimum(today, today.addDays(-1))
    );
    System.assertEquals(
      today,
      DeepCloneController.dateAfterMinimum(today, null)
    );
  }

  @IsTest
  static void findsHealthcareFacilityCreatedForNewAccount() {
    if (!hasObject('HealthcareFacility')) {
      return;
    }

    Account account = new Account(Name = 'Healthcare Facility Lookup Account');
    insert account;

    SObject healthcareFacility = Schema.getGlobalDescribe()
      .get('HealthcareFacility')
      .newSObject();
    putIfWriteable(
      healthcareFacility,
      'Name',
      'Lookup Healthcare Facility',
      true
    );
    putIfWriteable(healthcareFacility, 'AccountId', account.Id, true);
    if (
      healthcareFacility.get('Name') == null ||
      healthcareFacility.get('AccountId') == null
    ) {
      return;
    }
    insert healthcareFacility;

    System.assertEquals(
      healthcareFacility.get('Id'),
      DeepCloneController.findHealthcareFacilityIdByAccount(account.Id)
    );
  }

  @IsTest
  static void cloneFacilityRemovesOldHealthcareFacilityBeforeCarryForward() {
    if (!hasObject('HealthcareFacility')) {
      return;
    }

    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    ensureHealthcareFacility(facility.Id, 'WDFA-OLD', 'DSR-OLD');

    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.wdfaChanging = false;
    request.facilityIdChanging = false;
    request.acpNumberChanging = false;
    request.dsrIdChanging = true;
    request.newDsrId = 'HF-DSR-NEW';

    DeepCloneController.bypassFacilityCheckForTests = true;
    Test.startTest();
    DeepCloneController.CloneResult result = DeepCloneController.cloneFacility(
      facility.Id,
      request
    );
    Test.stopTest();

    System.assertNotEquals(null, result.newAccountId);
    System.assertEquals(
      0,
      queryHealthcareFacilities(facility.Id).size(),
      'The old HealthcareFacility should be removed before the replacement Facility is created.'
    );
    System.assert(
      queryHealthcareFacilities(result.newAccountId).size() > 0,
      'The Account flow should create a HealthcareFacility for the replacement Facility.'
    );
  }

  private static void createAssetHierarchy(Id accountId) {
    if (!hasObject('Asset')) {
      return;
    }

    SObject parentAsset = Schema.getGlobalDescribe().get('Asset').newSObject();
    putIfWriteable(parentAsset, 'Name', 'Parent Asset', true);
    putIfWriteable(parentAsset, 'AccountId', accountId, true);
    putIfWriteable(parentAsset, 'Status', 'Installed', true);
    putIfWriteable(
      parentAsset,
      'eHS_Source_System_Id__c',
      'ASSET-PARENT-OLD',
      true
    );
    insert parentAsset;

    if (!hasField('Asset', 'ParentId')) {
      return;
    }

    SObject childAsset = Schema.getGlobalDescribe().get('Asset').newSObject();
    putIfWriteable(childAsset, 'Name', 'Child Asset', true);
    putIfWriteable(childAsset, 'AccountId', accountId, true);
    putIfWriteable(childAsset, 'ParentId', parentAsset.get('Id'), true);
    putIfWriteable(childAsset, 'Status', 'Installed', true);
    putIfWriteable(
      childAsset,
      'eHS_Source_System_Id__c',
      'ASSET-CHILD-OLD',
      true
    );
    insert childAsset;
  }

  private static SObject queryAccount(Id accountId) {
    Set<String> fields = new Set<String>{
      'Id',
      'Name',
      'IsActive',
      'EndDate',
      'EffectiveDate',
      'eHS_WDFA__c',
      'eHS_Facility_Id__c',
      'eHS_ACPNumber__c',
      'eHS_Source_System_Id__c',
      'eHS_Status__c'
    };
    List<String> validFields = new List<String>();
    for (String fieldName : fields) {
      if (hasField('Account', fieldName)) {
        validFields.add(fieldName);
      }
    }
    validFields.sort();
    String soql =
      'SELECT ' +
      String.join(validFields, ', ') +
      ' FROM Account WHERE Id = :accountId LIMIT 1';
    return Database.query(soql);
  }

  private static List<SObject> queryAssets(Id accountId) {
    Set<String> fields = new Set<String>{
      'Id',
      'Name',
      'AccountId',
      'ParentId',
      'UsageEndDate',
      'InstallDate',
      'eHS_Source_System_Id__c'
    };
    List<String> validFields = new List<String>();
    for (String fieldName : fields) {
      if (hasField('Asset', fieldName)) {
        validFields.add(fieldName);
      }
    }
    validFields.sort();
    String soql =
      'SELECT ' +
      String.join(validFields, ', ') +
      ' FROM Asset WHERE AccountId = :accountId ORDER BY Name';
    return Database.query(soql);
  }

  private static List<SObject> queryHealthcareFacilities(Id accountId) {
    if (
      !hasObject('HealthcareFacility') ||
      !hasField('HealthcareFacility', 'AccountId')
    ) {
      return new List<SObject>();
    }
    return Database.query(
      'SELECT Id FROM HealthcareFacility WHERE AccountId = :accountId'
    );
  }

  private static void ensureHealthcareFacility(
    Id accountId,
    String wdfa,
    String sourceSystemId
  ) {
    if (!queryHealthcareFacilities(accountId).isEmpty()) {
      return;
    }

    SObject healthcareFacility = Schema.getGlobalDescribe()
      .get('HealthcareFacility')
      .newSObject();
    putIfWriteable(healthcareFacility, 'Name', 'Old Healthcare Facility', true);
    putIfWriteable(healthcareFacility, 'AccountId', accountId, true);
    putIfWriteable(healthcareFacility, 'eHS_WDFA__c', wdfa, true);
    putIfWriteable(
      healthcareFacility,
      'eHS_Source_System_Id__c',
      sourceSystemId,
      true
    );
    if (
      healthcareFacility.get('Name') == null ||
      healthcareFacility.get('AccountId') == null
    ) {
      return;
    }
    insert healthcareFacility;
  }

  private static SObject queryIdentifier(Id identifierId) {
    Set<String> fields = new Set<String>{ 'Id', 'EndDate' };
    List<String> validFields = new List<String>();
    for (String fieldName : fields) {
      if (hasField('Identifier', fieldName)) {
        validFields.add(fieldName);
      }
    }
    validFields.sort();
    String soql =
      'SELECT ' +
      String.join(validFields, ', ') +
      ' FROM Identifier WHERE Id = :identifierId LIMIT 1';
    return Database.query(soql);
  }

  private static Boolean hasIdentifierUsage(Id accountId, String usageType) {
    if (
      !hasObject('Identifier') ||
      !hasField('Identifier', 'ParentRecordId') ||
      !hasField('Identifier', 'IdUsageType')
    ) {
      return false;
    }
    Integer rowCount = Database.countQuery(
      'SELECT COUNT() FROM Identifier WHERE ParentRecordId = :accountId AND IdUsageType = :usageType'
    );
    return rowCount > 0;
  }

  private static SObject insertIdentifierHistory(
    Id accountId,
    String idValue,
    String usageType,
    Datetime endDate
  ) {
    SObject identifier = Schema.getGlobalDescribe()
      .get('Identifier')
      .newSObject();
    putIfWriteable(identifier, 'ParentRecordId', accountId, true);
    putIfWriteable(identifier, 'IssuingAuthorityId', accountId, true);
    putIfWriteable(identifier, 'IdValue', idValue, true);
    putIfWriteable(identifier, 'IdUsageType', usageType, true);
    putIfWriteable(identifier, 'EffectiveDate', Datetime.now().addDays(-2), true);
    putIfWriteable(identifier, 'EndDate', endDate, true);
    putIfWriteable(identifier, 'SourceSystemIdentifier', 'DSR-OLD', true);
    putIfWriteable(
      identifier,
      'eHS_Source_System_Id__c',
      'DSR-OLD' + usageType + idValue,
      true
    );
    insert identifier;
    return identifier;
  }

  private static Id findFacilityRecordTypeId() {
    List<RecordType> recordTypes = [
      SELECT Id
      FROM RecordType
      WHERE SObjectType = 'Account' AND DeveloperName = 'Facility'
      LIMIT 1
    ];
    return recordTypes.isEmpty() ? null : recordTypes[0].Id;
  }

  private static void putIfWriteable(
    SObject record,
    String fieldName,
    Object value,
    Boolean createMode
  ) {
    String objectName = record.getSObjectType().getDescribe().getName();
    if (!hasField(objectName, fieldName)) {
      return;
    }
    Schema.DescribeFieldResult fieldDescribe = getFieldDescribe(
      objectName,
      fieldName
    );
    if (createMode && !fieldDescribe.isCreateable()) {
      return;
    }
    if (!createMode && !fieldDescribe.isUpdateable()) {
      return;
    }
    if (
      value != null &&
      String.valueOf(fieldDescribe.getType()) == 'PICKLIST' &&
      !picklistContains(fieldDescribe, String.valueOf(value))
    ) {
      return;
    }
    record.put(fieldName, value);
  }

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

  private static Boolean hasObject(String objectName) {
    return Schema.getGlobalDescribe().containsKey(objectName);
  }

  private static Boolean hasField(String objectName, String fieldName) {
    return hasObject(objectName) &&
      Schema.getGlobalDescribe()
        .get(objectName)
        .getDescribe()
        .fields.getMap()
        .containsKey(fieldName);
  }

  private static Boolean isFieldReadable(String objectName, String fieldName) {
    return hasField(objectName, fieldName) &&
      getFieldDescribe(objectName, fieldName).isAccessible();
  }

  private static Schema.DescribeFieldResult getFieldDescribe(
    String objectName,
    String fieldName
  ) {
    return Schema.getGlobalDescribe()
      .get(objectName)
      .getDescribe()
      .fields.getMap()
      .get(fieldName)
      .getDescribe();
  }
}