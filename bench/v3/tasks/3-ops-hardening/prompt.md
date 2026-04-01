# Task: Ops Production Hardening

You have a running Valkey instance loaded with a deliberately misconfigured `valkey.conf`. The workload description is in `workload.md`.

Your job:

1. Read `workload.md` to understand the production workload requirements.
2. Audit `valkey.conf` and identify every configuration problem - security, persistence, performance, and operational issues.
3. Fix all problems directly in `valkey.conf`. Make the config production-ready for the described workload.
4. Write `AUDIT.md` documenting every issue you found and the fix you applied. For each issue, include:
   - The problem (what was wrong and why it matters)
   - The fix (what you changed)
   - The rationale (why this value/setting is appropriate for the workload)

Do not start a new Valkey instance or modify `docker-compose.yml`. Only fix `valkey.conf` and produce `AUDIT.md`.
