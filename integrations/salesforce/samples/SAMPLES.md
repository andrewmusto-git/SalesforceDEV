# Sample Data — Salesforce OAA Integration

This connector fetches data **live from the Salesforce REST API** — no flat file samples
are required for normal operation.

For **offline testing** or schema validation, you can place representative JSON exports
here. The dry-run tester will use `--data-dir` pointing to this directory, but the main
script will still call the live API (the `--data-dir` flag is accepted but unused by
`salesforce.py`).

## Useful sample files for reference / testing

| File | How to export | What it represents |
|------|--------------|-------------------|
| `users.json` | SOQL: `SELECT Id,Username,Email,FirstName,LastName,IsActive,ProfileId,UserType FROM User LIMIT 10` | Salesforce User records |
| `profiles.json` | SOQL: `SELECT Id,Name,UserType,Description FROM Profile LIMIT 10` | Salesforce Profile records |
| `permission_sets.json` | SOQL: `SELECT Id,Name,Label,IsOwnedByProfile,ProfileId FROM PermissionSet LIMIT 10` | PermissionSet records |
| `object_permissions.json` | SOQL: `SELECT Id,ParentId,SObjectType,PermissionsRead,PermissionsCreate,PermissionsEdit,PermissionsDelete,PermissionsViewAllRecords,PermissionsModifyAllRecords FROM ObjectPermissions LIMIT 20` | Object-level permission records |

Export via Salesforce Workbench → Utilities → REST Explorer, or using the Salesforce CLI:
```bash
sf data query --query "SELECT Id, Username FROM User LIMIT 5" --json > users.json
```
