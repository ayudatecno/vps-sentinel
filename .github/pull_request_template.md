## What & why


## Checklist
- [ ] `shellcheck -S warning *.sh` passes
- [ ] `bash -n` passes on changed scripts
- [ ] No new runtime dependencies
- [ ] Destructive actions stay scoped and fail-safe
- [ ] Tool usage is feature-detected (skips cleanly when absent)
