-- Phase 3.4.1.2C — collaborator invitation username resolution + secure people search.
--
-- ROOT CAUSE this fixes: the Flutter client resolved an invited username to a
-- user id with a direct client SELECT `profiles.select(id).eq('username', x)`.
-- `profiles` RLS is own-row-only (auth.uid() = id), so that SELECT returns ZERO
-- rows for any OTHER user → the controller reported `No user "x"`. The users
-- exist and are public; the lookup was simply blocked by RLS. Real usernames
-- (iamleizu, maria205) both have public profiles rows.
--
-- FIX: resolve + invite entirely inside trusted SECURITY DEFINER RPCs (no client
-- profiles SELECT), with one canonical username-normalization contract, plus a
-- bounded privacy-safe people-search RPC for the collaborator picker. Additive
-- only; global `profiles` RLS is NOT weakened.

-- Accent-insensitive matching for the people search (display names may carry
-- accents). Additive; installed into the extensions schema.
create extension if not exists unaccent with schema extensions;

-- ── 1. Canonical username normalization (shared contract; mirrored in Dart) ──
-- trim → NFKC → lower → strip one optional leading '@' (+ spaces) → null if blank.
-- IMMUTABLE so it can back a unique functional index. Internal characters are
-- never altered.
create or replace function private.normalize_username(p text)
returns text language sql immutable set search_path to '' as $$
  select nullif(
    btrim(regexp_replace(lower(normalize(coalesce(p, ''), nfkc)), '^\s*@?\s*', '')),
  '');
$$;

-- ── 2. Case/@-insensitive uniqueness + exact-normalized lookup index ──
-- No existing collisions were found before applying this (verified read-only).
create unique index if not exists profiles_username_norm_key
  on public.profiles (private.normalize_username(username));

-- Trigram index to accelerate case-insensitive prefix/substring username search
-- at scale (people picker). display_name search is accent-folded in the RPC.
create index if not exists profiles_username_lower_trgm
  on public.profiles using gin (lower(username) extensions.gin_trgm_ops);

-- ── 3. Harden the canonical UUID invite RPC (final write path for both the
--       typed username invite and the people picker) ──
-- Adds: self-invite rejection, distinct pending vs accepted errors, and
-- deleted/disabled-account rejection. Owner-only, blocked, role checks kept.
create or replace function public.playlist_invite_collaborator(
  p_playlist_id uuid, p_user_id uuid, p_role text default 'editor')
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid; v_status text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_owner <> v_uid then raise exception 'ONLY_OWNER' using errcode = '42501'; end if;
  if p_user_id = v_uid then raise exception 'CANNOT_INVITE_SELF'; end if;
  if p_user_id = v_owner then raise exception 'CANNOT_INVITE_OWNER'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'USER_NOT_FOUND';
  end if;
  -- deleted / banned auth accounts are not invitable (do not leak specifics).
  if exists (select 1 from auth.users au
             where au.id = p_user_id
               and (au.deleted_at is not null
                    or (au.banned_until is not null and au.banned_until > now()))) then
    raise exception 'USER_NOT_FOUND';
  end if;
  if private.is_blocked(v_owner, p_user_id) then raise exception 'USER_BLOCKED'; end if;
  if p_role not in ('editor','moderator','viewer') then raise exception 'INVALID_ROLE'; end if;
  select status into v_status from public.playlist_collaborators
    where playlist_id = p_playlist_id and user_id = p_user_id;
  if v_status = 'accepted' then raise exception 'ALREADY_COLLABORATOR'; end if;
  if v_status = 'pending'  then raise exception 'INVITATION_PENDING'; end if;
  insert into public.playlist_collaborators(playlist_id, user_id, role, status, invited_by, invited_at, updated_at)
  values (p_playlist_id, p_user_id, p_role, 'pending', v_uid, now(), now())
  on conflict (playlist_id, user_id) do update
    set role = excluded.role, status = 'pending', invited_by = v_uid,
        invited_at = now(), accepted_at = null, joined_at = null, updated_at = now();
  update public.playlists set collaborative = true, updated_at = now()
    where id = p_playlist_id and collaborative = false;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_invited',
    jsonb_build_object('user_id', p_user_id, 'role', p_role));
  perform private.emit_playlist_notification(p_user_id, v_uid, 'playlist_collaboration_invited',
    p_playlist_id, 'pl_invite:'||p_playlist_id::text||':'||p_user_id::text);
