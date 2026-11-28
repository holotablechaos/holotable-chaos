# Holotable Chaos accounts (Supabase)

The website stays a static GitHub Pages site. Supabase (free plan) provides sign-in, the database
and, in later phases, scheduled jobs. This folder holds everything about the database that is safe
to publish: migrations, tests and local settings. **It contains no secrets, no personal data and no
seed accounts.**

| Path | What it is |
|---|---|
| `migrations/` | The database schema, row-level security rules and functions, applied in order. |
| `tests/` | pgTAP tests: owner protection, the access matrix for every table, admin features. |
| `config.jsonc` | Settings for the **local** test stack only. Production settings are made in the Supabase dashboard. |

## How sign-in works

- Listeners sign in with **Discord or Google** only. Production has the Email provider switched off,
  so there are no passwords or magic links. Guests simply don't sign in.
- Supabase links sign-ins that share a **verified** email to one account, and allows only one
  account per email address. "Connect Discord/Google" on the account page uses manual linking for
  listeners whose emails differ.
- Nothing is created at first sign-in except the sign-in itself (and the owner role for the owner).
  A profile row appears only when the listener saves their profile; every field is optional.

## Roles and the owner

- `public.user_roles` holds `owner` or `admin`. A unique index allows only one owner.
- The owner's email lives only in `private.owner_claim`, which the website can't read. It is
  inserted by hand in the SQL editor and is never committed.
- The owner role is granted only when a **Google or Discord identity with `email_verified = true`**
  for that email signs in, on an account whose email Supabase has confirmed, and only while no owner
  exists. Unverified identities, email/password accounts and look-alikes get nothing (see
  `tests/02_owner_claim_unverified.test.sql`).
- A trigger blocks removing, demoting or moving the owner row, including deleting the owner's
  sign-in, from anywhere except `private.transfer_ownership()`.
- The owner invites admins on the admin page by Discord user ID or email. An invite becomes the
  admin role when someone signs in with that Discord account, or with a verified email match.
- Every admin action writes to `public.audit_log`, which nobody can edit or delete.

### Claim ownership (once, after the first deploy)

Run in **Supabase → SQL Editor**, replacing the placeholder with the owner's address:

```sql
insert into private.owner_claim (id, email)
values (true, lower('OWNER-EMAIL@example.com'))
on conflict (id) do nothing;          -- never overwrites an existing claim

select private.try_claim_owner();     -- grants now if that verified sign-in already exists
```

If it returns `null`, sign in on the site with Discord or Google using that verified email; the role
is granted automatically.

### Transfer ownership (rare, SQL editor only)

```sql
-- Find the new owner's account id on the admin page (Accounts → ID), then:
select private.transfer_ownership('NEW-OWNER-ACCOUNT-ID');
-- The previous owner becomes an admin. Optionally point the claim at the new owner's email:
update private.owner_claim set email = lower('NEW-OWNER-EMAIL@example.com');
```

## Moderation lists, reserved names and unique display names

- Blocked terms (with a match type and category), an allowlist and reserved names live in private
  tables. **The lists are not in this repository and can't be viewed on the site or through the
  API by anyone, including the owner.** No function, view, export, audit entry or error message
  returns an entry. They are edited only by the owner's private loader script (files kept outside
  the repo) or by typing entries on the dashboard's Moderation tab (add, remove or change match
  type/category), which reports counts only. The filter tester says whether text would be blocked
  and in which category, never which entry matched. `tests/09_lists_not_readable.test.sql` proves
  admin and owner sessions can't retrieve any entry. Tests use fictional words only.
- All checks share one normalisation (`private.norm_words`, `private.name_key`): NFKC, lower case,
  accents and zero-width characters removed, common character swaps mapped, spaced or dotted
  letters joined, repeated letters collapsed where safe. Symbol-censored words ("gr*bble",
  "gr**ble", "gr#bble") are caught when the masks sit inside a word with at least two real letters;
  masks at the edges (**bold**, 4*) and digit-only text (5*3) are ignored.
- The filter applies to display names, in-game names and bios now, and to every later public text
  (answers, roster requests, comments). It never applies to ally codes or links, which are
  validated by format.
- Display names are unique on `display_name_key` (lookalikes collide; a unique index guards
  simultaneous saves), can change once every 30 days, and are freed when an account is deleted.
  Without a display name, people show as their provider name or "Listener" plus " · 1234" from
  their account id. The owner can look up and reclaim a name on the Moderation tab.
- `tests/07_false_positives.test.sql` checks every SwGoH unit name, tag and common game term against
  whatever list is loaded; run `supabase test db supabase/tests/07_false_positives.test.sql` after
  loading the real lists into the local stack.

## Applying database changes

Migrations are applied from a maintainer's computer, so no deploy token is stored in GitHub:

```sh
supabase login                       # once per computer
supabase link --project-ref <ref>    # once; asks for the database password
supabase db push                     # applies any new files in migrations/
```

## Testing

```sh
supabase start                       # local stack in Docker
supabase test db                     # pgTAP tests in tests/
supabase db lint --level warning     # static checks of the SQL functions
```

The **Database Tests** GitHub workflow runs the same tests on every change to this folder. It uses
no secrets.

## Staying on the free plan

- **Pausing:** free projects pause after a week without activity. The **Supabase Keep-Alive**
  workflow calls the public `keep_alive()` function every two days using only the publishable key.
  If it fails, open the Supabase dashboard and restore the project.
- **Limits that matter:** 500 MB database and 1 GB file storage per project, 5 GB data transfer a
  month. Phase 1 stores only small text rows.
- **Backups:** the free plan has none we rely on. A daily, encrypted `pg_dump` runs in the private
  repository `holotablechaos/holotable-chaos-backups`; see its README for restoring.
