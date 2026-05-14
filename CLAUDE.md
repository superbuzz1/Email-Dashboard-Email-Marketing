# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

Smart-Emailing is a Rails 5.0 multi-tenant email marketing dashboard combining a CRM, campaign manager, and IMAP inbox. Accounts own users, campaigns, email templates, SMTP/IMAP settings, and notes. Campaigns are sent through user-configured SMTP (SendGrid/AWS SES/etc.) and status updates flow back via a SendGrid webhook.

## Stack

- Ruby 2.6.2 per `.ruby-version` and `Gemfile`, but `Dockerfile` pins `ruby:2.3.0`. The Dockerfile is the deploy target — keep this mismatch in mind before changing gems or syntax that depend on a particular Ruby.
- Rails 5.0.1, Puma, Sidekiq (<5), Redis (via `redis-namespace`, namespace `email_marketing_sidekiq`).
- DB: app supports SQLite, MySQL, PostgreSQL, and SQL Server (all adapter gems are bundled). `config/database.yml` is the default; `database_*.example.yml` ship for each backend.
- Views in HAML, assets via Sprockets (Bootstrap-Sass, jQuery, CoffeeScript, Select2, TinyMCE, chartkick).
- Auth: Devise for `Account` (end user) and `AdminUser` (rails_admin). Token auth for the JSON API via `Account#authentication_token`.

## Common commands

Local (non-Docker):

```bash
bundle install
bundle exec rake db:migrate
bundle exec rails s            # boots Puma on :3000
bundle exec sidekiq -C config/sidekiq.yml   # workers (needs Redis on 127.0.0.1:6379)
bundle exec rspec              # full test suite
bundle exec rspec spec/models/user_spec.rb           # single file
bundle exec rspec spec/models/user_spec.rb:42        # single example by line
bundle exec annotate           # refresh `# == Schema Information` blocks at top of models
```

Docker (the documented deployment path):

```bash
docker-compose build
docker-compose run web rake db:migrate
docker-compose up -d
```

CI / quality: CodeClimate runs Rubocop, Brakeman, and duplication on `**.rb` (see `.codeclimate.yml`; `config/`, `spec/`, `db/`, `vendor/` are excluded). There is no local rubocop config — match existing style.

## Required environment variables

`SECRET_KEY_BASE`, `SIDEKIQ_USERNAME`, `SIDEKIQ_PASSWORD` (gate `/sidekiq` in production), `REDIS_HOST_URL`, `REDIS_PASSWORD`, `TINYMCE_API_KEY`. In non-production, Sidekiq talks to `127.0.0.1:6379` and the Sidekiq web UI is unauthenticated.

## Architecture

### Account-scoped multi-tenancy

Every user-facing controller derives from `ApplicationController`, which runs `before_action :authenticate_account!` (Devise). Controllers must scope queries through `current_account` (e.g. `current_account.campaigns.find(params[:id])`) — never query top-level `Campaign`/`User` directly in request paths. `CampaignUser` enforces this at the model layer via `validate_sources_accounts`, which rejects records whose campaign and user belong to different accounts.

### Dynamic user attributes via `method_missing`

`User` has a HABTM-ish bag of `UserAttribute` rows (`key`/`value`). `User#method_missing` (`app/models/user.rb:26`) makes any unknown reader return `data[key]` and any unknown writer call `data_setter`. Two consequences:

- Importing a CSV automatically becomes columns: `ImportUsersJob` → `CreateUserJob` writes each CSV header as a `UserAttribute`.
- Email template bodies are rendered with a `User` instance as the binding (see below), so templates can write `<%= first_name %>` and it resolves through `method_missing`. Adding real methods to `User` will shadow attribute keys with the same name.

### Email template rendering (security-sensitive)

`UserMailer#campaign_email` (`app/mailers/user_mailer.rb`) builds `Tilt::ERBTemplate.new { template.body }` and renders it with `@user` as the context. This is arbitrary Ruby execution by design — anything an account user types into the template editor runs at send time with full access to that `User` instance. Treat the template editor as trusted-account input and don't widen its exposure (don't render unsanitized template content elsewhere, don't expand the binding object).

