# Flutter & Serverpod project

Gewerber open-core backend — multi-tenant SaaS for solo Gewerbe owners in Germany.

## Stack

- Serverpod 4.0-beta backend (server + generated client)
- Auth: serverpod_auth (JWT + email IdP)
- DI: get_it + injectable
- Architecture: Clean Architecture per module

## Project Structure

```
gewerber_backend_server/lib/src/
  core/                          # shared kernel
    di/                          # get_it locator + injectable config
    tenant/                      # TenantContext, TenantResolver, Session.authUserId
    audit/                       # AuditEntry model + AuditService
    admin/                       # AdminUser allowlist (AdminRole), AdminRoleResolver, AdminContext
    events/                      # EventBus (MessageCentral wrapper)
    errors/                      # Serializable exceptions (NotFound, Validation, Forbidden, Conflict)
    endpoints/                   # BusinessScopedEndpoint, AdminEndpoint base classes
    entitlement/                 # Feature gating scaffold (all features enabled in OSS)
    mail/                        # MailService (SMTP) + EmailTemplate
    sequence/                    # GoBD-safe number sequences
  modules/
    business/                    # M1: Business + Membership + BusinessSettings
    invoicing/                   # M2: Customer, Invoice, templates, payments, reminders, PDF, recurring, export
    time_tracking/               # M3: Project, Task, TimeEntry (timer), rounding, reports, billing
    accounting/                  # M4: Income/expense transactions, receipts, P&L, CSV export
    documents/                   # Document storage (upload/download, private storage)
    dashboard/                   # Aggregated dashboard summary
    admin/                       # Admin API (global roles, audit, used by gewerber-mcp)
    guidance/                    # M5: Tooltips, checklists, per-user progress
    user/                        # UserProfile
  auth/                          # serverpod_auth_idp email/JWT endpoints
  generated/                     # Serverpod-generated code (do not edit)
```

## Key Conventions

- **Multi-tenancy**: every business-scoped table has `businessId`; `TenantResolver` resolves the current tenant from JWT `userIdentifier` + `Membership`.
- **DI**: endpoints are constructed by Serverpod codegen without arguments — they resolve services via `getIt<T>()`.
- **Naming**: domain interfaces use `*Gateway` suffix (e.g. `BusinessGateway`) to avoid collision with Serverpod's generated `*Repository` classes.
- **Enums first**: for any closed value set (country, locale/language, currency, statuses, types, units) prefer an enum over a free-form `String`. In `.spy.yaml` always use `serialized: byName`; values are lowercase (e.g. `de`, `eur`, `paid`). Adding values is safe, renaming is breaking.
- **String defaults**: must be quoted (`default='de'`).
- **Exceptions**: use generated `.spy.yaml` exceptions — they're thrown on the server and caught on the client by type.
- **Tests**: integration tests via `withServerpod` with test postgres (docker compose `postgres_test`). Call `configureDependencies()` in `setUpAll`.

## Endpoints

| Endpoint | Methods | Auth |
|---|---|---|
| `business` | create, get, update, listMine | requireLogin |
| `businessSettings` | get, update | requireLogin |
| `userProfile` | getMyProfile, me (own identity: global role + memberships), update, deleteMyAccount, exportMyData | requireLogin |
| `customer` | create, get, update, list, listPage, listCursorPage | requireLogin |
| `invoice` | create, get, getItems, update, list, listPage, listCursorPage, delete, markSent, cancel, generatePdf, exportCsv, exportJson | requireLogin |
| `invoiceTemplate` | create, get, update, list | requireLogin |
| `payment` | record, status | requireLogin |
| `recurringSchedule` | create, get, list, update, cancel | requireLogin |
| `reminder` | list, send | requireLogin |
| `document` | upload, list, get, download, delete | requireLogin |
| `entitlement` | list | requireLogin |
| `project` | create, get, getTasks, update, list, delete | requireLogin |
| `task` | create, update, list | requireLogin |
| `timeEntry` | startTimer, stopTimer, create, get, update, list, delete, report, createInvoice | requireLogin |
| `accounting` | create, get, update, list, delete, profitLoss, exportCsv | requireLogin |
| `dashboard` | getSummary | requireLogin |
| `guidance` | tips, checklists, myProgress, markCompleted, dismissTip | requireLogin |
| `adminStats` | statsOverview | global role moderator |
| `adminUsers` | usersSearch, usersGet / usersVerifyEmail (read-only compliance check) / usersBan, usersUnban | moderator read / admin check (no `confirm`) / admin write + `confirm` |
| `adminBusinesses` | businessesSearch, businessesGet, membershipsSetRole | moderator read / admin write + `confirm` |
| `adminInvoices` | invoicesList, invoicesGet / invoiceCancelAdmin | moderator read / admin write + `confirm` |
| `adminAudit` | auditQuery | moderator |
| `adminGuidance` | guidanceTipsList / guidanceTipUpsert | moderator read / admin write + `confirm` |
| auth (module) | email login/register, JWT refresh | per serverpod_auth |
| `waitlist` (commercial module) | join | public |

## Admin API (`modules/admin`, used by `gewerber-mcp`)

