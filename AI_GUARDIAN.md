# ZouChat AI Guardian

## What is implemented

- Supabase Edge Function `zouchat-ai-guardian`, protected by a signed-in session and admin check for privileged actions.
- Browser error summaries can be submitted without collecting chat messages or passwords.
- Admin-only event history and AI proposal storage with row-level security.
- Optional OpenAI analysis. If no provider key exists, the function stays in monitoring-only mode.
- GitHub Actions checks inline JavaScript syntax and scans for obvious accidental secret commits.

## Important limitations

- No API key is included in this repository. Never commit one.
- The guardian does not edit, merge, or deploy application code.
- AI suggestions are saved as `pending_approval`; a human must review and implement them.
- GitHub Actions validates syntax; it does not prove the app works in a real browser or run full integration tests.
- This is a foundation, not an autonomous 24/7 security service. More runtime telemetry and integration tests can be added later.

## Enable AI analysis

1. Open the Supabase dashboard for project `rollxrixddvgpkgidlja`.
2. Go to Edge Functions / Secrets and add `OPENAI_API_KEY` there (never in `index.html` or GitHub files).
3. Use the admin-only Guardian panel in ZouChat to check status and request an analysis.
4. Review every proposal and test it before manually merging/deploying changes.

The external OpenAI API may incur separate usage charges. No AI calls are made while the key is absent.