### Filtering, exporting, and Ransack

List screens (`users#index`, `campaigns#index`, `campaigns#show`) use Ransack. The shared helpers `ransack_results_with_limit` and `users_to_export` in `ApplicationController` honor `params[:limit_count]` and paginate with Kaminari. New filterable screens should follow the same pattern (`@q = scope.ransack(params[:q])`, `@q.build_grouping`, then `ransack_results_with_limit`). XLSX export uses `axlsx_rails` (see `users#index` responder); CSV export goes through `User.to_csv_file`.

### Background jobs (Sidekiq via ActiveJob)

`config.active_job.queue_adapter = :sidekiq` (`config/application.rb`). Queues and weights are declared in `config/sidekiq.yml`:

- `high_priority` (1), `user_create_or_update` (20), `low_priority` (30), `default` (100).

`config/initializers/sidekiq.rb` sets `Sidekiq.default_worker_options = { unique: :until_executing, unique_args: ->(args) { [args.first.except('job_id')] } }` via `sidekiq-unique-jobs`. This means jobs are deduped by their **first** argument; pass an options hash (not positional args) when you need fields to participate in uniqueness. The current job graph:

- `ImportUsersJob` (high_priority) reads `public/upload/<name>.csv` and enqueues one `CreateUserJob` per row.
- `CreateCampaignJob` / `AddUsersToCampaignJob` materialize a campaign + its `CampaignUser` rows from a Ransack `params[:q]`.
- `SendCampaignEmailsJob` walks `campaign.campaign_users.where(status: 'draft')`, mails each through `UserMailer`, then flips status to `processed`. It rescues per-user errors and only logs — failures don't retry.

### CampaignUser status lifecycle

`CampaignUser::STATUSES` is the canonical list: `draft processed dropped delivered deferred bounce open click spamreport unsubscribe group_unsubscribe group_resubscribe`. `default("draft")` lives in the DB; `after_initialize :set_default_status` is a defensive fallback. The SendGrid webhook (`CampaignsController#event_receiver`, `POST /campaigns/event_receiver`) updates `status` by `campaign_user_id` carried in `X-SMTPAPI` unique args set in `ApplicationMailer#send_email_with_delivery_options`. CSRF and Devise are both skipped on that action.

### JSON API

`app/controllers/api/v1/` is mounted at `/api/v1` and inherits from `Api::V1::ApiBaseController` (an `ActionController::API`). Auth is HTTP token against `Account#authentication_token` (set on Account create via `before_create :set_authentication_token`). Note the controller uses `before_filter`, which is removed in Rails 5.1+ — if Rails is upgraded, this must become `before_action`.

### Admin and ops surfaces

- `/admin` — rails_admin, guarded by Devise `:admin_users`.
- `/sidekiq` — Sidekiq Web UI; HTTP-Basic in production using `SIDEKIQ_USERNAME` / `SIDEKIQ_PASSWORD`, open in dev.

## Testing conventions

- RSpec with `--require spec_helper` (`.rspec`); `rails_helper` enables `infer_spec_type_from_file_location!` and transactional fixtures.
- Factories live in `spec/factories/` (factory_bot — gem name in the Gemfile is the old `factory_girl_rails`).
- Only model specs exist today (`spec/models/`); there are no request, controller, or job specs. If you add tests for controllers/jobs, you'll be establishing the pattern — keep them scoped per `current_account`.

## Conventions to follow

- Always scope through `current_account`; never expose cross-account data.
- Annotate model schemas at the top of each file (`bundle exec annotate`) to match the existing style — every model has a `# == Schema Information` block.
- When adding queues, register them in `config/sidekiq.yml`; otherwise the worker won't pick them up.
- HAML for new views, not ERB (except mailer templates, which are ERB by deliberate choice so users can author them).
- `public/upload/` is gitignored and is where CSV uploads land — don't commit fixtures there.