Global administration surface for the AI MCP server replacing the admin
panel. Roles live in the `admin_user` allowlist table (`AdminRole`:
`moderator` = read-only, `admin` = mutate); they are resolved from the DB on
every request via `AdminRoleResolver` (base class `core/endpoints/
AdminEndpoint.requireAdmin`). Mutations require `confirm: true` and write
`audit_entry` rows with action prefix `admin.`. There is no user deletion —
bans are flags on the auth user (`AuthUser.blocked` + refresh-token purge).

**Granting the first admin** (out of band, by design): registered users only —

```bash
psql "$DATABASE_URL" -v email="'you@example.com'" -v role="'admin"' \
  -f gewerber_backend_server/tool/grant_admin.sql
```

## Background jobs

Invoicing future calls are scheduled at server start (`server.dart` →
`InvoicingJobScheduler.ensureScheduled`, hourly, idempotent):

- `process-recurring-invoices` — materializes due recurring invoices.
- `mark-overdue-invoices` — marks sent/partially paid invoices past their due
  date as overdue.

## Commercial module

The closed-source `gewerber-backend-commercial` Serverpod module (nickname
`commercial`) is wired in via `config/generator.yaml` (`modules:` section).
The git dependency in `gewerber_backend_server/pubspec.yaml` points at the
public stub packages (`Gewerber/gewerber-backend-stubs`), so OSS builds and
CI resolve without any private access. Developers with a local checkout of the
private repo override it via `pubspec_overrides.yaml` (gitignored,
`../gewerber-backend-commercial`). Release image builds rewrite the stubs URL
to the real module with a git `insteadOf` rule using the
`COMMERCIAL_REPO_TOKEN` BuildKit secret (see `Dockerfile`). Its tables are
prefixed `commercial_*` and migrate together with the server
(`SERVERPOD_APPLY_MIGRATIONS=true`). When endpoints or models of the module
change, mirror the public API surface into `gewerber-backend-stubs`.

Commercial billing wiring (PayPal webhook route, hourly reconciliation sweep)
lives inside the module behind its public entrypoint
`wireCommercialBilling(Serverpod)` (exported from the module barrel; the OSS
stubs ship an identical no-op). The host `server.dart` calls it unconditionally
before `pod.start()` — it self-gates on `GEWERBER_COMMERCIAL_ENTITLEMENTS=true`
and imports only the module's public barrel, no `src/` paths.

## Phases

| Phase | Content | Status |
|---|---|---|
| M0 | DI, tenant, audit, errors, events, base endpoint | ✅ Done |
| M1 | Business + Membership + onboarding | ✅ Done |
| M2 | Invoicing (Customer, Invoice, TaxRuleEngine, PDF, recurring, reminders, export) | ✅ Done |
| M3 | Time tracking (Project, Task, TimeEntry, rounding, reports, billing) | ✅ Done |
| M4 | Accounting (Expense, Income, P&L, receipts, export) | ✅ Done |
| M5 | Guidance (tooltips, checklists, per-user progress) | ✅ Done |

## Commands

```bash
serverpod generate          # regenerate models/endpoints after changing .spy.yaml
serverpod create-migration  # create DB migration (after table changes)
dart run build_runner build # regenerate injectable DI config
dart analyze                # required before PR
dart format .               # required before PR
dart test                   # integration tests (needs postgres_test)
```

## Deployment

Same pipeline as `gewerber-website`: GitHub Actions → GHCR → VPS → docker compose behind Traefik.

- Push `main` → production (`api.gewerber.de`), push `develop` → staging (`api.test.gewerber.de`).
- `.github/workflows/deploy.yml` builds `gewerber_backend_server/Dockerfile`, pushes the image to GHCR, copies `deploy/` to the VPS and runs `deploy/deploy.sh`.
- Per-environment stack: server + PostgreSQL + Redis (`deploy/docker-compose.yml`); only the API port 8080 is exposed via Traefik (router prefix `gwb` / `gwb-test`), Insights (8081) stays internal.
- Secrets (DB/Redis passwords, JWT keys, service secret) are generated once per environment by `deploy.sh` into `~/gewerber/backend/<env>/.secrets` and written to `config/passwords.yaml` mounted into the container. Deleting `.secrets` rotates all secrets (and invalidates JWT sessions).
- Migrations are applied automatically on container startup (`SERVERPOD_APPLY_MIGRATIONS=true`).
- Self-hosting: `deploy/docker-compose.yml` + `deploy/.env.example` describe the standalone (OSS single-tenant) setup; the container needs a `config/passwords.yaml` mounted at `/app/config/passwords.yaml`.

## Checklist after doing changes

1. `dart analyze` (CLI)
2. `dart format` (CLI)
3. `serverpod create-migration` (CLI — only if models changed)
4. Do `serverpod` MCP `hot_restart` if required
5. Run tests (`dart test` — needs `docker compose up -d postgres_test`)
6. Check `serverpod` MCP `tail_server_logs` and `tail_flutter_logs` for any issues.

The user starts the server and Flutter app with `serverpod start`. NEVER start the server yourself.

If the user asks you to test the app:

1. Use `get_flutter_app_dtd` (`serverpod` MCP) to get the Flutter app's DTD
2. Pass the DTD to `connect_dart_tooling_daemon` (`dart` MCP) to connect to the app
3. Use `flutter_driver` (`dart` MCP) to navigate through the app
