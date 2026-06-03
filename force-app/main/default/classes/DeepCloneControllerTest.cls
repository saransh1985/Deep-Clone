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
    putIfWriteable(facility, 'BillingStreet', '100 Old Facility Rd', true);
    putIfWriteable(facility, 'BillingCity', 'Old City', true);
    putIfWriteable(facility, 'BillingState', 'BC', true);
    putIfWriteable(facility, 'BillingPostalCode', 'V1V 1V1', true);
    putIfWriteable(facility, 'BillingCountry', 'Canada', true);
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
    System.assertEquals(OLD_ACCOUNT_NAME, context.facilityName);
    if (hasField('Account', 'BillingStreet')) {
      System.assertEquals('100 Old Facility Rd', context.street);
    }
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

    Date newStartDate = Date.today().addDays(2);
    Date requestedEndDate = Date.today().addYears(1);
    DeepCloneController.CloneRequest request = new DeepCloneController.CloneRequest();
    request.facilityNameChanging = true;
    request.newFacilityName = 'Deep Clone Test Facility New';
    request.addressChanging = true;
    request.newStreet = '200 New Facility Ave';
    request.newCity = 'New City';
    request.newState = 'AB';
    request.newPostalCode = 'T2T 2T2';
    request.newCountry = 'Canada';
    request.startDateChanging = true;
    request.newStartDate = newStartDate;
    request.endDateChanging = true;
    request.newEndDate = requestedEndDate;
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
    System.assertEquals('Deep Clone Test Facility New', newFacility.get('Name'));
    if (hasField('Account', 'BillingStreet')) {
      System.assertEquals(
        '200 New Facility Ave',
        newFacility.get('BillingStreet')
      );
      System.assertEquals('New City', newFacility.get('BillingCity'));
      System.assertEquals('AB', newFacility.get('BillingState'));
      System.assertEquals('T2T 2T2', newFacility.get('BillingPostalCode'));
      System.assertEquals('Canada', newFacility.get('BillingCountry'));
    }
    if (hasField('Account', 'EffectiveDate')) {
      System.assertEquals(
        newStartDate,
        dateValue(newFacility.get('EffectiveDate'))
      );
    }
    if (hasField('Account', 'EndDate')) {
      System.assertEquals(
        requestedEndDate,
        dateValue(oldFacility.get('EndDate')),
        'The old Facility should keep the user-entered End Date.'
      );
      System.assertEquals(
        null,
        dateValue(newFacility.get('EndDate')),
        'The new Facility should stay open-ended even when an EndDate value is sent.'
      );
    }
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
          System.assertEquals(requestedEndDate, oldAsset.get('UsageEndDate'));
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
      if (hasField('Asset', 'Name')) {
        for (SObject newAsset : newAssets) {
          System.assertEquals(
            'AHS IAM | Deep Clone Test Facility New',
            newAsset.get('Name')
          );
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
      if (hasPicklistValue('Asset', 'eHS_Status__c', 'In Progress')) {
        for (SObject newAsset : newAssets) {
          System.assertEquals('In Progress', newAsset.get('eHS_Status__c'));
        }
      }
      if (
        hasPicklistValue(
          'Asset',
          'eHS_Asset_Type__c',
          'eHS Provider Initiative'
        )
      ) {
        for (SObject newAsset : newAssets) {
          System.assertEquals(
            'eHS Provider Initiative',
            newAsset.get('eHS_Asset_Type__c')
          );
        }
      }
    }

    assertAccountRelationshipRoles(facility.Id, result.newAccountId);
  }

  @IsTest
  static void closeFacilityEndsAccountAndRelatedAssets() {
    Account facility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    Date requestedEndDate = Date.today().addDays(10);
    DeepCloneController.CloseFacilityRequest request = new DeepCloneController.CloseFacilityRequest();
    request.endDate = requestedEndDate;

    DeepCloneController.bypassFacilityCheckForTests = true;
    Test.startTest();
    DeepCloneController.CloneResult result = DeepCloneController.closeFacility(
      facility.Id,
      request
    );
    Test.stopTest();

    System.assertEquals('Facility closed successfully.', result.message);
    SObject closedFacility = queryAccount(facility.Id);
    System.assertEquals(false, closedFacility.get('IsActive'));
    if (hasField('Account', 'EndDate')) {
      System.assertEquals(
        requestedEndDate,
        dateValue(closedFacility.get('EndDate'))
      );
    }
    if (hasField('Account', 'eHS_Status__c')) {
      System.assertEquals('Closed', closedFacility.get('eHS_Status__c'));
    }
    if (hasField('Account', 'eHS_WDFA__c')) {
      System.assertEquals(null, closedFacility.get('eHS_WDFA__c'));
    }
    if (hasField('Account', 'eHS_Facility_Id__c')) {
      System.assertEquals(null, closedFacility.get('eHS_Facility_Id__c'));
    }
    if (hasField('Account', 'eHS_ACPNumber__c')) {
      System.assertEquals(null, closedFacility.get('eHS_ACPNumber__c'));
    }
    if (hasField('Account', 'eHS_Source_System_Id__c')) {
      System.assertEquals(null, closedFacility.get('eHS_Source_System_Id__c'));
    }
    if (hasObject('Identifier')) {
      System.assertEquals(true, hasIdentifierUsage(facility.Id, 'DSR - WDFA'));
      System.assertEquals(
        true,
        hasIdentifierUsage(facility.Id, 'DSR - Facility ID')
      );
      System.assertEquals(
        true,
        hasIdentifierUsage(facility.Id, 'DSR - ACP Number')
      );
      System.assertEquals(true, hasIdentifierUsage(facility.Id, 'DSR - ID'));
    }
    if (hasObject('Asset')) {
      for (SObject asset : queryAssets(facility.Id)) {
        if (hasField('Asset', 'UsageEndDate')) {
          System.assertEquals(requestedEndDate, asset.get('UsageEndDate'));
        }
        if (isFieldReadable('Asset', 'eHS_Source_System_Id__c')) {
          System.assertNotEquals(
            null,
            asset.get('eHS_Source_System_Id__c'),
            'Close Facility should not clear child source-system ids.'
          );
        }
      }
    }
  }

  @IsTest
  static void closeFacilityRequiresStartDateBeforeEndDate() {
    Account facility = new Account(Name = 'Close Facility Missing Start Date');
    Id facilityRecordTypeId = findFacilityRecordTypeId();
    if (facilityRecordTypeId != null) {
      facility.RecordTypeId = facilityRecordTypeId;
    }
    putIfWriteable(facility, 'IsActive', true, true);
    insert facility;

    DeepCloneController.CloseFacilityRequest request = new DeepCloneController.CloseFacilityRequest();
    request.endDate = Date.today().addDays(5);
    DeepCloneController.bypassFacilityCheckForTests = true;
    try {
      DeepCloneController.closeFacility(facility.Id, request);
      System.assert(false, 'A Facility without Start Date should not close.');
    } catch (Exception ex) {
      System.assert(
        ex.getMessage().contains('Enter Start Date first'),
        ex.getMessage()
      );
    }

    Account seededFacility = [
      SELECT Id
      FROM Account
      WHERE Name = :OLD_ACCOUNT_NAME
      LIMIT 1
    ];
    Date startDate = dateValue(queryAccount(seededFacility.Id).get('EffectiveDate'));
    request.endDate = startDate;
    try {
      DeepCloneController.closeFacility(seededFacility.Id, request);
      System.assert(false, 'End Date equal to Start Date should not close.');
    } catch (Exception ex) {
      System.assert(
        ex.getMessage().contains('End Date must be after Start Date'),
        ex.getMessage()
      );
    }
  }

  @IsTest
  static void facilityNameDrivenChildNamesUseRequestedConventions() {
    System.assertEquals(
      'AHS IAM | New Facility',
      DeepCloneController.buildAssetName('New Facility')
    );
    System.assertEquals(
      'New Facility | Program Coordinator',
      DeepCloneController.buildCareProgramTeamMemberName(
        'New Facility',
        'Program Coordinator'
      )
    );
    System.assertEquals(
      'Dr. Ada Lovelace | Primary Practitioner | New Facility',
      DeepCloneController.buildHealthcarePractitionerFacilityName(
        'Dr. Ada Lovelace',
        'Primary Practitioner',
        'New Facility'
      )
    );
    assertPicklistLabelLookup('CareProgramTeamMember', 'Role');
    assertPicklistLabelLookup(
      'HealthcarePractitionerFacility',
      'eHS_HCPF_Role__c'
    );
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
    Id assetRecordTypeId = findAssetRecordTypeId();
    if (assetRecordTypeId != null) {
      putIfWriteable(parentAsset, 'RecordTypeId', assetRecordTypeId, true);
    }
    putIfWriteable(parentAsset, 'Name', 'Parent Asset', true);
    putIfWriteable(parentAsset, 'AccountId', accountId, true);
    putIfWriteable(parentAsset, 'Status', 'Installed', true);
    putIfWriteable(
      parentAsset,
      'eHS_Asset_Type__c',
      'eHS Provider Initiative',
      true
    );
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
    if (assetRecordTypeId != null) {
      putIfWriteable(childAsset, 'RecordTypeId', assetRecordTypeId, true);
    }
    putIfWriteable(childAsset, 'Name', 'Child Asset', true);
    putIfWriteable(childAsset, 'AccountId', accountId, true);
    putIfWriteable(childAsset, 'ParentId', parentAsset.get('Id'), true);
    putIfWriteable(childAsset, 'Status', 'Installed', true);
    putIfWriteable(
      childAsset,
      'eHS_Asset_Type__c',
      'eHS Provider Initiative',
      true
    );
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
      'BillingStreet',
      'BillingCity',
      'BillingState',
      'BillingPostalCode',
      'BillingCountry',
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
      'eHS_Source_System_Id__c',
      'eHS_Asset_Type__c',
      'eHS_Status__c'
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

  private static void assertAccountRelationshipRoles(
    Id oldAccountId,
    Id newAccountId
  ) {
    if (
      !hasObject('HealthCloudGA__AccountAccountRelation__c') ||
      !hasField(
        'HealthCloudGA__AccountAccountRelation__c',
        'HealthCloudGA__Account__c'
      ) ||
      !hasField(
        'HealthCloudGA__AccountAccountRelation__c',
        'HealthCloudGA__RelatedAccount__c'
      ) ||
      !hasField(
        'HealthCloudGA__AccountAccountRelation__c',
        'HealthCloudGA__Role__c'
      ) ||
      !hasObject('HealthCloudGA__ReciprocalRole__c')
    ) {
      return;
    }

    List<SObject> relations = Database.query(
      'SELECT Id, HealthCloudGA__Account__c, HealthCloudGA__RelatedAccount__c, HealthCloudGA__Role__c ' +
        'FROM HealthCloudGA__AccountAccountRelation__c ' +
        'WHERE (HealthCloudGA__Account__c = :oldAccountId AND HealthCloudGA__RelatedAccount__c = :newAccountId) ' +
        'OR (HealthCloudGA__Account__c = :newAccountId AND HealthCloudGA__RelatedAccount__c = :oldAccountId)'
    );
    System.assert(
      relations.size() >= 2,
      'Deep Clone should create both old-to-new and new-to-old relationship rows.'
    );

    Set<Id> roleIds = new Set<Id>();
    for (SObject relation : relations) {
      roleIds.add((Id) relation.get('HealthCloudGA__Role__c'));
    }
    Map<Id, String> roleNamesById = reciprocalRoleNames(roleIds);

    Boolean hasOldToNew = false;
    Boolean hasNewToOld = false;
    for (SObject relation : relations) {
      Id accountId = (Id) relation.get('HealthCloudGA__Account__c');
      String roleName = roleNamesById.get(
        (Id) relation.get('HealthCloudGA__Role__c')
      );
      if (accountId == oldAccountId && roleName == 'New Facility') {
        hasOldToNew = true;
      }
      if (accountId == newAccountId && roleName == 'Old Facility') {
        hasNewToOld = true;
      }
    }
    System.assert(hasOldToNew, 'Old Facility page should link to New Facility.');
    System.assert(hasNewToOld, 'New Facility page should link to Old Facility.');
  }

  private static Map<Id, String> reciprocalRoleNames(Set<Id> roleIds) {
    Map<Id, String> namesById = new Map<Id, String>();
    if (roleIds == null || roleIds.isEmpty()) {
      return namesById;
    }
    for (SObject role : Database.query(
      'SELECT Id, Name FROM HealthCloudGA__ReciprocalRole__c WHERE Id IN :roleIds'
    )) {
      namesById.put((Id) role.get('Id'), String.valueOf(role.get('Name')));
    }
    return namesById;
  }

  private static void assertPicklistLabelLookup(
    String objectName,
    String fieldName
  ) {
    if (!hasField(objectName, fieldName)) {
      return;
    }

    Schema.DescribeFieldResult fieldDescribe = getFieldDescribe(
      objectName,
      fieldName
    );
    if (fieldDescribe.getPicklistValues().isEmpty()) {
      return;
    }

    Schema.PicklistEntry entry = fieldDescribe.getPicklistValues()[0];
    System.assertEquals(
      entry.getLabel(),
      DeepCloneController.getPicklistLabel(
        objectName,
        fieldName,
        entry.getValue()
      )
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

  private static Id findAssetRecordTypeId() {
    if (!hasObject('Asset')) {
      return null;
    }
    List<RecordType> recordTypes = [
      SELECT Id
      FROM RecordType
      WHERE SObjectType = 'Asset'
      AND DeveloperName IN ('eHS_Initiatives_and_HIS', 'eHS_PIA', 'eHS_pORA')
      ORDER BY DeveloperName
      LIMIT 1
    ];
    return recordTypes.isEmpty() ? null : recordTypes[0].Id;
  }

  private static Date dateValue(Object value) {
    if (value instanceof Date) {
      return (Date) value;
    }
    if (value instanceof Datetime) {
      return ((Datetime) value).date();
    }
    return null;
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

  private static Boolean hasPicklistValue(
    String objectName,
    String fieldName,
    String value
  ) {
    return hasField(objectName, fieldName) &&
      picklistContains(getFieldDescribe(objectName, fieldName), value);
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
