-- Phase 3.4.1 — tighten playlist permission helpers (used by existing RLS):
-- accepted-status collaborators only for editing, blocking-aware, soft-delete
-- aware. Same signatures → all existing RLS policies pick up the new logic.

create or replace function private.can_view_playlist(p_playlist_id uuid, p_user_id uuid)
returns boolean language plpgsql stable security definer set search_path to '' as $$
declare v_owner uuid; v_vis text; v_deleted timestamptz;
begin
  select owner_id, visibility, deleted_at into v_owner, v_vis, v_deleted
  from public.playlists where id = p_playlist_id;
  if not found then return false; end if;
  if v_deleted is not null then return false; end if; -- soft-deleted: hidden (owner restores via RPC)
  if v_vis in ('public', 'unlisted') then return true; end if;
  if p_user_id is null then return false; end if;
  if v_owner = p_user_id then return true; end if;
  if private.is_blocked(v_owner, p_user_id) then return false; end if;
  -- pending invitees may view (to accept/decline); accepted collaborators view.
  if exists (select 1 from public.playlist_collaborators c
             where c.playlist_id = p_playlist_id and c.user_id = p_user_id
               and c.status in ('pending', 'accepted')) then
    return true;
  end if;
  if v_vis = 'followers' then
    return private.is_accepted_friend(v_owner, p_user_id);
  end if;
  return false;
end;
$$;

create or replace function private.can_edit_playlist(p_playlist_id uuid, p_user_id uuid)
returns boolean language plpgsql stable security definer set search_path to '' as $$
declare v_owner uuid; v_collab boolean; v_deleted timestamptz;
begin
  if p_user_id is null then return false; end if;
  select owner_id, collaborative, deleted_at into v_owner, v_collab, v_deleted
  from public.playlists where id = p_playlist_id;
  if not found then return false; end if;
  if v_deleted is not null then return false; end if;
  if v_owner = p_user_id then return true; end if;
  if not v_collab then return false; end if;
  if private.is_blocked(v_owner, p_user_id) then return false; end if;
  return exists (
    select 1 from public.playlist_collaborators c
    where c.playlist_id = p_playlist_id
      and c.user_id = p_user_id
      and c.status = 'accepted'
      and c.role in ('editor', 'moderator', 'owner')
  );
end;
$$;

-- Owner-only management gate (collaborators, visibility, delete, transfer, cover).
create or replace function private.is_playlist_owner(p_playlist_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from public.playlists p
    where p.id = p_playlist_id and p.owner_id = p_user_id and p.deleted_at is null
  );
$$;
revoke all on function private.is_playlist_owner(uuid, uuid) from public, anon, authenticated;
