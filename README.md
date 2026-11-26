# Deep Clone

Standalone Salesforce DX snapshot of the EHDATA Deep Clone implementation for Account record type `Facility`.

## Included Metadata

- Account quick action: `Account.Deep_Clone`
- Lightning Web Component: `deepClone`
- Apex: `DeepCloneController`
- Apex test: `DeepCloneControllerTest`
- Facility Account Lightning page: `eHS_Facility_Account_Page`
- Facility Account layout: `Account-eHS_Facility`
- Related object metadata snapshots used by the controller:
  - `Account`
  - `Identifier`
  - `HealthcareFacility`
  - `CareProgramTeamMember`
  - `BusinessLicense`
  - `Asset`
  - `AccountContactRelation`
  - `HealthCloudGA__AccountAccountRelation__c`
  - `HealthCloudGA__ReciprocalRole__c`

The related object metadata is intentionally broad so this repo preserves as much EHDATA context as possible around the Deep Clone workflow. Some Health Cloud metadata is managed package metadata and depends on that package being installed in the target org.

## Validation

The EHDATA test run passed:

- Test class: `DeepCloneControllerTest`
- Tests run: 12
- Pass rate: 100%
- Controller coverage: 80%
- Dry-run deploy validation: succeeded

Saved evidence is in `docs/deep-clone-test-results.txt`.

## Inventory

Read `docs/deep-clone-inventory.md` for the high-level inventory.

## Deploy Command

```powershell
sf project deploy start --manifest manifest/package.xml --target-org <target-org-alias> --test-level RunSpecifiedTests --tests DeepCloneControllerTest
```
