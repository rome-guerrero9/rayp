# Audit Submission Cover Email

**Status:** TODO — recreate. The cover email body was drafted off-record. Paste the version actually sent here, or use the template below if the original is lost.

## Template

```
Subject: RAYP — audit engagement request

Hi <firm name>,

We'd like to engage <firm> to audit RAYP, a regime-aware yield protocol
deploying to Arbitrum One. Brief facts:

  Codebase:   <github URL, commit hash>
  In scope:   8 contracts, ~<TODO> LOC (see AUDIT_SCOPE.md)
  Tests:      forge test green; <TODO>% branch coverage
  Testnet:    Deployed to Arbitrum Sepolia (see SEPOLIA_DEPLOYMENT.md)
  Multisig:   Arbitrum One Safe, 2-of-3 (address withheld until
              engagement signed)
  Target:     Mainnet deploy <TODO month/year>

Attached:
  - AUDIT_SCOPE.md (in scope, threat model summary)
  - Latest test/coverage report

Happy to schedule a 30-min call to walk through the architecture. Could
you share rough timeline, cost, and earliest start date?

Thanks,
<name>
<contact>
```

## Once sent

Record below: the date, recipient, message-ID or thread URL, and the firm's response. Update `AUDIT_SCOPE.md` with the same.