end; $$;

-- ── 4. Invite by username — trusted server-side resolution (no client SELECT) ──
create or replace function public.playlist_invite_collaborator_by_username(
  p_playlist_id uuid, p_username text, p_role text default 'editor')
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid; v_norm text; v_target uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_owner <> v_uid then raise exception 'ONLY_OWNER' using errcode = '42501'; end if;
  v_norm := private.normalize_username(p_username);
  if v_norm is null then raise exception 'USER_NOT_FOUND'; end if;
  select id into v_target from public.profiles
    where private.normalize_username(username) = v_norm limit 1;
  if v_target is null then raise exception 'USER_NOT_FOUND'; end if;
  -- All eligibility rules (self/owner/blocked/pending/accepted/disabled) +
  -- atomic insert + single notification are enforced by the canonical RPC.
  perform public.playlist_invite_collaborator(p_playlist_id, v_target, p_role);
end; $$;

-- ── 5. Secure, bounded people search for the collaborator picker ──
-- Returns only invitation-safe public fields. Owner-only (no leak otherwise),
-- min 2 chars, capped result set, wildcard-escaped, excludes self/owner/blocked/
-- existing collaborators/private/disabled. Ranked: exact username, username
-- prefix, display prefix, username substring, display substring.
create or replace function public.search_invitable_profiles(
  p_playlist_id uuid, p_query text, p_limit integer default 10)
returns table(user_id uuid, username text, display_name text, avatar_url text)
language plpgsql stable security definer set search_path to '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_owner uuid; v_q text; v_esc text; v_qd text; v_lim int;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found or v_owner <> v_uid then return; end if; -- only the owner may search; no leak
  v_q := private.normalize_username(p_query);
  if v_q is null or length(v_q) < 2 then return; end if;
  v_lim := least(greatest(coalesce(p_limit, 10), 1), 12);
  -- escape LIKE wildcards, then build accent-folded display query
  v_esc := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  v_qd  := extensions.unaccent(v_esc);
  return query
  with base as (
    select p.id, p.username, p.display_name, p.avatar_url,
           lower(p.username) as u_ci,
           extensions.unaccent(lower(coalesce(p.display_name, ''))) as d_ci
    from public.profiles p
    where p.is_private = false
      and p.id <> v_uid
      and p.id <> v_owner
      and not exists (select 1 from public.playlist_collaborators c
                      where c.playlist_id = p_playlist_id and c.user_id = p.id
                        and c.status in ('pending','accepted'))
      and not private.is_blocked(v_owner, p.id)
      and not exists (select 1 from auth.users au
                      where au.id = p.id
                        and (au.deleted_at is not null
                             or (au.banned_until is not null and au.banned_until > now())))
  )
  select b.id, b.username, b.display_name, b.avatar_url
  from base b
  where b.u_ci = v_q
     or b.u_ci like v_esc || '%'
     or b.d_ci like v_qd || '%'
     or b.u_ci like '%' || v_esc || '%'
     or b.d_ci like '%' || v_qd || '%'
  order by
    case
      when b.u_ci = v_q then 0
      when b.u_ci like v_esc || '%' then 1
      when b.d_ci like v_qd || '%' then 2
      when b.u_ci like '%' || v_esc || '%' then 3
      else 4
    end,
    b.username
  limit v_lim;
end; $$;

-- ── 6. Grants (authenticated only; revoke from anon/public) ──
revoke all on function public.playlist_invite_collaborator_by_username(uuid, text, text) from public, anon;
grant execute on function public.playlist_invite_collaborator_by_username(uuid, text, text) to authenticated;
revoke all on function public.search_invitable_profiles(uuid, text, integer) from public, anon;
grant execute on function public.search_invitable_profiles(uuid, text, integer) to authenticated;
