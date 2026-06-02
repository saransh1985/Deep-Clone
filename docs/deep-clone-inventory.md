# Deep Clone Inventory

## Direct Components

| Area | Metadata | Notes |
| --- | --- | --- |
| Quick action | `Account.Deep_Clone` | Label `Deep Clone`; launches LWC `deepClone`. |
| LWC | `deepClone` | Record action screen action for Account Deep Clone. |
| Apex | `DeepCloneController` | LWC controller plus `Callable` and `Queueable` entry points. |
| Apex test | `DeepCloneControllerTest` | EHDATA run passed 12 of 12 tests. |
| Lightning page | `eHS_Facility_Account_Page` | Contains `Account.Deep_Clone` in action names. |
| Layout | `Account-eHS_Facility` | Facility layout snapshot from EHDATA. |

## Functional Scope From Apex

`DeepCloneController` is designed to clone a Facility Account and supported related records while rolling back on failure. The controller references these main record areas:

- Account and Facility identifiers: WDFA, Facility ID, ACP Number, DSR/source system id.
- Identifier history.
- HealthcareFacility records.
- Health Cloud account-account relationship records and reciprocal roles.
- CareProgramTeamMember records.
- AccountContactRelation records.
- BusinessLicense records.
- Asset records, including parent-child Asset hierarchy handling.

## Retrieved Context

The repo includes direct metadata plus broad object metadata snapshots for:

- `Account`
- `Identifier`
- `HealthcareFacility`
- `CareProgramTeamMember`
- `BusinessLicense`
- `Asset`
- `AccountContactRelation`
- `HealthCloudGA__AccountAccountRelation__c`
- `HealthCloudGA__ReciprocalRole__c`

## Query Evidence

The `docs/inventory` folder contains raw JSON evidence for:

- Quick action definition.
- LWC bundle.
- Apex classes.
- Account Facility record type.
- Account Facility layout.
- Related object definitions.

## Validation Evidence

`docs/deep-clone-test-results.txt` contains the saved EHDATA test result for `DeepCloneControllerTest`.

The manifest was also validated with a dry-run deploy against EHDATA. The validation succeeded with deploy id `0AfAw00000OB3WFKA1`.
