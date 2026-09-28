# The /initialize contract

- Called at the start of EVERY bench run; resets DB/files/in-memory to baseline.
- Hard time limit, varies by year (ISUCON12: 30s). Exceeding = automatic fail.
- Response BODY is validated: ISUCON13 required a `lang` field; missing/empty = init failure.
- Reset mechanism matters: ISUCON12 teams using mysqldump logical restore blew 30s; physical
  copy of /var/lib/mysql passed. This is why some top teams stayed on SQLite.
- Re-invoked during post-contest restart+revalidation.
- => Any cache/new-persistent-state fix MUST be checked against "does /initialize reset it?"

## Checklist before shipping any stateful change

- [ ] Does /initialize reset this new state?
- [ ] Does it complete within the year's documented time limit when cold, not just when warm?
- [ ] Does the response body still contain every field the benchmarker validates?
- [ ] Does the state survive a process restart correctly, or does it come back stale?
- [ ] Is the reset mechanism physical (fast) rather than a logical mysqldump restore (slow)?
